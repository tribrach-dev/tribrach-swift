import Foundation
import TribrachGen

/// `tribrach-swift gen`: each argument is Name=path to a schema.
func genMain(_ args: [String]) -> Never {
    var out: String?
    var check = false
    var specs: [(String, String)] = []
    var rest = args
    while !rest.isEmpty {
        let a = rest.removeFirst()
        switch a {
        case "-o":
            guard !rest.isEmpty else { fail(usage) }
            out = rest.removeFirst()
        case "-n":
            check = true
        default:
            guard let eq = a.firstIndex(of: "="), eq != a.startIndex else { fail("tribrach-swift gen: \(a) is not Name=schema.json") }
            specs.append((String(a[..<eq]), String(a[a.index(after: eq)...])))
        }
    }
    guard let out, !specs.isEmpty else { fail(usage) }
    let base = URL(fileURLWithPath: out).deletingLastPathComponent().standardizedFileURL.path
    do {
        let loaded = try specs.map { name, path -> Gen.Spec in
            let full = URL(fileURLWithPath: path).standardizedFileURL.path
            return Gen.Spec(name: name, source: relative(full, to: base), schema: try Data(contentsOf: URL(fileURLWithPath: path)))
        }
        let code = try Gen.generate(loaded)
        if check {
            let have = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
            if have != code {
                FileHandle.standardError.write(Data("TRS0401 \(out) is out of date with the schemas core exported (Tribrach.Schema); fix: run tribrach-swift gen without -n\n".utf8))
                exit(1)
            }
            exit(0)
        }
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try code.write(toFile: out, atomically: true, encoding: .utf8)
        exit(0)
    } catch {
        fail("TRS0402 tribrach-swift gen: \(error)")
    }
}

/// A path relative to a directory, with ../ as needed.
func relative(_ path: String, to base: String) -> String {
    let p = path.split(separator: "/")
    let b = base.split(separator: "/")
    var i = 0
    while i < p.count, i < b.count, p[i] == b[i] { i += 1 }
    return (Array(repeating: "..", count: b.count - i) + p[i...].map(String.init)).joined(separator: "/")
}
