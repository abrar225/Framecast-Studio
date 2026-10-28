#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$project_root/build/canvas-validation}"
mkdir -p "$output"
temporary="$(mktemp -d -t framecast-canvas-validation)"
trap 'rm -rf "$temporary"' EXIT
sources=(MediaTypes VideoColor RecordingOutput RecordingStorage StreamPipe MediaPreferences MediaFailure CaptureDelivery StudioUI AudioSignalMonitor AudioMixer ScreenCaptureSession MediaEngine CanvasGeometry CanvasInteraction StudioModel StudioLayouts RemoteServer PrompterView VidystCollectionImport GoogleYouTube YouTubeLiveAPI YouTubeStudioSession)
inputs=()
for name in "${sources[@]}"; do inputs+=("$project_root/Sources/VidystStudio/$name.swift"); done
swiftc -O -swift-version 5 "${inputs[@]}" "$project_root/Tests/CanvasInteractionTests.swift" -o "$temporary/canvas-test" > "$output/build.log" 2>&1
"$temporary/canvas-test" "$output"
