import Foundation

/// Failures the music services report themselves (transport failures surface as `URLError`).
public enum MusicServiceError: Error, Equatable, Sendable {
    /// An error status with nothing to read.
    case http(status: Int, path: String)
    /// A reply that is not the JSON/XML the endpoint is known to send.
    case malformedResponse(String)
    /// NetEase answered, but with a `code` other than 200.
    case rejected(code: Int)
    /// A track id that does not belong to the service asked.
    case invalidTrack(String)
    /// There is no online source (the offline preview).
    case offline
}

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    public var followRedirects: Bool

    public init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 10,
        followRedirects: Bool = true
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.followRedirects = followRedirects
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    /// Header names are lower-cased.
    public var headers: [String: String]
    /// One `name=value` per `Set-Cookie` header, attributes dropped.
    public var setCookies: [String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], setCookies: [String] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.setCookies = setCookies
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public var text: String {
        String(decoding: body, as: UTF8.self)
    }
}

/// The one seam between the services and the network, so they can be tested without it.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// `URLSession` without its cookie handling (the services manage their own `Cookie` header).
public final class URLSessionTransport: HTTPTransport, Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: request.timeout
        )
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let delegate: (any URLSessionTaskDelegate)? = request.followRedirects ? nil : NoRedirectDelegate()
        let (data, response) = try await session.data(for: urlRequest, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            throw MusicServiceError.malformedResponse("not an HTTP response")
        }

        var headers: [String: String] = [:]
        var cookieHeaders: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            headers[name.lowercased()] = text
            if name.lowercased() == "set-cookie" { cookieHeaders["Set-Cookie"] = text }
        }
        // `allHeaderFields` joins repeated Set-Cookie headers; HTTPCookie knows how to split them.
        let setCookies = HTTPCookie.cookies(withResponseHeaderFields: cookieHeaders, for: request.url)
            .map { "\($0.name)=\($0.value)" }
        return HTTPResponse(status: http.statusCode, headers: headers, setCookies: setCookies, body: data)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum URLEncoding {
    /// `application/x-www-form-urlencoded` escaping: everything but the unreserved characters.
    static func form(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E:
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
