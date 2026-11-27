import Foundation
import ParkingContracts
import TribrachWire

/// Calls meters.start v1. The client speaks only v1; core proves a v2
/// server answers it exactly as a v1 server would (Meters.v2_serves_v1).
public struct MetersClient: Sendable {
    /// Sends a request body and returns the status and response body.
    public typealias Transport = @Sendable (_ path: String, _ body: Data) async throws -> (Int, Data)

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The server refused the request as malformed (400).
        case badRequest(String)
        case status(Int, String)

        public var description: String {
            switch self {
            case let .badRequest(why): return "meters refused the request: \(why)"
            case let .status(code, body): return "meters answered \(code): \(body)"
            }
        }
    }

    let transport: Transport

    public init(transport: @escaping Transport) { self.transport = transport }

    /// A client for a meters server at `base`, such as http://localhost:8080.
    public init(base: URL, session: URLSession = .shared) {
        self.transport = { path, body in
            var req = URLRequest(url: base.appendingPathComponent(path))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            let (data, resp) = try await session.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    }

    /// Asks for a session. The request is checked against its schema before
    /// it is sent, and the answer is checked before it is returned.
    public func start(_ request: StartRequest) async throws -> StartResponse {
        let (status, data) = try await transport("v1/start", request.encode())
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 200: return try StartResponse.decode(data)
        case 400: throw Failure.badRequest(text)
        default: throw Failure.status(status, text)
        }
    }
}

extension StartResponse {
    /// One line for people.
    public var summary: String {
        switch self {
        case let .started(s):
            let cents = s.charged
            return "Started \(s.sessionId) until \(WireInstant.format(s.expiresAt)), charged \(cents / 100).\(String(format: "%02d", Int(cents % 100)))"
        case let .rejected(r):
            return "Rejected: \(r.reason)"
        }
    }
}
