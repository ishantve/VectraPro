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
  for package in SimDeterminism ATCSimKit ATCTrafficKit ATCReplayKit NetworkKit; do
    printf '  %-16s' "$package"
    if swift test --package-path "LocalPackages/$package" >/tmp/verify-$package.log 2>&1; then
      # The largest count, not the last line: `swift test` prints a summary per suite as well as one
      # overall, and which comes last is not fixed — reading `tail -1` reported a single suite's
      # total as the whole package's, which looked like tests had vanished.
      grep -Eo 'Executed [0-9]+ tests' /tmp/verify-$package.log \
        | awk '{ if ($2 > max) max = $2 } END { print max " tests" }'
      # Anchored on "failures", because a skipped-test summary also has a number after "with" —
      # matching that reported failures in a suite that had none.
      grep -qE 'with [1-9][0-9]* failure' /tmp/verify-$package.log \
        && { echo "    HAS FAILURES — see /tmp/verify-$package.log"; return 1; } || true
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

metrics() {
  echo "▸ Recording metrics (exit validation)"
  xcodebuild test -project VectraPro.xcodeproj -scheme VectraPro \
    -destination "$DESTINATION" -only-testing:VectraProTests/RecordingMetricsTests \
    >/tmp/verify-metrics.log 2>&1 || { echo "  FAILED — see /tmp/verify-metrics.log"; return 1; }

  # The figures are XCTAttachments, not console output: a print from a test does not survive into the
  # result bundle, and a measurement nobody can read is not a measurement.
  local bundle out
  bundle=$(ls -td ~/Library/Developer/Xcode/DerivedData/VectraPro-*/Logs/Test/*.xcresult | head -1)
  out=$(mktemp -d)
  for name in testCaptureEventCountsAndStorageGrowth testCaptureRecordingOverhead \
              testCaptureSealPerformance testCaptureMemoryProfile; do
    xcrun xcresulttool export attachments --path "$bundle" \
      --test-id "RecordingMetricsTests/$name()" --output-path "$out/$name" >/dev/null 2>&1
    cat "$out/$name"/*.txt 2>/dev/null
    echo
  done
  rm -rf "$out"
}

case "$WHAT" in
  packages) packages ;;
  metrics)  metrics ;;
  app)      app ;;
  arch)     arch ;;
  all)      packages && echo && arch && echo && app ;;
  *)        echo "usage: scripts/verify.sh [all|packages|app|arch|metrics]" >&2; exit 1 ;;
esac
