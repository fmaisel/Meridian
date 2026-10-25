#!/bin/sh
# Builds the offline audio harness against the app's DSP sources (macOS command-line tool).
# Usage: ./build.sh [-Onone]   then   ./.build/AudioCheck [output-dir]
set -e
cd "$(dirname "$0")"
OPT="${1:--O}"
SRC=../../MeridianNative/Audio
mkdir -p .build
xcrun --sdk macosx swiftc $OPT -wmo -swift-version 5 -target arm64-apple-macos15.0 \
  $SRC/SynthPrimitives.swift $SRC/SynthReverb.swift $SRC/SynthCompressor.swift $SRC/SynthCore.swift $SRC/AudioManager.swift \
  main.swift -o .build/AudioCheck
