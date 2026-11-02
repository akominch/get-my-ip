import AppKit
import Foundation

/// Supplies flag images for the non-system `FlagStyle`s. Images are downloaded once,
/// normalised to a 64 px high PNG, cached on disk and kept in a small memory cache.
/// Main-thread API; every completion is called on the main queue exactly once.
final class FlagImageProvider {
    private static let pixelHeight = 64
    private static let menuBarHeight: CGFloat = 16

    private let memory = NSCache<NSString, NSImage>()
    private var pending: [String: [(NSImage?) -> Void]] = [:]
    private let cacheRoot: URL

    init() {
        memory.countLimit = 16
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheRoot = caches.appendingPathComponent("com.akominch.GetMyIP/flags", isDirectory: true)
    }

    func image(code: String, style: FlagStyle, completion: @escaping (NSImage?) -> Void) {
        let cc = code.uppercased()
        guard style != .apple, Self.isValid(cc) else { return completion(nil) }
        let key = "\(style.rawValue)/\(cc)"

        if let hit = memory.object(forKey: key as NSString) { return completion(hit) }

        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]

        if let url = cachedPNG(code: cc, style: style), let image = Self.menuImage(from: Data.read(url)) {
            return finish(key, image)
        }

        guard let remote = Self.remoteURL(code: cc, style: style) else { return finish(key, nil) }
        var request = URLRequest(url: remote)
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard ok, let data = data, let png = Self.normalizedPNG(from: data) else {
                    return self.finish(key, nil)
                }
                let file = self.fileURL(code: cc, style: style)
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? png.write(to: file, options: .atomic)
                self.finish(key, Self.menuImage(from: png))
            }
        }.resume()
    }

    /// On-disk PNG for the given flag, if it has been downloaded.
    func cachedPNG(code: String, style: FlagStyle) -> URL? {
        let cc = code.uppercased()
        guard style != .apple, Self.isValid(cc) else { return nil }
        let url = fileURL(code: cc, style: style)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Private

    private func finish(_ key: String, _ image: NSImage?) {
        if let image = image { memory.setObject(image, forKey: key as NSString) }
        let callbacks = pending.removeValue(forKey: key) ?? []
        for callback in callbacks { callback(image) }
    }

    private func fileURL(code: String, style: FlagStyle) -> URL {
        cacheRoot.appendingPathComponent(style.rawValue, isDirectory: true)
            .appendingPathComponent("\(code).png")
    }

    private static func isValid(_ cc: String) -> Bool {
        cc.utf8.count == 2 && cc.utf8.allSatisfy { $0 >= 65 && $0 <= 90 }
    }

    private static func remoteURL(code cc: String, style: FlagStyle) -> URL? {
        let lower = cc.lowercased()
        let scalars = cc.unicodeScalars.map { 127397 + $0.value }
        let hex = scalars.map { String($0, radix: 16) }
        let s: String
        switch style {
        case .apple: return nil
        case .twemoji:
            s = "gh/jdecked/twemoji@v16.0.1/assets/72x72/\(hex.joined(separator: "-")).png"
        case .openmoji:
            s = "npm/openmoji@15.1.0/color/svg/\(hex.joined(separator: "-").uppercased()).svg"
        case .noto:
            s = "gh/googlefonts/noto-emoji@v2.047/third_party/region-flags/png/\(cc).png"
        case .flagIcons:
            // flag-icons SVGs use features NSImage's SVG renderer draws incorrectly; flagcdn serves the same flags as PNG.
            return URL(string: "https://flagcdn.com/h80/\(lower).png")
        case .circleFlags:
            s = "gh/HatScripts/circle-flags@v2.6.2/flags/\(lower).svg"
        }
        return URL(string: "https://cdn.jsdelivr.net/" + s)
    }

    /// Decodes PNG/SVG data and re-renders it as a PNG 64 px high, keeping the aspect ratio.
    private static func normalizedPNG(from data: Data) -> Data? {
        guard let source = NSImage(data: data) else { return nil }
        var size = source.size
        if let rep = source.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        guard size.width > 0, size.height > 0 else { return nil }
        let height = pixelHeight
        let width = max(1, Int((CGFloat(height) * size.width / size.height).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                    from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Builds the menu-bar image (16 pt high, width by aspect ratio) from a cached PNG.
    private static func menuImage(from data: Data?) -> NSImage? {
        guard let data = data, let rep = NSBitmapImageRep(data: data),
              rep.pixelsHigh > 0, rep.pixelsWide > 0,
              let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: menuBarHeight * CGFloat(rep.pixelsWide) / CGFloat(rep.pixelsHigh),
                            height: menuBarHeight)
        image.isTemplate = false
        return image
    }
}

private extension Data {
    static func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}
