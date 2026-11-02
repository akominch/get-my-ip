import Foundation
import UserNotifications
import os

/// Posts "country changed" notifications.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "com.akominch.GetMyIP", category: "notify")

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [log] granted, error in
            log.info("notification authorization granted=\(granted, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
        center.getNotificationSettings { [log] s in
            log.info("notification settings status=\(s.authorizationStatus.rawValue, privacy: .public) alertStyle=\(s.alertStyle.rawValue, privacy: .public)")
        }
    }

    func countryChanged(from old: IPInfo, to new: IPInfo, flagImage: URL?) {
        let content = UNMutableNotificationContent()
        content.title = "\(Country.flagEmoji(new.countryCode)) \(Country.name(new.countryCode, fallback: new.countryName))"
        content.subtitle = "Country changed from \(Country.flagEmoji(old.countryCode)) \(Country.name(old.countryCode, fallback: old.countryName))"
        content.body = "New IP: \(new.ip)"
        content.sound = nil
        content.threadIdentifier = "country-change"
        if let src = flagImage {
            // The system moves attachment files into its store, so hand it a copy.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flag-\(UUID().uuidString).png")
            if (try? FileManager.default.copyItem(at: src, to: tmp)) != nil,
               let att = try? UNNotificationAttachment(identifier: "flag", url: tmp) {
                content.attachments = [att]
            }
        }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req) { [log] error in
            log.info("notification posted \(old.countryCode, privacy: .public)->\(new.countryCode, privacy: .public) ip=\(new.ip, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
