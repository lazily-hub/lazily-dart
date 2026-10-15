#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
dart_bin=${DART:-dart}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

(cd "$root" && tar -cf "$tmp/lazily-dart.tar" pubspec.yaml lib LICENSE README.md CHANGELOG.md)
mkdir -p "$tmp/lazily"
tar -xf "$tmp/lazily-dart.tar" -C "$tmp/lazily"
mkdir -p "$tmp/consumer/bin"
cp "$root/tests/core_artifact_consumer/pubspec.yaml" "$tmp/consumer/pubspec.yaml"
cp "$root/tests/core_artifact_consumer/bin/main.dart" "$tmp/consumer/bin/main.dart"
sed -i "s|__ARTIFACT__|$tmp/lazily|" "$tmp/consumer/pubspec.yaml"

(cd "$tmp/consumer" && "$dart_bin" pub get && "$dart_bin" run bin/main.dart)
if grep -R -F "$root" "$tmp/consumer/.dart_tool" >/dev/null 2>&1; then
  echo "consumer metadata references the source checkout" >&2
  exit 1
fi
