#!/bin/zsh
# Builds tools/transcribe against Core, for E0: files through the shipping engine.
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
  tools/transcribe/main.swift -o $OUT/transcribe
echo "built $OUT/transcribe"
