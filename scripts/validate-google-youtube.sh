#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vidyst-google-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 5 \
  "$PROJECT_ROOT/Sources/VidystStudio/GoogleYouTube.swift" \
  "$PROJECT_ROOT/Tests/OfflineGoogleTests.swift" \
  -o "$TEST_DIR/google-offline"
"$TEST_DIR/google-offline"
swiftc -swift-version 5 \
  "$PROJECT_ROOT/Sources/VidystStudio/YouTubeLiveAPI.swift" \
  "$PROJECT_ROOT/Tests/YouTubeProtocolTests.swift" \
  -o "$TEST_DIR/youtube-protocol"
"$TEST_DIR/youtube-protocol"
