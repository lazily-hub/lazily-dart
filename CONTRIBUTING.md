# Contributing to lazily-dart

## Verify a change

```bash
dart pub get
dart analyze --fatal-infos
dart test
```

`dart test` builds
[`lazily-formal`](https://github.com/lazily-hub/lazily-formal) (Lean proofs)
when the sibling checkout and `lake` toolchain are present, and skips it
otherwise. To verify the proofs in a standalone clone:

```bash
git clone https://github.com/lazily-hub/lazily-formal.git ../lazily-formal
# (or) set LAZILY_FORMAL_PATH=/path/to/lazily-formal
dart run tool/formal_check.dart
```
