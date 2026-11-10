#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift test --filter OfflineGoogleTests
swift test --filter YouTubeProtocolTests
