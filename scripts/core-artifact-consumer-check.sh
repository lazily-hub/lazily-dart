#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
dart_bin=${DART:-dart}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/consumer/bin"
cp "$root/tests/core_artifact_consumer/pubspec.yaml.in" "$tmp/consumer/pubspec.yaml"
cp "$root/tests/core_artifact_consumer/bin/main.dart" "$tmp/consumer/bin/main.dart"
if [ -n "${LAZILY_CORE_ARTIFACT_VERSION:-}" ]; then
  sed -i "s|__DEPENDENCY__|version: $LAZILY_CORE_ARTIFACT_VERSION|" "$tmp/consumer/pubspec.yaml"
else
  (cd "$root" && tar -cf "$tmp/lazily-dart.tar" pubspec.yaml lib LICENSE README.md CHANGELOG.md)
  mkdir -p "$tmp/lazily"
  tar -xf "$tmp/lazily-dart.tar" -C "$tmp/lazily"
  sed -i "s|__DEPENDENCY__|path: $tmp/lazily|" "$tmp/consumer/pubspec.yaml"
fi

(cd "$tmp/consumer" && "$dart_bin" pub get && "$dart_bin" run bin/main.dart)
if grep -R -F "$root" "$tmp/consumer/.dart_tool" >/dev/null 2>&1; then
  echo "consumer metadata references the source checkout" >&2
  exit 1
fi
if [ -n "${LAZILY_CORE_ARTIFACT_VERSION:-}" ]; then
  (cd "$tmp/consumer" && "$dart_bin" pub deps --json) |
    python3 -c '
import json, sys
data = json.load(sys.stdin)
version = sys.argv[1]
packages = [item for item in data["packages"] if item["name"] == "lazily"]
if len(packages) != 1 or packages[0]["version"] != version:
    raise SystemExit("consumer did not resolve the exact Lazily version")
if packages[0].get("kind") != "direct":
    raise SystemExit("consumer did not resolve Lazily as a direct hosted package")
' "$LAZILY_CORE_ARTIFACT_VERSION"
fi
