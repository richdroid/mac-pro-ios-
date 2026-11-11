#!/bin/bash
# The Chumby app's alarm rules, tested on the Mac with plain swiftc: the files under test import only Foundation.
# Usage: ci/chumby-tests.sh   (exit 0 and "ok: N checks" when everything passes)
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
S=ChumbyApp/Sources
cp ChumbyApp/Tests/AlarmLogicTests.swift "$OUT/main.swift"
swiftc -swift-version 5 -O -o "$OUT/tests" "$S/ChumbyAPI.swift" "$S/CalendarPlanner.swift" "$S/AlarmChange.swift" "$OUT/main.swift" 2>&1 | grep -E "error|warning: unre" || true
TZ=America/New_York "$OUT/tests"
