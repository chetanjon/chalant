#!/bin/zsh
# Builds tools/mergeprobe against Core: what the merge would have done to
# words that already landed, swept over recorded audio.
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
  tools/mergeprobe/main.swift -o $OUT/mergeprobe
echo "built $OUT/mergeprobe"
