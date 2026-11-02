import AppKit
import Foundation
import Security
import os

/// Self-updater backed by GitHub Releases of the repository named in Info.plist (`GMIUpdateRepository`).
/// Checks once a day; installs automatically when enabled, otherwise offers the update in the menu.
final class Updater {
    struct Release: Equatable {
        let version: String
        let zipURL: URL
        let pageURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release)
        case failed(String)
    }

    static let checkInterval: TimeInterval = 24 * 60 * 60

    var onStateChange: (() -> Void)?
    private(set) var state: State = .idle {
        didSet { onStateChange?() }
    }

    let repository: String?
    let currentVersion: String
    private var timer: Timer?
    private let log = Logger(subsystem: "com.akominch.GetMyIP", category: "update")

    init(bundle: Bundle = .main) {
        repository = (bundle.object(forInfoDictionaryKey: "GMIUpdateRepository") as? String).flatMap { $0.isEmpty ? nil : $0 }
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var isConfigured: Bool { repository != nil }

    func start() {
        guard isConfigured else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.check(userInitiated: false) }
        let t = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in self?.check(userInitiated: false) }
        t.tolerance = 60 * 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func check(userInitiated: Bool) {
        guard let repository else { return }
        if case .installing = state { return }
        if !userInitiated && !Settings.autoUpdateEnabled { return }
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GetMyIP/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, status == 200, let data, let release = Self.parseRelease(data) else {
                    let why = error?.localizedDescription ?? "HTTP \(status)"
                    self.log.error("update check failed: \(why, privacy: .public)")
                    self.state = .failed("Update check failed: \(why)")
                    return
                }
                guard Self.isVersion(release.version, newerThan: self.currentVersion) else {
                    self.log.info("up to date (\(self.currentVersion, privacy: .public), latest \(release.version, privacy: .public))")
                    self.state = .upToDate
                    return
                }
                self.log.info("update available \(release.version, privacy: .public)")
                self.state = .available(release)
                if Settings.autoUpdateEnabled && !userInitiated { self.install(release) }
            }
        }.resume()
    }

    func install(_ release: Release) {
        if case .installing = state { return }
        state = .installing(release)
        log.info("installing \(release.version, privacy: .public) from \(release.zipURL.absoluteString, privacy: .public)")
        URLSession.shared.downloadTask(with: release.zipURL) { [weak self] location, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var result: Result<URL, Error>
            if let location, error == nil, status == 200 {
                result = Result { try Self.prepare(zip: location, expectedVersion: release.version) }
            } else {
                result = .failure(UpdateError(error?.localizedDescription ?? "Download failed (HTTP \(status))"))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let newApp): self.replaceAndRelaunch(with: newApp, release: release)
                case .failure(let error): self.fail(release, error)
                }
            }
        }.resume()
    }

    private func fail(_ release: Release, _ error: Error) {
        log.error("update failed: \(error.localizedDescription, privacy: .public)")
        state = .failed("Update failed: \(error.localizedDescription)")
    }

    /// Unpacks the downloaded zip and validates the bundle before it may replace the running app.
    private static func prepare(zip: URL, expectedVersion: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("GetMyIP-update-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, dir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError("Could not unpack the update") }

        let app = dir.appendingPathComponent("GetMyIP.app")
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion else {
            throw UpdateError("Downloaded bundle does not match the release")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw UpdateError("Code signature of the update is invalid")
        }
        return app
    }

    private func replaceAndRelaunch(with newApp: URL, release: Release) {
        let current = Bundle.main.bundleURL
        do {
            guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
                throw UpdateError("No permission to replace \(current.path)")
            }
            _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp)
        } catch {
            fail(release, error)
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        log.info("updated to \(release.version, privacy: .public), relaunching")
        // Wait for this process to exit, then start the new bundle (a running instance would just be activated).
        let script = "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", script, current.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: Parsing (internal for tests)

    static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let zipURL = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, zipURL: zipURL, pageURL: page)
    }

    /// Numeric dotted-version comparison: "1.10.0" > "1.9.2", "1.2" == "1.2.0".
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
