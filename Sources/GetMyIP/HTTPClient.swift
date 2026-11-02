import Foundation
import Network
import Security

final class HTTPClient {
    private static let queue = DispatchQueue(label: "getmyip.http")

    static func get(_ url: URL, interface: NWInterface?, timeout: TimeInterval,
                    completion: @escaping (Result<Data, LookupError>) -> Void) {
        queue.async {
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? (scheme == "https" ? 443 : 80)) ?? 0),
                  port.rawValue != 0 else {
                DispatchQueue.main.async { completion(.failure(.invalidResponse("Invalid HTTP URL"))) }
                return
            }
            let parameters: NWParameters
            if scheme == "https" {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
                parameters = NWParameters(tls: tls)
            } else {
                parameters = .tcp
            }
            parameters.requiredInterface = interface
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
            let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
            let target = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
            let hostHeader = host + (url.port.map { ":\($0)" } ?? "")
            let request = Data(("GET \(target) HTTP/1.1\r\nHost: \(hostHeader)\r\n" +
                                "User-Agent: GetMyIP/1.0\r\nAccept: */*\r\nConnection: close\r\n\r\n").utf8)
            Request(connection: connection, completion: completion).start(request, timeout: timeout)
        }
    }

    // All mutable request state is confined to the shared serial queue.
    private final class Request {
        let connection: NWConnection
        var completion: ((Result<Data, LookupError>) -> Void)?
        var deadline: DispatchWorkItem?
        var response = Data()

        init(connection: NWConnection, completion: @escaping (Result<Data, LookupError>) -> Void) {
            self.connection = connection
            self.completion = completion
        }

        func start(_ request: Data, timeout: TimeInterval) {
            let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(.timeout)) }
            self.deadline = deadline
            queue.asyncAfter(deadline: .now() + max(0, timeout), execute: deadline)
            connection.stateUpdateHandler = { state in
                guard self.completion != nil else { return }
                switch state {
                case .ready:
                    self.connection.send(content: request, completion: .contentProcessed { error in
                        if let error = error {
                            self.finish(.failure(.network(error.localizedDescription)))
                        } else {
                            self.receive()
                        }
                    })
                case .waiting(let error), .failed(let error):
                    self.finish(.failure(.network(error.localizedDescription)))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        func receive() {
            guard completion != nil else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                guard self.completion != nil else { return }
                if let data = data { self.response.append(data) }
                if let error = error {
                    self.finish(.failure(.network(error.localizedDescription)))
                } else if complete {
                    do {
                        self.finish(.success(try HTTPClient.body(from: self.response)))
                    } catch let error as LookupError {
                        self.finish(.failure(error))
                    } catch {
                        self.finish(.failure(.invalidResponse(error.localizedDescription)))
                    }
                } else {
                    self.receive()
                }
            }
        }

        func finish(_ result: Result<Data, LookupError>) {
            guard let completion = completion else { return }
            self.completion = nil
            deadline?.cancel()
            deadline = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            response.removeAll()
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func body(from response: Data) throws -> Data {
        let crlf = Data([13, 10])
        guard let separator = response.range(of: Data([13, 10, 13, 10])),
              let header = String(data: response[..<separator.lowerBound], encoding: .isoLatin1) else {
            throw LookupError.invalidResponse("Missing HTTP headers")
        }
        let lines = header.components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(status[0])),
              status[1].count == 3, let code = Int(status[1]) else {
            throw LookupError.invalidResponse("Invalid HTTP status line")
        }
        guard (200..<300).contains(code) else { throw LookupError.httpStatus(code) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw LookupError.invalidResponse("Invalid HTTP header")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + "," + value } ?? value
        }
        let body = response.subdata(in: separator.upperBound..<response.endIndex)
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased().trimmingCharacters(in: .whitespaces) == "chunked" else {
                throw LookupError.invalidResponse("Unsupported transfer encoding")
            }
            var decoded = Data()
            var cursor = body.startIndex
            while cursor < body.endIndex {
                guard let end = body.range(of: crlf, in: cursor..<body.endIndex),
                      let line = String(data: body[cursor..<end.lowerBound], encoding: .ascii),
                      let sizeText = line.split(separator: ";", maxSplits: 1).first,
                      !sizeText.isEmpty, sizeText.utf8.allSatisfy({
                          (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                      }), let size = Int(sizeText, radix: 16) else {
                    throw LookupError.invalidResponse("Invalid chunk size")
                }
                cursor = end.upperBound
                if size == 0 {
                    // Consume optional trailer fields and their terminating empty line.
                    while let end = body.range(of: crlf, in: cursor..<body.endIndex) {
                        if end.lowerBound == cursor {
                            guard end.upperBound == body.endIndex else {
                                throw LookupError.invalidResponse("Data after chunk trailers")
                            }
                            return decoded
                        }
                        guard body[cursor..<end.lowerBound].contains(58) else {
                            throw LookupError.invalidResponse("Invalid chunk trailer")
                        }
                        cursor = end.upperBound
                    }
                    throw LookupError.invalidResponse("Truncated chunk trailers")
                }
                guard size <= body.endIndex - cursor, body.endIndex - cursor - size >= 2,
                      body[cursor + size] == 13, body[cursor + size + 1] == 10 else {
                    throw LookupError.invalidResponse("Truncated chunk")
                }
                decoded.append(body[cursor..<cursor + size])
                cursor += size + 2
            }
            throw LookupError.invalidResponse("Missing final chunk")
        }
        if let length = headers["content-length"] {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
                  let expected = Int(length), expected == body.count else {
                throw LookupError.invalidResponse("Content-Length mismatch")
            }
        }
        return body
    }
}
