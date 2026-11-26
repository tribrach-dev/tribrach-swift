import Foundation
import PackagePlugin

/// Runs `tribrach-swift check` on a target's Swift files on every build, so
/// link, purity and drift problems appear inline. Manifest links that no
/// file in this target annotates aren't reported here, because they may
/// live in another target; run `swift run tribrach-swift check` over the
/// whole package for that.
@main
struct TribrachCheck: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let source = target as? SourceModuleTarget else { return [] }
        let files = source.sourceFiles(withSuffix: "swift").map(\.url)
        return try command(
            tool: context.tool(named: "tribrach-swift").url,
            work: context.pluginWorkDirectoryURL,
            name: target.name,
            files: files,
            // Start from the target's first source file: Target.directoryURL
            // needs PackageDescription 6.1.
            manifest: findManifest(
                from: files.first?.deletingLastPathComponent() ?? context.package.directoryURL,
                stopAt: context.package.directoryURL))
    }
}

func command(tool: URL, work: URL, name: String, files: [URL], manifest: URL?) -> [Command] {
    let touched = work.appendingPathComponent("tribrach-check-\(name).done")
    var args = ["check", "--no-missing", "--touch", touched.path]
    var inputs = files
    if let manifest {
        args += ["--manifest", manifest.path]
        inputs.append(manifest)
    }
    args += files.map(\.path)
    return [.buildCommand(
        displayName: "Tribrach check \(name)",
        executable: tool,
        arguments: args,
        inputFiles: inputs,
        outputFiles: [touched])]
}

/// The nearest tribrach.manifest.json from a directory up to `stopAt`.
func findManifest(from dir: URL, stopAt root: URL) -> URL? {
    var url = dir.standardizedFileURL
    let stop = root.standardizedFileURL.path
    while true {
        let candidate = url.appendingPathComponent("tribrach.manifest.json")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        if url.path == stop || url.path == "/" { return nil }
        url = url.deletingLastPathComponent()
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension TribrachCheck: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        let files = target.inputFiles.filter { $0.url.pathExtension == "swift" }.map(\.url)
        let root = context.xcodeProject.directoryURL
        return try command(
            tool: context.tool(named: "tribrach-swift").url,
            work: context.pluginWorkDirectoryURL,
            name: target.displayName,
            files: files,
            manifest: findManifest(from: root, stopAt: root))
    }
}
#endif
