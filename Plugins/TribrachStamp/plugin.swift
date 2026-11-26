import Foundation
import PackagePlugin

/// `swift package tribrach-stamp [-n]` records the manifest's stamps under
/// each //tribrach:link in the package. Run it deliberately, after the code
/// has been checked against the model and the vectors pass. It runs as a
/// command because build plugins can't write to the package.
@main
struct TribrachStamp: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "tribrach-swift")
        let root = context.package.directoryURL
        var args = ["stamp"] + arguments
        if !arguments.contains("--manifest") {
            let manifest = root.appendingPathComponent("tribrach.manifest.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                args += ["--manifest", manifest.path]
            }
        }
        args.append(root.path)
        let process = Process()
        process.executableURL = tool.url
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Diagnostics.error(arguments.contains("-n")
                ? "stale stamps listed above"
                : "tribrach-swift stamp exited with \(process.terminationStatus)")
        }
    }
}
