#!/bin/zsh
# Builds tools/nameprobe against Core: which names survive the sound gate on
# the second ear's prompt, answered on the first ear's real transcripts.
set -e
cd "$(dirname "$0")/../.."
OUT=build/tools
mkdir -p $OUT
swiftc -O -swift-version 6 -target arm64-apple-macos26.0 -parse-as-library \
  -emit-module -emit-library -module-name ChalantDictationCore \
  -emit-module-path $OUT/ChalantDictationCore.swiftmodule \
  Sources/ChalantDictationCore/*/*.swift -o $OUT/libChalantDictationCore.dylib
swiftc -O -swift-version 6 -target arm64-apple-macos26.0 \
  -I $OUT -L $OUT -lChalantDictationCore -Xlinker -rpath -Xlinker @executable_path \
  tools/nameprobe/main.swift -o $OUT/nameprobe
echo "built $OUT/nameprobe"
