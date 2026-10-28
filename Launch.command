#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -d "build/Framecast Studio.app" ]; then bash scripts/build.sh; fi
open "build/Framecast Studio.app"
