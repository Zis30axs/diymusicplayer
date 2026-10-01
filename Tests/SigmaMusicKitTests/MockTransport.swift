import Foundation
@testable import SigmaMusicKit

/// Answers requests from a closure (`index` is the 0-based call number) and records them.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [HTTPRequest] = []
    private let handler: @Sendable (HTTPRequest, Int) throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest, Int) throws -> HTTPResponse) {
        self.handler = handler
    }

    var requests: [HTTPRequest] {
        lock.withLock { log }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let index = lock.withLock { () -> Int in
            log.append(request)
            return log.count - 1
        }
        return try handler(request, index)
    }

    static func json(_ text: String, status: Int = 200, setCookies: [String] = []) -> HTTPResponse {
        HTTPResponse(status: status, setCookies: setCookies, body: Data(text.utf8))
    }
}

extension HTTPRequest {
    var bodyText: String {
        String(decoding: body ?? Data(), as: UTF8.self)
    }

    /// The path, query included.
    var pathAndQuery: String {
        let query = url.query.map { "?" + $0 } ?? ""
        return url.path + query
    }

    /// For an eapi request: the path, JSON and digest that were encrypted into `params`.
    func decryptedEapi() throws -> (path: String, json: JSON, digest: String) {
        let text = bodyText
        guard text.hasPrefix("params=") else { throw MusicServiceError.malformedResponse("no params") }
        let plain = try NeteaseCrypto.eapiDecrypt(hex: String(text.dropFirst("params=".count)))
        let parts = plain.components(separatedBy: NeteaseCrypto.eapiSeparator)
        guard parts.count == 3 else { throw MusicServiceError.malformedResponse("bad eapi plaintext") }
        return (parts[0], try JSON.parse(parts[1]), parts[2])
    }
}
