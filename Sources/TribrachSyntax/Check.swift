import Foundation
import TribrachCore

/// Everything `tribrach-swift check` and `stamp` do, as a library so it can
/// be tested.
public enum Check {
    public static let manifestName = "tribrach.manifest.json"

    /// Every .swift file under the given files and directories, skipping
    /// hidden directories and build output.
    public static func swiftFiles(_ paths: [String]) -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for p in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if p.hasSuffix(".swift") { out.append(p) }
                continue
            }
            guard let e = fm.enumerator(atPath: p) else { continue }
            while let rel = e.nextObject() as? String {
                let last = (rel as NSString).lastPathComponent
                if last.hasPrefix(".") || last == "build" {
                    e.skipDescendants()
                    continue
                }
                if rel.hasSuffix(".swift") { out.append((p as NSString).appendingPathComponent(rel)) }
            }
        }
        return out.sorted()
    }

    /// The nearest manifest at or above a directory.
    public static func nearestManifest(from dir: String) -> String? {
        var url = URL(fileURLWithPath: dir).standardizedFileURL
        while true {
            let candidate = url.appendingPathComponent(manifestName).path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    public struct Scanned {
        public var files: [FileScan]
        public var diagnostics: [Diagnostic]
    }

    public static func scan(_ files: [String], allow: Set<String>) throws -> Scanned {
        let sources = try files.map { (path: $0, source: try String(contentsOfFile: $0, encoding: .utf8)) }
        let decls = Scanner.declarations(sources)
        let scans = sources.map { Scanner.scan(path: $0.path, source: $0.source, declarations: decls, allow: allow) }
        return Scanned(files: scans, diagnostics: scans.flatMap(\.diagnostics))
    }

    /// Links, purity and drift. `missing` reports manifest links with no
    /// annotated function, which only makes sense when every file that could
    /// hold them was scanned.
    public static func run(files: [String], manifestPath: String?, allow: Set<String>, missing: Bool) throws -> [Diagnostic] {
        let scanned = try scan(files, allow: allow)
        var out = scanned.diagnostics
        let linked = scanned.files.flatMap(\.functions).filter { $0.lean != nil }
        guard let manifestPath else {
            if let first = linked.first {
                out.append(Diagnostic(file: first.file, line: first.line, column: first.column, severity: .warning,
                                      code: "TRS0200", message: "no \(manifestName) found: export one from Lean, or pass --manifest"))
            }
            return out
        }
        let manifest = try Manifest.load(URL(fileURLWithPath: manifestPath))
        let hosts = linked.map { Drift.Host(symbol: $0.symbol, lean: $0.lean!, stamp: $0.stamp) }
        var links = manifest.owned()
        if !missing {
            let leanNames = Set(hosts.map(\.lean))
            links = links.filter { leanNames.contains($0.lean) }
        }
        var bySymbol: [String: LinkedFunction] = [:]
        for l in linked { bySymbol["\(l.lean!)|\(l.symbol)"] = l }
        for f in Drift.compare(owner: swiftOwner, links: links, host: hosts) {
            let fn = bySymbol["\(f.lean)|\(f.symbol)"]
            func at(_ severity: Diagnostic.Severity, _ code: String, _ message: String) {
                out.append(Diagnostic(file: fn?.file ?? manifestPath, line: fn?.line ?? 1, column: fn?.column ?? 1,
                                      severity: severity, code: code, message: message))
            }
            let name = fn?.name ?? f.symbol
            switch f.outcome {
            case .ok:
                break
            case .drift:
                at(.error, "TRS0201", "\(f.lean) changed in Lean (stamp \(f.want ?? ""), recorded \(fn?.stamp ?? "")): check \(name) against the model, run the vectors, then run `swift package tribrach-stamp`")
            case .unstamped:
                at(.warning, "TRS0202", "\(name) links \(f.lean) but records no stamp: once it matches the model, run `swift package tribrach-stamp` (it will record \(f.want ?? ""))")
            case .unknown:
                at(.error, "TRS0203", "the manifest (\((manifestPath as NSString).lastPathComponent)) has no Swift link for \(f.lean): check the Lean name, or add a link to the exporter and re-export")
            case .symbolMismatch:
                at(.error, "TRS0204", "the manifest links \(f.lean) to \(f.want ?? ""), not \(f.symbol): update the exporter's symbol and re-export, or move the annotation")
            case .missing:
                at(.error, "TRS0205", "the manifest links \(f.lean) to \(f.symbol), but no function has //tribrach:link \(f.lean)")
            }
        }
        return out
    }

    public struct StampChange: CustomStringConvertible {
        public var file: String
        public var line: Int
        public var symbol: String
        public var from: String?
        public var to: String
        public var description: String { "\(file):\(line): \(symbol) \(from ?? "(none)") -> \(to)" }
    }

    /// Record the manifest's stamps under each link. With `dryRun`, only list
    /// the stale ones.
    public static func stamp(files: [String], manifestPath: String, dryRun: Bool) throws -> [StampChange] {
        let manifest = try Manifest.load(URL(fileURLWithPath: manifestPath))
        var want: [String: String] = [:]
        for l in manifest.owned() { want["\(l.lean)|\(l.symbol)"] = l.stamp }
        let scanned = try scan(files, allow: [])
        var changes: [StampChange] = []
        for file in scanned.files {
            var edits: [(range: Range<Int>, text: String)] = []
            var bytes = Array(try String(contentsOfFile: file.path, encoding: .utf8).utf8)
            for fn in file.functions {
                guard let lean = fn.lean, let s = want["\(lean)|\(fn.symbol)"], s != fn.stamp,
                      let link = fn.linkRange else { continue }
                changes.append(StampChange(file: file.path, line: fn.line, symbol: fn.symbol, from: fn.stamp, to: s))
                let line = "//tribrach:stamp \(s)"
                if let existing = fn.stampRange {
                    edits.append((existing, line))
                } else {
                    var start = link.lowerBound
                    while start > 0 && bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
                    let indent = String(decoding: bytes[start..<link.lowerBound], as: UTF8.self)
                    edits.append((link.upperBound..<link.upperBound, "\n" + indent + line))
                }
            }
            guard !dryRun, !edits.isEmpty else { continue }
            for e in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                bytes.replaceSubrange(e.range, with: Array(e.text.utf8))
            }
            try Data(bytes).write(to: URL(fileURLWithPath: file.path))
        }
        return changes
    }
}
