#!/bin/zsh
# Builds tools/textpath against the SHIPPING sources: Core as a module, then
# the app's own FoundationModelsPolisher.swift and Cleanup.swift linked in, so
# the offline path cannot drift from the one DictationController runs.
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
  -framework FoundationModels \
  ChalantDictationApp/Polish/FoundationModelsPolisher.swift ChalantDictationApp/Cleanup.swift \
  tools/textpath/main.swift -o $OUT/textpath
echo "built $OUT/textpath"
