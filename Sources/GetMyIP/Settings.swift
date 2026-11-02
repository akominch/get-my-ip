import Foundation

/// UserDefaults-backed preferences. Main thread only.
enum Settings {
    private static let d = UserDefaults.standard

    static let intervalRange: ClosedRange<TimeInterval> = 1...600
    static let intervalPresets: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    static var primaryServiceID: String {
        get { d.string(forKey: "primaryService").flatMap { IPServices.service(id: $0)?.id } ?? IPServices.defaultPrimaryID }
        set { d.set(newValue, forKey: "primaryService") }
    }

    /// nil = no fallback.
    static var fallbackServiceID: String? {
        get {
            guard let v = d.string(forKey: "fallbackService") else { return IPServices.defaultFallbackID }
            return v.isEmpty ? nil : IPServices.service(id: v)?.id
        }
        set { d.set(newValue ?? "", forKey: "fallbackService") }
    }

    static var interval: TimeInterval {
        get {
            let v = d.double(forKey: "interval")
            return v == 0 ? 30 : min(max(v, intervalRange.lowerBound), intervalRange.upperBound)
        }
        set { d.set(min(max(newValue, intervalRange.lowerBound), intervalRange.upperBound), forKey: "interval") }
    }

    /// nil = automatic (system routing, follows VPN).
    static var interfaceName: String? {
        get { d.string(forKey: "interface").flatMap { $0.isEmpty ? nil : $0 } }
        set { d.set(newValue ?? "", forKey: "interface") }
    }

    static var displayMode: DisplayMode {
        get { d.string(forKey: "displayMode").flatMap(DisplayMode.init(rawValue:)) ?? .flag }
        set { d.set(newValue.rawValue, forKey: "displayMode") }
    }

    static var flagStyle: FlagStyle {
        get { d.string(forKey: "flagStyle").flatMap(FlagStyle.init(rawValue:)) ?? .apple }
        set { d.set(newValue.rawValue, forKey: "flagStyle") }
    }

    static var notificationsEnabled: Bool {
        get { d.object(forKey: "notifications") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifications") }
    }

    /// Check GitHub Releases daily and install new versions automatically.
    static var autoUpdateEnabled: Bool {
        get { d.object(forKey: "autoUpdate") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoUpdate") }
    }

    static func formatInterval(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s) s" }
        if s % 60 == 0 { return "\(s / 60) min" }
        return "\(s / 60) min \(s % 60) s"
    }
}
