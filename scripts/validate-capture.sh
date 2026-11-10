#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift test --filter CaptureLifecycleTests
swift test --filter CaptureDeliveryTests
swift test --filter CaptureSizingTests
