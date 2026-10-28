#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary="$(mktemp -d -t framecast-capture-validation)"
trap 'rm -rf "$temporary"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
    "$project_root/Sources/VidystStudio/MediaFailure.swift" "$project_root/Sources/VidystStudio/CaptureDelivery.swift" "$project_root/Sources/VidystStudio/ScreenCaptureSession.swift" \
    "$project_root/Tests/CaptureLifecycleTests.swift" -o "$temporary/capture-test"
"$temporary/capture-test"

xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
    "$project_root/Sources/VidystStudio/CaptureDelivery.swift" \
    "$project_root/Tests/CaptureDeliveryTests.swift" -o "$temporary/delivery-test"
"$temporary/delivery-test"
