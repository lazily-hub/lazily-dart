# Contributing to lazily-dart

## Verify a change

```bash
make check
```

`make check` is the canonical local gate. Its formatter step resolves
dependencies before invoking `dart format`, because Dart reads the package's
declared language version from `.dart_tool/package_config.json`; running the
formatter first in a clean checkout can report spurious mass drift. To apply
the same pinned formatting policy, run `make fmt-fix`.

`dart test` builds
[`lazily-formal`](https://github.com/lazily-hub/lazily-formal) (Lean proofs)
when the sibling checkout and `lake` toolchain are present, and skips it
otherwise. To verify the proofs in a standalone clone:

```bash
git clone https://github.com/lazily-hub/lazily-formal.git ../lazily-formal
# (or) set LAZILY_FORMAL_PATH=/path/to/lazily-formal
dart run tool/formal_check.dart
```
