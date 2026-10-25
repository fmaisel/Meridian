#!/bin/sh
# Renders the scripted session with the original WebAudio code in headless Chrome (OfflineAudioContext)
# and compares it with the native render written by AudioCheck. Run AudioCheck first.
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-/private/tmp/claude-501/-Users-fmaisel-Development-Videospiele-Monument-Valley/d5efd4f3-e050-4b08-8461-78797b72de55/scratchpad}"
TS="$HERE/../../../../../src/game/Audio.ts"
PAGE="$OUT/webaudio_reference.html"
LOG="$OUT/webaudio_reference.log"
node --no-warnings -e '
const m = require("node:module"), fs = require("fs");
const js = m.stripTypeScriptTypes(fs.readFileSync(process.argv[1], "utf8"), { mode: "strip" }).replace(/^export /m, "");
const page = "<!doctype html><meta charset=utf-8><script>\nconst NATIVE_URL = " + JSON.stringify("file://" + process.argv[3] + "/meridian_native_session.f32") + ";\n" + js + "\n</script><script>\n" + fs.readFileSync(process.argv[2], "utf8") + "\n</script>";
fs.writeFileSync(process.argv[4], page);
' "$TS" "$HERE/harness.js" "$OUT" "$PAGE" || exit 1
PROFILE="$OUT/chrome-profile"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --no-first-run \
  --user-data-dir="$PROFILE" --allow-file-access-from-files --enable-logging=stderr --v=0 "file://$PAGE" > "$LOG" 2>&1 &
PID=$!
i=0
while [ $i -lt 240 ] && ! grep -q '\[ref\] DONE' "$LOG"; do sleep 1; i=$((i + 1)); done
kill $PID 2>/dev/null
grep -o '\[ref\] [^"]*' "$LOG" | sed 's/^\[ref\] //'
