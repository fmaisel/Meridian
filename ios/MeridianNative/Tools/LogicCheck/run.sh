#!/bin/sh
# Builds the logic harness with the app's Logic sources and runs dump diff + tests.
set -e
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/meridian-logiccheck"
mkdir -p "$OUT"
swiftc -O -o "$OUT/LogicCheck" main.swift ../../MeridianNative/Logic/*.swift
(cd ../../../.. && npx vite-node ios/MeridianNative/Tools/LogicCheck/dump.ts > "$OUT/ts.txt")
"$OUT/LogicCheck" dump > "$OUT/swift.txt"
if diff -q "$OUT/ts.txt" "$OUT/swift.txt" >/dev/null; then echo "dump identical ($(wc -l < "$OUT/ts.txt") lines)"; else echo "DUMP DIFFERS: diff $OUT/ts.txt $OUT/swift.txt"; exit 1; fi
"$OUT/LogicCheck" test
