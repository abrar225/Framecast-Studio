#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_ROOT/research/runtime-0.2.32/dual-recording-validation}"
mkdir -p "$OUTPUT_DIR"
TEMP_DIR="$(mktemp -d -t vidyst-dual-media-validation)"
trap 'rm -rf "$TEMP_DIR"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
    "$PROJECT_ROOT/Sources/VidystStudio/MediaTypes.swift" \
    "$PROJECT_ROOT/Sources/VidystStudio/VideoColor.swift" \
    "$PROJECT_ROOT/Sources/VidystStudio/RecordingOutput.swift" \
    "$PROJECT_ROOT/Sources/VidystStudio/RecordingStorage.swift" \
    "$PROJECT_ROOT/Sources/VidystStudio/StreamPipe.swift" \
    "$PROJECT_ROOT/Sources/VidystStudio/MediaPreferences.swift" \
    "$PROJECT_ROOT/Sources/VidystStudio/MediaFailure.swift" \
    "$PROJECT_ROOT/Sources/VidystStudio/AudioMixer.swift" \
    "$PROJECT_ROOT/Sources/VidystStudio/AudioSignalMonitor.swift" \
    "$PROJECT_ROOT/Sources/VidystStudio/CaptureDelivery.swift" \
    "$PROJECT_ROOT/Sources/VidystStudio/ScreenCaptureSession.swift" \
    "$PROJECT_ROOT/Sources/VidystStudio/MediaEngine.swift" \
    "$PROJECT_ROOT/Sources/VidystStudio/MediaCompositor.swift" \
    "$PROJECT_ROOT/Sources/VidystStudio/MediaSelfTests.swift" \
    "$PROJECT_ROOT/scripts/DualMediaSelfTest.swift" -o "$TEMP_DIR/dual-test"
"$TEMP_DIR/dual-test" "$OUTPUT_DIR"
