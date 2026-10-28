#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary="$(mktemp -d -t framecast-audio-validation)"
trap 'rm -rf "$temporary"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
    "$project_root/Sources/VidystStudio/AudioMixer.swift" \
    "$project_root/Tests/AudioMixerTests.swift" -o "$temporary/audio-test"
"$temporary/audio-test"

xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
    "$project_root/Sources/VidystStudio/AudioMixer.swift" \
    "$project_root/Sources/VidystStudio/AudioSignalMonitor.swift" \
    "$project_root/Tests/AudioSignalMonitorTests.swift" -o "$temporary/audio-level-test"
"$temporary/audio-level-test"
