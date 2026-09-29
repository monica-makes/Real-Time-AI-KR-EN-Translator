#!/bin/zsh
# Build and run the iOS network-layer harness against the real app sources.
#   tests/ios_harness/run.sh offline
#   tests/ios_harness/run.sh live ROOM01 /path/to/english_16k_mono.wav [ws://localhost:8001/ws/translate]
set -e
HERE="${0:A:h}"
REPO="$HERE/../.."
NET="$REPO/KorEngTranslator/KorEngTranslator/Network"
BUILD="${TMPDIR:-/tmp}/kr-ios-harness"
mkdir -p "$BUILD"
xcrun swiftc -swift-version 5 -o "$BUILD/harness" \
    "$NET/MessageTypes.swift" "$NET/WebSocketManager.swift" "$HERE/main.swift"
exec "$BUILD/harness" "$@"
