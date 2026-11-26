# tribrach-swift

The Swift instrument for [Tribrach](https://github.com/tribrach-dev/tribrach).
Pre-alpha; nothing is released yet.

It reads the manifest and vectors a project exports from Lean
(`Tribrach.Export` in core) and checks Swift code against them.

## Annotate

```swift
public enum Counter {
    /// Applies one operation, never going above `max`.
    //tribrach:link Counter.counterStep
    //tribrach:stamp c5f9ea973150248a
    public static func step(_ op: Op, in n: Int, max: Int) -> Int { … }
}
```

- `//tribrach:link <LeanName>` links the function to a Lean definition. A
  linked function must be pure.
- `//tribrach:pure` marks a helper that linked code may call.
- `//tribrach:stamp` records the Lean stamp the function was last checked
  against. The stamp command writes it; don't edit it by hand.

The directives go in plain `//` comments directly above the `func`. `///`
documentation comments stay prose. Symbols are written
`Type.name(labels:)`, for example `Counter.step(_:in:max:)`, or
`name(labels:)` for free functions.

## Check on every build

Add the build-tool plugin to each target that holds linked code:

```swift
.package(url: "https://github.com/tribrach-dev/tribrach-swift", branch: "main"),
…
.target(name: "Core", plugins: [.plugin(name: "TribrachCheck", package: "tribrach-swift")]),
```

The plugin uses the nearest `tribrach.manifest.json` from the target's
directory up to the package root. Problems show inline in Xcode and
`swift build`. Xcode asks you to trust the plugin on first use; command-line
`xcodebuild` needs `-skipPackagePluginValidation`.

A target can't see the links that live in other targets, so the plugin
doesn't report missing links. Check the whole package with:

```sh
swift run tribrach-swift check [--allow TRS0306,print] Sources
```

| Code | Meaning |
| --- | --- |
| TRS0101 | A directive can't be read |
| TRS0102 | A directive isn't directly above a function |
| TRS0103 | A function links two Lean definitions |
| TRS0104 | A stamp without a link |
| TRS0200 | No manifest found |
| TRS0201 | Drift: the Lean definition changed since the recorded stamp |
| TRS0202 | A link with no recorded stamp (warning) |
| TRS0203 | The manifest has no Swift link for this Lean name |
| TRS0204 | The manifest links this Lean name to another symbol |
| TRS0205 | The manifest links a symbol that isn't annotated (whole-package check only) |
| TRS0301 | Clock reads in pure code (`Date()`, `Date.now`, …) |
| TRS0302 | Randomness (`.random`, `UUID()`, …) |
| TRS0303 | I/O (`print`, `FileManager`, `URLSession`, `UserDefaults`, …) |
| TRS0304 | Global or static variables |
| TRS0305 | `async`, `await`, `Task`, Dispatch |
| TRS0306 | Iterating over `.keys` or `.values` (unordered) |
| TRS0307 | Calling a function in the scanned files that isn't marked pure |
| TRS0308 | A file holding pure functions imports something other than Foundation |

Purity is checked from the syntax alone, so it matches names. The lists
cover the usual Foundation entry points. `--allow` silences a code or a
name, and each message gives the reason in the model's terms.

## Stamp deliberately

```sh
swift package tribrach-stamp -n   # list stale stamps
swift package --allow-writing-to-package-directory tribrach-stamp
```

This is a command plugin, because build plugins can't write to the package.
Stamps sit next to each function, never in a shared file, so stamping one
target can't disturb another's.

## Replay

`TribrachReplay` runs exported vectors against your code. Write a
`ReplayHarness` that starts from a state, applies operations
(`{"op": name, …}`) and reports its state; then:

```swift
for result in try Replay.check(Vectors.load(url), harness: { CounterHarness(max: 3) }) {
    XCTAssertTrue(result.passed, result.description)
}
```

A failure names the first differing step, the operation, and the model's
and the code's states. `Examples/Counter` also shows a check that the vectors
catch an off-by-one.

## Conformance

`Tests/TribrachCoreTests/core` is a copy of `tribrach/tests/conformance` at
the commit in `CORE_REV`. CI checks the copy.

Licence: Apache-2.0. Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md).
