import AppKit
import Foundation

// Shared contract for all modules. All app state lives on the main thread.

/// Result of a successful public-IP lookup.
struct IPInfo: Equatable {
    let ip: String
    /// ISO 3166-1 alpha-2, uppercased ("DE").
    let countryCode: String
    /// Country name as reported by the service, if it reports one.
    let countryName: String?
    /// `IPService.id` of the service that produced this result.
    let serviceID: String
}

enum LookupError: Error, CustomStringConvertible {
    case interfaceUnavailable(String)
    case timeout
    case httpStatus(Int)
    case invalidResponse(String)
    case network(String)

    var description: String {
        switch self {
        case .interfaceUnavailable(let name): return "Interface \(name) is not available"
        case .timeout: return "Request timed out"
        case .httpStatus(let code): return "HTTP status \(code)"
        case .invalidResponse(let why): return "Invalid response: \(why)"
        case .network(let why): return "Network error: \(why)"
        }
    }
}

/// What the menu bar item shows.
enum DisplayMode: String, CaseIterable {
    case flag, code, flagAndCode

    var title: String {
        switch self {
        case .flag: return "Flag"
        case .code: return "Country code"
        case .flagAndCode: return "Flag + country code"
        }
    }
}

/// Visual style of the flag. `.apple` is the system emoji font (text); every other
/// style is an image set downloaded on demand and cached on disk as PNG.
enum FlagStyle: String, CaseIterable {
    case apple, twemoji, openmoji, noto, flagIcons, circleFlags

    var title: String {
        switch self {
        case .apple: return "Apple (system emoji)"
        case .twemoji: return "Twemoji (Twitter/X)"
        case .openmoji: return "OpenMoji"
        case .noto: return "Noto Color Emoji (Google)"
        case .flagIcons: return "Rectangular flags (flagcdn)"
        case .circleFlags: return "Circle Flags"
        }
    }
}

enum Country {
    /// Regional-indicator emoji for an ISO alpha-2 code ("DE" -> 🇩🇪). Returns "🏳️" for invalid codes.
    static func flagEmoji(_ code: String) -> String {
        let upper = code.uppercased()
        guard upper.count == 2, upper.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return "🏳️" }
        var s = ""
        for u in upper.unicodeScalars { s.unicodeScalars.append(Unicode.Scalar(127397 + u.value)!) }
        return s
    }

    /// Localized country name, falling back to the service-provided name, then the code.
    static func name(_ code: String, fallback: String? = nil) -> String {
        Locale.current.localizedString(forRegionCode: code.uppercased()) ?? fallback ?? code.uppercased()
    }
}
