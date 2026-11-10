#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$project_root/build/canvas-validation}"
mkdir -p "$output"
cd "$project_root"
swift test --filter CanvasInteractionTests > "$output/build.log" 2>&1 || { cat "$output/build.log"; exit 1; }
cat "$output/build.log"
