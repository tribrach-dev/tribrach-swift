# tribrach-swift

The Swift instrument for [Tribrach](https://github.com/tribrach-dev/tribrach).
Pre-alpha; nothing is released yet.

Planned (see the core architecture):

- a SwiftSyntax analyzer for links, purity and drift, run by a SwiftPM
  build-tool plugin on every build with inline Xcode errors;
- a command plugin that records the manifest's stamps next to each linked
  function (the build sandbox can't write the package);
- `TribrachReplay`, a table-driven replay harness for exported vectors.

The tools live in this package, separate from the app's own packages, so
they never form a dependency cycle with it.

Licence: Apache-2.0. Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md).
