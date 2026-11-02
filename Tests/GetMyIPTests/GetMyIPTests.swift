import XCTest
@testable import GetMyIP

final class IPServicesTests: XCTestCase {
    private func parse(_ id: String, _ body: String) throws -> (ip: String, countryCode: String, countryName: String?) {
        let service = try XCTUnwrap(IPServices.service(id: id), "unknown service \(id)")
        return try service.parse(Data(body.utf8))
    }

    func testEveryServiceParsesItsRealResponseShape() throws {
        let fixtures: [String: String] = [
            "cloudflare": "fl=12f1\nh=www.cloudflare.com\nip=157.90.232.174\nts=1793621000.1\nloc=DE\ntls=TLSv1.3\n",
            "ipapi.co": #"{"ip":"157.90.232.174","country_code":"DE","country_name":"Germany"}"#,
            "ipinfo": #"{"ip":"157.90.232.174","city":"Falkenstein","country":"DE"}"#,
            "ip-api": #"{"status":"success","country":"Germany","countryCode":"DE","query":"157.90.232.174"}"#,
            "ipwho.is": #"{"ip":"157.90.232.174","success":true,"country":"Germany","country_code":"DE"}"#,
            "country.is": #"{"ip":"157.90.232.174","country":"DE"}"#,
            "geojs": #"{"ip":"157.90.232.174","country":"Germany","country_code":"DE"}"#,
            "ipwhois.app": #"{"ip":"157.90.232.174","success":true,"country":"Germany","country_code":"DE"}"#,
            "ip.sb": #"{"ip":"157.90.232.174","country":"Germany","country_code":"DE"}"#,
        ]
        XCTAssertEqual(Set(fixtures.keys), Set(IPServices.all.map(\.id)), "every service needs a fixture")
        for (id, body) in fixtures {
            let r = try parse(id, body)
            XCTAssertEqual(r.ip, "157.90.232.174", id)
            XCTAssertEqual(r.countryCode, "DE", id)
        }
    }

    func testCountryCodeIsUppercased() throws {
        XCTAssertEqual(try parse("country.is", #"{"ip":"1.1.1.1","country":"us"}"#).countryCode, "US")
    }

    func testInvalidCountryCodeIsRejected() {
        XCTAssertThrowsError(try parse("country.is", #"{"ip":"1.1.1.1","country":"USA"}"#))
        XCTAssertThrowsError(try parse("country.is", #"{"ip":"1.1.1.1","country":""}"#))
        XCTAssertThrowsError(try parse("cloudflare", "ip=1.1.1.1\nloc=\n"))
    }

    func testServiceReportedFailureIsRejected() {
        XCTAssertThrowsError(try parse("ipwho.is", #"{"ip":"1.1.1.1","success":false,"country_code":"US"}"#))
        XCTAssertThrowsError(try parse("ip-api", #"{"status":"fail","countryCode":"US","query":"1.1.1.1"}"#))
    }

    func testMissingFieldsAndGarbageAreRejected() {
        XCTAssertThrowsError(try parse("ipinfo", #"{"ip":"1.1.1.1"}"#))
        XCTAssertThrowsError(try parse("ipinfo", "<html>rate limited</html>"))
        XCTAssertThrowsError(try parse("cloudflare", "loc=US\n"))
    }

    func testDefaultServicesExistAndDiffer() {
        XCTAssertNotNil(IPServices.service(id: IPServices.defaultPrimaryID))
        XCTAssertNotNil(IPServices.service(id: IPServices.defaultFallbackID))
        XCTAssertNotEqual(IPServices.defaultPrimaryID, IPServices.defaultFallbackID)
    }
}

final class HTTPParsingTests: XCTestCase {
    private func response(_ s: String) -> Data { Data(s.utf8) }

    func testContentLengthBody() throws {
        let body = try HTTPClient.body(from: response("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello")
    }

    func testChunkedBody() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\n\r\n"
        XCTAssertEqual(String(decoding: try HTTPClient.body(from: response(raw)), as: UTF8.self), "Wikipedia")
    }

    func testNon2xxStatusIsReported() {
        XCTAssertThrowsError(try HTTPClient.body(from: response("HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n"))) { error in
            guard case LookupError.httpStatus(429) = error else { return XCTFail("got \(error)") }
        }
    }

    func testTruncatedBodiesAreRejected() {
        XCTAssertThrowsError(try HTTPClient.body(from: response("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort")))
        XCTAssertThrowsError(try HTTPClient.body(from: response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab")))
        XCTAssertThrowsError(try HTTPClient.body(from: response("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n")))
    }
}

final class CountryTests: XCTestCase {
    func testFlagEmoji() {
        XCTAssertEqual(Country.flagEmoji("DE"), "🇩🇪")
        XCTAssertEqual(Country.flagEmoji("us"), "🇺🇸")
        XCTAssertEqual(Country.flagEmoji("X"), "🏳️")
        XCTAssertEqual(Country.flagEmoji("12"), "🏳️")
    }
}

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Updater.isVersion("1.10.0", newerThan: "1.9.9"))
        XCTAssertTrue(Updater.isVersion("2", newerThan: "1.99"))
        XCTAssertTrue(Updater.isVersion("1.2.1", newerThan: "1.2"))
        XCTAssertFalse(Updater.isVersion("1.2.0", newerThan: "1.2"))
        XCTAssertFalse(Updater.isVersion("1.1.0", newerThan: "1.2.0"))
        XCTAssertFalse(Updater.isVersion("1.2.0-beta", newerThan: "1.2.0"))
    }

    func testParseLatestReleasePicksZipAsset() throws {
        let json = #"""
        {"tag_name":"v1.3.0","html_url":"https://github.com/akominch/get-my-ip/releases/tag/v1.3.0",
         "assets":[{"name":"GetMyIP-1.3.0.zip.sha256","browser_download_url":"https://example.com/a.sha256"},
                   {"name":"GetMyIP-1.3.0.zip","browser_download_url":"https://example.com/GetMyIP-1.3.0.zip"}]}
        """#
        let release = try XCTUnwrap(Updater.parseRelease(Data(json.utf8)))
        XCTAssertEqual(release.version, "1.3.0")
        XCTAssertEqual(release.zipURL.absoluteString, "https://example.com/GetMyIP-1.3.0.zip")
    }

    func testReleaseWithoutZipIsIgnored() {
        let json = #"{"tag_name":"v1.3.0","html_url":"https://github.com/x/y","assets":[]}"#
        XCTAssertNil(Updater.parseRelease(Data(json.utf8)))
    }
}
