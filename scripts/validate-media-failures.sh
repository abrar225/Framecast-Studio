#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary="$(mktemp -d -t framecast-media-failures)"
trap 'rm -rf "$temporary"' EXIT
xcrun swiftc -O -swift-version 5 "$project_root/Sources/VidystStudio/MediaPreferences.swift" "$project_root/Sources/VidystStudio/MediaFailure.swift" "$project_root/Sources/VidystStudio/RecordingStorage.swift" "$project_root/Sources/VidystStudio/StreamPipe.swift" "$project_root/Sources/VidystStudio/CaptureDelivery.swift" "$project_root/Sources/VidystStudio/AudioMixer.swift" "$project_root/Tests/MediaFailureTests.swift" -o "$temporary/media-failures"
"$temporary/media-failures"
