# Notes for Claude

- tribrach-swift is the Swift instrument for Tribrach (github.com/tribrach-dev/tribrach).
  It is an independent open-source project and must never depend on, name, or
  contain code, data or models from any application (including the
  maintainers' own apps). Requirements from apps arrive in words only.
- It reads only the core formats (manifest, vectors, annotations) and passes
  the core conformance suite in tribrach/tests/conformance. It never defines
  formats or rules of its own; format changes go to core first.
- Diagnostics use the TRS prefix and name the Lean definition, the reason and
  the fix command.
- Sign off every commit (DCO, no CLA). Agents never sign off as themselves;
  they add Co-Authored-By, and the person who asked for the change signs off.
- CI may only use GitHub-made or verified-creator actions (org policy).
