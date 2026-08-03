#!/usr/bin/env bash
#
# verify.sh — everything CI runs, locally.
#
# Determinism is the invariant the recording and replay design rests on, and an invariant nobody
# checks decays. This is the check, in one command, so there is no excuse not to run it.
#
# Usage:  scripts/verify.sh            all of it
#         scripts/verify.sh packages   just the Swift packages (seconds)
#         scripts/verify.sh app        just the app suite (minutes)
#         scripts/verify.sh arch       just the cross-architecture fingerprint
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Name-based, not a UUID: simulator identifiers change with every Xcode update, so a hard-coded
# `id=` goes stale and the failure looks like a test problem.
DESTINATION='platform=iOS Simulator,name=iPhone 17'
WHAT="${1:-all}"

packages() {
  echo "▸ Packages"
  for package in ATCSimKit ATCTrafficKit ATCReplayKit NetworkKit; do
    printf '  %-16s' "$package"
    if swift test --package-path "LocalPackages/$package" >/tmp/verify-$package.log 2>&1; then
      grep -Eo 'Executed [0-9]+ tests, with [0-9]+ failures' /tmp/verify-$package.log | tail -1
    else
      echo "FAILED — see /tmp/verify-$package.log"; return 1
    fi
  done
}

app() {
  echo "▸ App (unit tests only; the UI suite is slow and flaky)"
  xcodebuild test -project VectraPro.xcodeproj -scheme VectraPro \
    -destination "$DESTINATION" -only-testing:VectraProTests \
    >/tmp/verify-app.log 2>&1 \
    && echo "  TEST SUCCEEDED" \
    || { echo "  FAILED — see /tmp/verify-app.log"; grep -E 'error:|failed on' /tmp/verify-app.log | head -10; return 1; }
}

arch() {
  echo "▸ Cross-architecture determinism"
  ./scripts/arch-fingerprint.sh | tail -4
}

case "$WHAT" in
  packages) packages ;;
  app)      app ;;
  arch)     arch ;;
  all)      packages && echo && arch && echo && app ;;
  *)        echo "usage: scripts/verify.sh [all|packages|app|arch]" >&2; exit 1 ;;
esac
