import Foundation
import ParkClient
import ParkingContracts
import TribrachWire
import XCTest

/// The vendored core exports, at the package root.
let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("core")

func load(_ path: String) throws -> [String: WireValue] {
    guard case let .object(o) = try WireValue.parse(Data(contentsOf: core.appendingPathComponent(path))) else {
        throw WireError(schema: path, path: "", reason: "not an object")
    }
    return o
}

extension WireValue {
    var items: [WireValue] { if case let .array(a) = self { return a } else { return [] } }
    subscript(_ key: String) -> WireValue? { if case let .object(o) = self { return o[key] } else { return nil } }
    var string: String? { if case let .string(s) = self { return s } else { return nil } }
}

/// Decode, and decode-then-encode, for each contract.
struct Codec {
    let decode: (Data) throws -> Void
    let reencode: (Data) throws -> Data
}

func codec<T>(_ dec: @escaping (Data) throws -> T, _ enc: @escaping (T) throws -> Data) -> Codec {
    Codec(decode: { _ = try dec($0) }, reencode: { try enc(dec($0)) })
}

var codecs: [String: Codec] {
    [
        "payments.authorize.request": codec(AuthorizeRequest.decode, { try $0.encode() }),
        "payments.authorize.response": codec(AuthorizeResponse.decode, { try $0.encode() }),
        "meters.start.v1.request": codec(StartRequest.decode, { try $0.encode() }),
        "meters.start.v1.response": codec(StartResponse.decode, { try $0.encode() }),
        "meters.start.v2.request": codec(StartRequestV2.decode, { try $0.encode() }),
        "meters.start.v2.response": codec(StartResponseV2.decode, { try $0.encode() }),
    ]
}

final class ParkingTests: XCTestCase {
    /// The generated decoders against Lean: each accepts exactly the
    /// messages core's schema accepts.
    func testVerdicts() throws {
        var total = 0
        for (name, c) in codecs.sorted(by: { $0.key < $1.key }) {
            let file = try load("verdicts/\(name).json")
            XCTAssertEqual(file["format"], .string("tribrach.verdicts.v1"))
            for k in file["cases"]?.items ?? [] {
                total += 1
                let doc = try XCTUnwrap(k["doc"])
                var why = ""
                do { try c.decode(doc.data) } catch { why = "\(error)" }
                XCTAssertEqual(why.isEmpty, k["accept"] == .bool(true),
                               "\(name): Swift accepts=\(why.isEmpty), Lean accepts=\(k["accept"]!) on \(doc.text) \(why)")
            }
        }
        XCTAssertGreaterThan(total, 1000, "is core/ vendored?")
    }

    /// Every message in the exchanges decodes and writes back as the same JSON.
    func testRoundTrips() throws {
        for (file, prefix) in [("payments.authorize", "payments.authorize"), ("meters.start.v1", "meters.start.v1"), ("meters.start.v2", "meters.start.v2")] {
            let f = try load("exchanges/\(file).json")
            XCTAssertEqual(f["format"], .string("tribrach.exchanges.v1"))
            for k in f["cases"]?.items ?? [] {
                let id = k["id"]?.string ?? "?"
                func check(_ name: String, _ doc: WireValue?) throws {
                    let doc = try XCTUnwrap(doc, "\(file) \(id)")
                    let back = try WireValue.parse(try XCTUnwrap(codecs[name]).reencode(doc.data))
                    XCTAssertEqual(back, doc, "\(file) \(id): \(doc.text) came back as \(back.text)")
                }
                if k["status"] != .number("200") {
                    XCTAssertThrowsError(try codecs["\(prefix).request"]!.decode(k["request"]!.data), "\(file) \(id)")
                    continue
                }
                try check("\(prefix).request", k["request"])
                try check("\(prefix).response", k["response"])
                for call in k["calls"]?.items ?? [] {
                    let c = call["contract"]?.string ?? ""
                    try check("\(c).request", call["request"])
                    try check("\(c).response", call["response"])
                }
            }
        }
    }

    /// The client against core's v1 exchanges: for each case it can send, it
    /// sends exactly the recorded request and reads the recorded answer.
    func testClientReplaysExchanges() async throws {
        let f = try load("exchanges/meters.start.v1.json")
        var sent = 0
        for k in f["cases"]?.items ?? [] {
            let id = k["id"]?.string ?? "?"
            let recorded = try XCTUnwrap(k["request"])
            // The client can only build requests its schema accepts; the
            // 400 cases are the server's to refuse.
            guard let request = try? StartRequest.decode(recorded.data) else {
                XCTAssertNotEqual(k["status"], .number("200"), id)
                continue
            }
            let response = try XCTUnwrap(k["response"], id)
            let client = MetersClient { path, body in
                XCTAssertEqual(path, "v1/start")
                XCTAssertEqual(try WireValue.parse(body), recorded, "\(id): sent a different request")
                return (200, response.data)
            }
            let answer = try await client.start(request)
            XCTAssertEqual(answer, try StartResponse.decode(response.data), id)
            sent += 1
        }
        XCTAssertGreaterThan(sent, 2)
    }

    func testClientRefusesBadRequestsBeforeSending() async {
        let client = MetersClient { _, _ in
            XCTFail("sent a request its schema rejects")
            return (500, Data())
        }
        for bad in [StartRequest(zone: "A1", plate: "abc123", minutes: 60),
                    StartRequest(zone: "Z9", plate: "ABC123", minutes: 60),
                    StartRequest(zone: "A1", plate: "ABC123", minutes: 50)] {
            do {
                _ = try await client.start(bad)
                XCTFail("accepted \(bad)")
            } catch {
                XCTAssertTrue(error is WireError, "\(error)")
            }
        }
    }

    func testSummary() throws {
        let r = try StartResponse.decode(Data(#"{"charged":"2000","expiresAt":"2026-11-26T23:30:00Z","result":"started","sessionId":"s-1001","startsAt":"2026-11-26T19:30:00Z"}"#.utf8))
        XCTAssertEqual(r.summary, "Started s-1001 until 2026-11-26T23:30:00Z, charged 20.00")
    }
}
