import AppKit
import Network
import ServiceManagement
import os

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let log = Logger(subsystem: "com.akominch.GetMyIP", category: "app")
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let lookup = IPLookup()
    private let watcher = NetworkWatcher()
    private let flags = FlagImageProvider()
    private let notifier = Notifier()
    private let updater = Updater()

    private static let resolvingTitle = "Resolving… 🏳️"
    private var timer: Timer?
    private var inFlight = false
    private var generation = 0
    /// Set on a network change; the status shows "Resolving…" until the next successful lookup.
    private var awaitingNetwork = false
    private var vpnTransitioning = false
    private var lastSuccess: Date?
    private static let initialRetryDelay: TimeInterval = 2
    private var retryDelay = initialRetryDelay
    private var retryWork: DispatchWorkItem?
    private var vpnSafety: DispatchWorkItem?
    private var followUp: DispatchWorkItem?

    private var current: IPInfo?
    private var lastError: LookupError?
    private var lastUpdate: Date?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = Self.resolvingTitle
        statusItem.button?.imageScaling = .scaleProportionallyDown
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        notifier.requestAuthorization()

        watcher.onChange = { [weak self] reason in
            self?.networkChanged(reason)
        }
        watcher.onVPNStatus = { [weak self] reason, transitioning in
            self?.vpnStatusChanged(reason, transitioning: transitioning)
        }
        watcher.start()
        updater.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        log.info("started interval=\(Settings.interval, privacy: .public) primary=\(Settings.primaryServiceID, privacy: .public) fallback=\(Settings.fallbackServiceID ?? "none", privacy: .public) interface=\(Settings.interfaceName ?? "auto", privacy: .public)")
        refresh(reason: "launch")
        scheduleTimer()
    }

    @objc private func didWake() {
        refresh(reason: "wake")
    }

    private func vpnStatusChanged(_ reason: String, transitioning: Bool) {
        log.info("\(reason, privacy: .public)")
        vpnSafety?.cancel()
        guard transitioning else {
            vpnTransitioning = false
            networkChanged(reason)
            return
        }
        // Show "Resolving…" while the tunnel is being set up/torn down; the old country is no longer trustworthy.
        vpnTransitioning = true
        awaitingNetwork = true
        updateStatusItem()
        let safety = DispatchWorkItem { [weak self] in
            self?.vpnTransitioning = false
            self?.networkChanged("vpn transition timeout")
        }
        vpnSafety = safety
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: safety)
    }

    private func networkChanged(_ reason: String) {
        log.info("network change: \(reason, privacy: .public)")
        // Secondary events right after a fresh answer (route/interface churn) re-check silently instead of flickering.
        if lastSuccess.map({ Date().timeIntervalSince($0) > 1.5 }) ?? true {
            awaitingNetwork = true
            updateStatusItem()
        }
        refresh(reason: "network: \(reason)")
        // VPN clients often finish installing routes/DNS shortly after the interface appears.
        followUp?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(reason: "network follow-up") }
        followUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: Polling

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = Settings.interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh(reason: nil)
        }
        t.tolerance = min(interval * 0.1, 5)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// `reason == nil` marks a routine timer tick: skipped while a request is in flight.
    /// Any other refresh supersedes the in-flight request, whose result may describe an outdated network path.
    private func refresh(reason: String?) {
        if reason == nil && (inFlight || vpnTransitioning) { return }
        retryWork?.cancel()
        retryWork = nil
        generation &+= 1
        let gen = generation
        var iface: NWInterface?
        if let name = Settings.interfaceName {
            guard let found = watcher.nwInterface(named: name) else {
                finish(.failure(.interfaceUnavailable(name)))
                return
            }
            iface = found
        }
        inFlight = true
        if let reason { log.info("refresh: \(reason, privacy: .public)") }
        lookup.lookup(primaryID: Settings.primaryServiceID, fallbackID: Settings.fallbackServiceID,
                      interface: iface, timeout: 5) { [weak self] result in
            guard let self, gen == self.generation else { return }
            self.finish(result)
        }
    }

    private func finish(_ result: Result<IPInfo, LookupError>) {
        inFlight = false
        lastUpdate = Date()
        switch result {
        case .success(let info):
            lastError = nil
            lastSuccess = Date()
            retryDelay = Self.initialRetryDelay
            awaitingNetwork = vpnTransitioning
            let previous = current
            current = info
            if previous != info {
                log.info("result ip=\(info.ip, privacy: .public) cc=\(info.countryCode, privacy: .public) via=\(info.serviceID, privacy: .public)")
            }
            if let previous, previous.countryCode != info.countryCode {
                countryChanged(from: previous, to: info)
            }
        case .failure(let error):
            lastError = error
            // Don't sit on "Resolving…" until the next (possibly 10-minute) tick: retry with backoff.
            let delay = min(retryDelay, Settings.interval)
            retryDelay = min(retryDelay * 2, 30)
            let work = DispatchWorkItem { [weak self] in self?.refresh(reason: "retry after failure") }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            log.error("lookup failed: \(error.description, privacy: .public)")
        }
        updateStatusItem()
    }

    private func countryChanged(from old: IPInfo, to new: IPInfo) {
        log.info("country changed \(old.countryCode, privacy: .public) -> \(new.countryCode, privacy: .public)")
        guard Settings.notificationsEnabled else { return }
        let style = Settings.flagStyle
        if style == .apple {
            notifier.countryChanged(from: old, to: new, flagImage: nil)
        } else {
            // Make sure the PNG is on disk so the notification can carry it.
            flags.image(code: new.countryCode, style: style) { [weak self] _ in
                guard let self else { return }
                self.notifier.countryChanged(from: old, to: new,
                                             flagImage: self.flags.cachedPNG(code: new.countryCode, style: style))
            }
        }
    }

    // MARK: Status item

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.toolTip = tooltip()
        guard let info = current, lastError == nil, !awaitingNetwork else {
            button.image = nil
            button.title = Self.resolvingTitle
            return
        }
        let code = info.countryCode
        let mode = Settings.displayMode
        let style = Settings.flagStyle

        if mode == .code || style == .apple {
            button.image = nil
            switch mode {
            case .flag: button.title = Country.flagEmoji(code)
            case .code: button.title = code
            case .flagAndCode: button.title = "\(Country.flagEmoji(code)) \(code)"
            }
            return
        }

        // Third-party image style. Show the emoji until the image is ready.
        let suffix = mode == .flagAndCode ? " \(code)" : ""
        flags.image(code: code, style: style) { [weak self] image in
            guard let self, let button = self.statusItem.button,
                  self.current?.countryCode == code, self.lastError == nil, Settings.flagStyle == style, Settings.displayMode == mode else { return }
            if let image {
                button.image = image
                button.imagePosition = suffix.isEmpty ? .imageOnly : .imageLeft
                button.title = suffix
            } else {
                button.image = nil
                button.title = Country.flagEmoji(code) + suffix
            }
        }
    }

    private func tooltip() -> String {
        var lines: [String] = []
        if let info = current {
            lines.append("\(Country.name(info.countryCode, fallback: info.countryName)) — \(info.ip)")
        }
        if let lastError { lines.append(lastError.description) }
        return lines.joined(separator: "\n")
    }

    // MARK: Menu (built lazily each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let info = current {
            let name = Country.name(info.countryCode, fallback: info.countryName)
            menu.addItem(disabled("\(Country.flagEmoji(info.countryCode))  \(name) (\(info.countryCode))"))
            menu.addItem(item("IP: \(info.ip)", #selector(copyIP), key: "c"))
            let via = IPServices.service(id: info.serviceID)?.title ?? info.serviceID
            menu.addItem(disabled("Via \(via)"))
        } else {
            menu.addItem(disabled("No data yet"))
        }
        if let lastError { menu.addItem(disabled("⚠︎ \(lastError.description)")) }
        if let lastUpdate {
            let f = DateFormatter()
            f.timeStyle = .medium
            menu.addItem(disabled("Updated \(f.string(from: lastUpdate))"))
        }
        menu.addItem(.separator())
        menu.addItem(item("Refresh Now", #selector(refreshNow), key: "r"))
        menu.addItem(.separator())

        menu.addItem(submenu("Show", DisplayMode.allCases.map {
            choice($0.title, $0.rawValue, Settings.displayMode == $0, #selector(pickDisplay(_:)))
        }))
        menu.addItem(submenu("Flag Style", FlagStyle.allCases.map {
            choice($0.title, $0.rawValue, Settings.flagStyle == $0, #selector(pickStyle(_:)))
        }))
        menu.addItem(submenu("Service", IPServices.all.map {
            choice($0.title, $0.id, Settings.primaryServiceID == $0.id, #selector(pickPrimary(_:)))
        }))
        var fallbackItems = [choice("None", "", Settings.fallbackServiceID == nil, #selector(pickFallback(_:))), .separator()]
        fallbackItems += IPServices.all.map {
            let it = choice($0.title, $0.id, Settings.fallbackServiceID == $0.id, #selector(pickFallback(_:)))
            it.isEnabled = $0.id != Settings.primaryServiceID
            return it
        }
        menu.addItem(submenu("Fallback Service", fallbackItems))

        let current = Settings.interval
        var intervalItems = Settings.intervalPresets.map {
            choice(Settings.formatInterval($0), String($0), current == $0, #selector(pickInterval(_:)))
        }
        intervalItems.append(.separator())
        let custom = Settings.intervalPresets.contains(current) ? "Custom…" : "Custom (\(Settings.formatInterval(current)))…"
        let customItem = item(custom, #selector(customInterval))
        customItem.state = Settings.intervalPresets.contains(current) ? .off : .on
        intervalItems.append(customItem)
        menu.addItem(submenu("Update Interval", intervalItems))

        let primary = watcher.primaryInterface.map { " — \($0)" } ?? ""
        var ifaceItems = [choice("Automatic\(primary)", "", Settings.interfaceName == nil, #selector(pickInterface(_:))), .separator()]
        var names = Set<String>()
        for i in watcher.interfaces {
            names.insert(i.name)
            let addr = i.addresses.first.map { "  \($0)" } ?? ""
            ifaceItems.append(choice(i.displayName + addr, i.name, Settings.interfaceName == i.name, #selector(pickInterface(_:))))
        }
        if let selected = Settings.interfaceName, !names.contains(selected) {
            let gone = choice("\(selected) (unavailable)", selected, true, #selector(pickInterface(_:)))
            ifaceItems.append(gone)
        }
        menu.addItem(submenu("Interface", ifaceItems))

        menu.addItem(.separator())
        let notify = item("Notify on Country Change", #selector(toggleNotifications))
        notify.state = Settings.notificationsEnabled ? .on : .off
        menu.addItem(notify)
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        if updater.isConfigured {
            let auto = item("Automatically Install Updates", #selector(toggleAutoUpdate))
            auto.state = Settings.autoUpdateEnabled ? .on : .off
            menu.addItem(auto)
            switch updater.state {
            case .available(let release):
                menu.addItem(item("Install Update \(release.version)…", #selector(installUpdate)))
            case .installing(let release):
                menu.addItem(disabled("Installing \(release.version)…"))
            case .checking:
                menu.addItem(disabled("Checking for Updates…"))
            default:
                menu.addItem(item("Check for Updates", #selector(checkForUpdates)))
            }
            switch updater.state {
            case .upToDate: menu.addItem(disabled("GetMyIP \(updater.currentVersion) is up to date"))
            case .failed(let why): menu.addItem(disabled("⚠︎ \(why)"))
            default: break
            }
        }
        menu.addItem(.separator())
        menu.addItem(disabled("GetMyIP \(updater.currentVersion)"))
        menu.addItem(.separator())
        menu.addItem(item("Quit GetMyIP", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = target ?? self
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func choice(_ title: String, _ value: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let it = item(title, action)
        it.representedObject = value
        it.state = on ? .on : .off
        return it
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        items.forEach(sub.addItem)
        it.submenu = sub
        return it
    }

    // MARK: Actions

    @objc private func toggleAutoUpdate() {
        Settings.autoUpdateEnabled.toggle()
        if Settings.autoUpdateEnabled { updater.check(userInitiated: false) }
    }

    @objc private func checkForUpdates() { updater.check(userInitiated: true) }

    @objc private func installUpdate() {
        if case .available(let release) = updater.state { updater.install(release) }
    }

    @objc private func refreshNow() { refresh(reason: "manual") }

    @objc private func copyIP() {
        guard let ip = current?.ip else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }

    @objc private func pickDisplay(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String, let m = DisplayMode(rawValue: v) else { return }
        Settings.displayMode = m
        updateStatusItem()
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String, let s = FlagStyle(rawValue: v) else { return }
        Settings.flagStyle = s
        updateStatusItem()
    }

    @objc private func pickPrimary(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.primaryServiceID = id
        if Settings.fallbackServiceID == id { Settings.fallbackServiceID = nil }
        refresh(reason: "service changed")
    }

    @objc private func pickFallback(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.fallbackServiceID = id.isEmpty ? nil : id
    }

    @objc private func pickInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String, let t = TimeInterval(v) else { return }
        Settings.interval = t
        scheduleTimer()
    }

    @objc private func customInterval() {
        let alert = NSAlert()
        alert.messageText = "Update Interval"
        alert.informativeText = "Seconds between checks (1–600)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = String(Int(Settings.interval))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let v = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
              Settings.intervalRange.contains(TimeInterval(v)) else {
            NSSound.beep()
            return
        }
        Settings.interval = TimeInterval(v)
        scheduleTimer()
    }

    @objc private func pickInterface(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.interfaceName = name.isEmpty ? nil : name
        refresh(reason: "interface changed")
    }

    @objc private func toggleNotifications() {
        Settings.notificationsEnabled.toggle()
        if Settings.notificationsEnabled { notifier.requestAuthorization() }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
