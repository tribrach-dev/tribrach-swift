import Foundation
import TribrachCore
import TribrachSyntax

let usage = """
usage:
  tribrach-swift check [--manifest PATH] [--allow CODES,NAMES] [--no-missing] [--touch FILE] PATHS...
  tribrach-swift stamp [--manifest PATH] [-n] PATHS...

check  reports links, purity and drift; exit 1 on any error.
stamp  records the manifest's stamps under each //tribrach:link; with -n it
       lists stale stamps and exits 1 if there are any.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, ["check", "stamp"].contains(command) else { fail(usage) }
args.removeFirst()

var manifestPath: String?
var allow = Set<String>()
var missing = true
var dryRun = false
var touch: String?
var paths: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--manifest":
        guard !args.isEmpty else { fail(usage) }
        manifestPath = args.removeFirst()
    case "--allow":
        guard !args.isEmpty else { fail(usage) }
        allow.formUnion(args.removeFirst().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    case "--no-missing":
        missing = false
    case "--touch":
        guard !args.isEmpty else { fail(usage) }
        touch = args.removeFirst()
    case "-n":
        dryRun = true
    default:
        paths.append(a)
    }
}
if paths.isEmpty { paths = ["."] }
if manifestPath == nil { manifestPath = Check.nearestManifest(from: FileManager.default.currentDirectoryPath) }
let files = Check.swiftFiles(paths)

do {
    switch command {
    case "check":
        let diags = try Check.run(files: files, manifestPath: manifestPath, allow: allow, missing: missing)
        for d in diags { print(d) }
        if let touch { FileManager.default.createFile(atPath: touch, contents: Data()) }
        exit(diags.contains { $0.severity == .error } ? 1 : 0)
    default:
        guard let manifestPath else { fail("no \(Check.manifestName) found; pass --manifest") }
        let changes = try Check.stamp(files: files, manifestPath: manifestPath, dryRun: dryRun)
        for c in changes { print(c) }
        exit(dryRun && !changes.isEmpty ? 1 : 0)
    }
} catch {
    fail("tribrach-swift: \(error)")
}
