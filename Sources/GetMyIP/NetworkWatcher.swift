import Darwin
import Foundation
import Network
import SystemConfiguration

struct InterfaceInfo: Equatable {
    let name: String
    let displayName: String
    let kind: String
    let addresses: [String]
}

/// Call the public API only on the main thread. All event sources share one queue.
final class NetworkWatcher {
    var onChange: ((_ reason: String) -> Void)?
    /// Fired immediately (no debounce) when a system VPN service changes state.
    /// `transitioning` is true while any VPN service is connecting or disconnecting.
    var onVPNStatus: ((_ reason: String, _ transitioning: Bool) -> Void)?
    private(set) var interfaces: [InterfaceInfo] = []
    private(set) var primaryInterface: String?

    private let queue = DispatchQueue(label: "GetMyIP.NetworkWatcher")
    private let queueKey = DispatchSpecificKey<Void>()
    private var activeID: UUID?
    private var availableInterfaces: [NWInterface] = []

    // The following state belongs exclusively to queue.
    private var monitor: NWPathMonitor?
    private var store: SCDynamicStore?
    private var sessionID: UUID?
    private var path: NWPath?
    private var observed: Signature?
    private var delivered: Signature?
    private var pendingChange: DispatchWorkItem?
    private var vpnConnections: [String: (name: String, connection: SCNetworkConnection)] = [:]
    private var vpnStates: [String: SCNetworkConnectionStatus] = [:]

    private struct Signature: Equatable {
        let primary: String?
        let route: String?
        let interfaces: [InterfaceInfo]
        let status: NWPath.Status

        static func == (lhs: Signature, rhs: Signature) -> Bool {
            lhs.primary == rhs.primary && lhs.route == rhs.route && lhs.status == rhs.status
                && lhs.interfaces.count == rhs.interfaces.count
                && zip(lhs.interfaces, rhs.interfaces).allSatisfy {
                    $0.name == $1.name && $0.addresses == $1.addresses
                }
        }
    }

    private final class StoreContext {
        weak var owner: NetworkWatcher?

        init(_ owner: NetworkWatcher) {
            self.owner = owner
        }
    }

    init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            tearDown()
        } else {
            queue.sync { tearDown() }
        }
    }

    func start() {
        precondition(Thread.isMainThread)
        guard activeID == nil else { return }
        let id = UUID()
        activeID = id
        // Seed the primary interface synchronously; NWPath supplies its initial
        // interface list asynchronously, without treating it as a change.
        primaryInterface = queue.sync {
            sessionID = id
            let box = StoreContext(self)
            var context = SCDynamicStoreContext(
                version: 0,
                info: Unmanaged.passUnretained(box).toOpaque(),
                retain: { pointer in
                    return UnsafeRawPointer(Unmanaged<StoreContext>
                        .fromOpaque(pointer).retain().toOpaque())
                },
                release: { pointer in
                    Unmanaged<StoreContext>.fromOpaque(pointer).release()
                },
                copyDescription: nil
            )
            store = SCDynamicStoreCreate(
                nil,
                "GetMyIP.NetworkWatcher" as CFString,
                { _, _, pointer in
                    guard let pointer else { return }
                    Unmanaged<StoreContext>.fromOpaque(pointer)
                        .takeUnretainedValue().owner?.refresh()
                },
                &context
            )
            if let store {
                let keys = [
                    "State:/Network/Global/IPv4",
                    "State:/Network/Global/IPv6"
                ] as CFArray
                let patterns = [
                    "State:/Network/Interface/[^/]+/IPv4",
                    "State:/Network/Interface/[^/]+/IPv6"
                ] as CFArray
                SCDynamicStoreSetNotificationKeys(store, keys, patterns)
                SCDynamicStoreSetDispatchQueue(store, queue)
            }
            let newMonitor = NWPathMonitor()
            monitor = newMonitor
            newMonitor.pathUpdateHandler = { [weak self] newPath in
                guard let self, self.sessionID == id else { return }
                self.path = newPath
                self.refresh()
            }
            newMonitor.start(queue: queue)
            syncVPNServices()
            return readPrimary()
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        activeID = nil
        queue.sync { tearDown() }
        availableInterfaces = []
        interfaces = []
        primaryInterface = nil
    }

    func nwInterface(named name: String) -> NWInterface? {
        precondition(Thread.isMainThread)
        return availableInterfaces.first { $0.name == name }
    }

    private func tearDown() {
        sessionID = nil
        pendingChange?.cancel()
        pendingChange = nil
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
        if let store {
            SCDynamicStoreSetDispatchQueue(store, nil)
        }
        store = nil
        for entry in vpnConnections.values {
            SCNetworkConnectionSetDispatchQueue(entry.connection, nil)
        }
        vpnConnections = [:]
        vpnStates = [:]
        path = nil
        observed = nil
        delivered = nil
    }

    private func readPrimary() -> String? {
        globalIPv4()?["PrimaryInterface"] as? String
    }

    /// Primary service + router: changes when a VPN takes over routing even if the interface name is reused.
    private func readRoute() -> String? {
        guard let v = globalIPv4() else { return nil }
        return "\(v["PrimaryService"] as? String ?? "-")|\(v["Router"] as? String ?? "-")"
    }

    private func globalIPv4() -> [String: Any]? {
        guard let store else { return nil }
        return SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    }

    /// Subscribes to status changes of every VPN service in the current network set
    /// (the same services `scutil --nc list` shows). Re-run to pick up added/removed services.
    private func syncVPNServices() {
        guard sessionID != nil,
              let prefs = SCPreferencesCreate(nil, "GetMyIP" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(prefs),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { return }
        let vpnTypes: Set<String> = ["VPN", "PPP", "IPSec", "L2TP"]
        var wanted: [String: String] = [:]
        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let iface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(iface) as String?, vpnTypes.contains(type),
                  let id = SCNetworkServiceGetServiceID(service) as String? else { continue }
            wanted[id] = (SCNetworkServiceGetName(service) as String?) ?? id
        }
        for (id, entry) in vpnConnections where wanted[id] == nil {
            SCNetworkConnectionSetDispatchQueue(entry.connection, nil)
            vpnConnections[id] = nil
            vpnStates[id] = nil
        }
        for (id, name) in wanted where vpnConnections[id] == nil {
            let box = StoreContext(self)
            var context = SCNetworkConnectionContext(
                version: 0,
                info: Unmanaged.passUnretained(box).toOpaque(),
                retain: { UnsafeRawPointer(Unmanaged<StoreContext>.fromOpaque($0).retain().toOpaque()) },
                release: { Unmanaged<StoreContext>.fromOpaque($0).release() },
                copyDescription: nil
            )
            guard let connection = SCNetworkConnectionCreateWithServiceID(nil, id as CFString, { connection, status, info in
                guard let info else { return }
                Unmanaged<StoreContext>.fromOpaque(info).takeUnretainedValue().owner?
                    .vpnStatusChanged(connection, status)
            }, &context) else { continue }
            if SCNetworkConnectionSetDispatchQueue(connection, queue) {
                vpnConnections[id] = (name, connection)
                vpnStates[id] = SCNetworkConnectionGetStatus(connection)
            }
        }
    }

    private func vpnStatusChanged(_ connection: SCNetworkConnection, _ status: SCNetworkConnectionStatus) {
        guard let id = sessionID,
              let serviceID = SCNetworkConnectionCopyServiceID(connection) as String? else { return }
        let name = vpnConnections[serviceID]?.name ?? serviceID
        // The first callback after subscribing just reports the current state; only real transitions matter.
        guard vpnStates[serviceID] != status else { return }
        vpnStates[serviceID] = status
        let state: String
        switch status {
        case .connecting: state = "connecting"
        case .connected: state = "connected"
        case .disconnecting: state = "disconnecting"
        case .disconnected: state = "disconnected"
        default: state = "invalid"
        }
        let transitioning = vpnStates.values.contains { $0 == .connecting || $0 == .disconnecting }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeID == id else { return }
            self.onVPNStatus?("vpn \(name) \(state)", transitioning)
        }
    }

    private func refresh() {
        guard let id = sessionID, let path else { return }
        let nwInterfaces = path.availableInterfaces
        let snapshot = Signature(
            primary: readPrimary(),
            route: readRoute(),
            interfaces: Self.enumerate(nwInterfaces),
            status: path.status
        )
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeID == id else { return }
            self.availableInterfaces = nwInterfaces
            self.interfaces = snapshot.interfaces
            self.primaryInterface = snapshot.primary
        }

        guard let previous = observed else {
            observed = snapshot
            delivered = snapshot
            return
        }
        guard previous != snapshot else { return }
        observed = snapshot
        pendingChange?.cancel()
        pendingChange = nil
        guard snapshot != delivered else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessionID == id,
                  let latest = self.observed,
                  let baseline = self.delivered,
                  latest != baseline else { return }
            self.delivered = latest
            self.pendingChange = nil
            self.syncVPNServices()
            let reason: String
            if baseline.primary != latest.primary {
                reason = "primary \(baseline.primary ?? "none") -> \(latest.primary ?? "none")"
            } else if baseline.interfaces != latest.interfaces {
                reason = "interfaces changed"
            } else if baseline.route != latest.route {
                reason = "route \(baseline.route ?? "none") -> \(latest.route ?? "none")"
            } else {
                reason = "path \(baseline.status) -> \(latest.status)"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeID == id else { return }
                self.onChange?(reason)
            }
        }
        pendingChange = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private static func isVPN(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
    }

    private static func enumerate(_ nwInterfaces: [NWInterface]) -> [InterfaceInfo] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }

        var addresses: [String: [String]] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let item = entry.pointee
            guard item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = item.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: item.ifa_name)
            guard nwInterfaces.contains(where: { $0.name == name }) || isVPN(name) else {
                continue
            }
            if family == AF_INET6 {
                let value = UnsafeRawPointer(address)
                    .assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                let bytes = withUnsafeBytes(of: value) { Array($0) }
                // fe80::/10, unspecified, and loopback are not internet addresses.
                if (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
                    || bytes.allSatisfy({ $0 == 0 })
                    || (bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1) {
                    continue
                }
            } else {
                let value = UnsafeRawPointer(address)
                    .assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                let host = UInt32(bigEndian: value)
                if host >> 16 == 0xa9fe || host >> 24 == 127 || host == 0 {
                    continue
                }
            }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let text = String(cString: buffer)
            if !(addresses[name]?.contains(text) ?? false) {
                addresses[name, default: []].append(text)
            }
        }

        var labels: [String: String] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in all {
                if let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                   let label = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                    labels[name] = label
                }
            }
        }
        return addresses.keys.sorted().map { name in
            let kind: String
            if isVPN(name) {
                kind = "vpn"
            } else {
                switch nwInterfaces.first(where: { $0.name == name })?.type {
                case .wifi: kind = "wifi"
                case .wiredEthernet: kind = "ethernet"
                case .cellular: kind = "cellular"
                default: kind = "other"
                }
            }
            let label = kind == "vpn" ? "VPN" : (labels[name] ?? name)
            let sortedAddresses = (addresses[name] ?? []).sorted {
                let leftIPv6 = $0.contains(":")
                let rightIPv6 = $1.contains(":")
                return leftIPv6 == rightIPv6 ? $0 < $1 : !leftIPv6
            }
            return InterfaceInfo(
                name: name,
                displayName: "\(label) (\(name))",
                kind: kind,
                addresses: sortedAddresses
            )
        }
    }
}
