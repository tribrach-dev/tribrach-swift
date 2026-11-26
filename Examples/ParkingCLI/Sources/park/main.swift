import Foundation
import ParkClient
import ParkingContracts

let usage = """
usage: park --zone ZONE --plate PLATE --minutes N [--server URL]

Asks a meters server (meters.start v1) for a parking session. Zones are
A1, B2 and C3; minutes are 15 to 240 in steps of 15; plates are 2 to 8
capital letters and digits. The request is checked against its schema
before it is sent.
"""

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var zone: String?
var plate: String?
var minutes: Int64?
var server = ProcessInfo.processInfo.environment["PARK_SERVER"] ?? "http://localhost:8080"
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    guard !args.isEmpty else { fail(usage) }
    let v = args.removeFirst()
    switch a {
    case "--zone": zone = v
    case "--plate": plate = v
    case "--minutes": minutes = Int64(v)
    case "--server": server = v
    default: fail(usage)
    }
}
guard let zone, let plate, let minutes, let base = URL(string: server) else { fail(usage) }

let client = MetersClient(base: base)
do {
    let answer = try await client.start(StartRequest(zone: zone, plate: plate, minutes: minutes))
    print(answer.summary)
    if case .rejected = answer { exit(1) }
} catch {
    fail("park: \(error)", code: 1)
}
