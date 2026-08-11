#!/usr/bin/env bash
#
# arch-fingerprint.sh
#
# Answers the question the replay architecture could not answer on paper: does this simulator
# compute the same aircraft positions on a different CPU architecture?
#
# It matters because an assessment is recorded on one device and reviewed on another. Every position
# in this simulator comes out of great-circle maths, and sin/cos/atan2 are library functions rather
# than hardware instructions, so their last bits are not guaranteed to agree across architectures. If
# they disagree, a replay is not quite what the trainee flew and must not be scored.
#
# Builds ATCSimKit's self-check as a small executable for arm64 and x86_64 and compares the
# fingerprints. On Apple Silicon the x86_64 build runs under Rosetta.
#
# Usage:  scripts/arch-fingerprint.sh
# Exit 0 when the architectures agree, 1 when they do not.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Sources/probe"

cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "probe",
    platforms: [.macOS(.v12)],
    dependencies: [.package(path: "$ROOT/LocalPackages/ATCSimKit")],
    targets: [.executableTarget(name: "probe", dependencies: ["ATCSimKit"])]
)
EOF

cat > "$WORK/Sources/probe/main.swift" <<'EOF'
import ATCSimKit
print(String(format: "%016llX", DeterminismSelfCheck.fingerprint()))
EOF

cd "$WORK"

echo "▸ Building the self-check for both architectures…"
swift build --arch arm64  -c release >/dev/null
swift build --arch x86_64 -c release >/dev/null

ARM64="$(./.build/arm64-apple-macosx/release/probe)"
# Rosetta, so the x86_64 binary can run on an Apple Silicon host.
X86_64="$(arch -x86_64 ./.build/x86_64-apple-macosx/release/probe)"

echo
echo "  arm64   0x$ARM64"
echo "  x86_64  0x$X86_64"
echo

if [[ "$ARM64" == "$X86_64" ]]; then
  echo "✅ The architectures agree. Cross-device replay may be scored."
  exit 0
fi

cat <<EOF
❌ The architectures disagree.

A session recorded on one architecture cannot be scored against a replay on the other. Either
restrict scoring to matching architectures, or make the geodesy bit-portable (fixed-point or a
soft-float path through GeoNavKit) — see docs/architecture/replay-engine.md §22.1.
EOF
exit 1
