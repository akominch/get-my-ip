import Foundation
import Network

struct IPService {
    let id: String
    let title: String
    let url: URL
    let parse: (Data) throws -> (ip: String, countryCode: String, countryName: String?)
}

enum IPServices {
    static let defaultPrimaryID = "cloudflare"
    static let defaultFallbackID = "ipwho.is"

    static let all: [IPService] = [
        IPService(id: "cloudflare", title: "Cloudflare (cdn-cgi/trace)",
                  url: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!) { data in
            guard let text = String(data: data, encoding: .utf8) else {
                throw LookupError.invalidResponse("Invalid Cloudflare trace text")
            }
            var fields: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
            guard let ip = fields["ip"], let country = fields["loc"] else {
                throw LookupError.invalidResponse("Missing Cloudflare IP or country")
            }
            return try validated(ip: ip, code: country, name: nil)
        },
        jsonService(id: "ipapi.co", title: "ipapi.co", url: "https://ipapi.co/json/",
                    ip: "ip", code: "country_code", name: "country_name"),
        jsonService(id: "ipinfo", title: "IPinfo", url: "https://ipinfo.io/json",
                    ip: "ip", code: "country"),
        jsonService(id: "ip-api", title: "IP-API (HTTP)",
                    url: "http://ip-api.com/json/?fields=status,country,countryCode,query",
                    ip: "query", code: "countryCode", name: "country"),
        jsonService(id: "ipwho.is", title: "ipwho.is", url: "https://ipwho.is/",
                    ip: "ip", code: "country_code", name: "country"),
        jsonService(id: "country.is", title: "country.is", url: "https://api.country.is/",
                    ip: "ip", code: "country"),
        jsonService(id: "geojs", title: "GeoJS", url: "https://get.geojs.io/v1/ip/geo.json",
                    ip: "ip", code: "country_code", name: "country"),
        jsonService(id: "ipwhois.app", title: "ipwhois.app", url: "https://ipwhois.app/json/",
                    ip: "ip", code: "country_code", name: "country"),
        jsonService(id: "ip.sb", title: "ip.sb", url: "https://api.ip.sb/geoip",
                    ip: "ip", code: "country_code", name: "country")
    ]

    static func service(id: String) -> IPService? {
        all.first { $0.id == id }
    }

    private static func jsonService(id: String, title: String, url: String, ip: String,
                                    code: String, name: String? = nil) -> IPService {
        IPService(id: id, title: title, url: URL(string: url)!) { data in
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LookupError.invalidResponse("Expected JSON object from \(id)")
            }
            if object["success"] as? Bool == false || object["status"] as? String == "fail"
                || object["error"] as? Bool == true {
                throw LookupError.invalidResponse("Service \(id) reported failure")
            }
            guard let address = object[ip] as? String, let country = object[code] as? String else {
                throw LookupError.invalidResponse("Missing IP or country from \(id)")
            }
            return try validated(ip: address, code: country, name: name.flatMap { object[$0] as? String })
        }
    }

    private static func validated(ip: String, code: String, name: String?) throws
        -> (ip: String, countryCode: String, countryName: String?) {
        guard !ip.isEmpty else { throw LookupError.invalidResponse("Missing IP address") }
        guard code.utf8.count == 2,
              code.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else {
            throw LookupError.invalidResponse("Country code must contain two ASCII letters")
        }
        return (ip, code.uppercased(), name)
    }
}

final class IPLookup {
    func lookup(primaryID: String, fallbackID: String?, interface: NWInterface?, timeout: TimeInterval,
                completion: @escaping (Result<IPInfo, LookupError>) -> Void) {
        Self.fetch(id: primaryID, interface: interface, timeout: timeout) { primary in
            guard case .failure(let primaryError) = primary,
                  let fallbackID = fallbackID, fallbackID != primaryID else {
                completion(primary)
                return
            }
            Self.fetch(id: fallbackID, interface: interface, timeout: timeout) { fallback in
                switch fallback {
                case .success: completion(fallback)
                case .failure: completion(.failure(primaryError))
                }
            }
        }
    }

    private static func fetch(id: String, interface: NWInterface?, timeout: TimeInterval,
                              completion: @escaping (Result<IPInfo, LookupError>) -> Void) {
        guard let service = IPServices.service(id: id) else {
            DispatchQueue.main.async {
                completion(.failure(.invalidResponse("Unknown service: \(id)")))
            }
            return
        }
        HTTPClient.get(service.url, interface: interface, timeout: timeout) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                do {
                    let value = try service.parse(data)
                    completion(.success(IPInfo(ip: value.ip, countryCode: value.countryCode,
                                               countryName: value.countryName, serviceID: service.id)))
                } catch let error as LookupError {
                    completion(.failure(error))
                } catch {
                    completion(.failure(.invalidResponse(error.localizedDescription)))
                }
            }
        }
    }
}
