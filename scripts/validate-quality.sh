#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$project_root/build/quality-validation}"
mkdir -p "$output"
temporary="$(mktemp -d -t framecast-quality)"
trap 'rm -rf "$temporary"' EXIT

cd "$project_root"
FRAMECAST_QUALITY_DIR="$output" swift test --filter MediaQualityTests

xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
    "$project_root/Sources/VidystStudio/MediaTypes.swift" \
    "$project_root/Sources/VidystStudio/MediaPreferences.swift" \
    "$project_root/Sources/VidystStudio/MediaFailure.swift" \
    "$project_root/Sources/VidystStudio/RecordingOutput.swift" \
    "$project_root/Sources/VidystStudio/AudioMixer.swift" \
    "$project_root/scripts/RecordingInterruptionTest.swift" \
    -o "$temporary/interruption-test"

ffmpeg=""
for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
    if [ -x "$candidate" ]; then ffmpeg="$candidate"; break; fi
done
for container in mp4 mov; do
    "$temporary/interruption-test" "$output/interrupted.$container" "$container"
done
if [ -n "$ffmpeg" ] && [ -x "$(dirname "$ffmpeg")/ffprobe" ]; then
    python3 - "$ffmpeg" "$output" <<'PY'
import json,subprocess,sys
from pathlib import Path
ffmpeg,output=sys.argv[1:]
for container,codec in [('mp4','h264'),('mov','hevc')]:
    path=Path(output)/('interrupted.'+container)
    metadata=json.loads(subprocess.check_output([str(Path(ffmpeg).with_name('ffprobe')),'-v','error','-show_streams','-show_format','-of','json',str(path)]))
    assert {s['codec_name'] for s in metadata['streams']} >= {codec,'aac'},metadata
    assert float(metadata['format']['duration'])>=0.9,(container,metadata['format']['duration'])
    frame=subprocess.check_output([ffmpeg,'-v','error','-ss','0.4','-i',str(path),'-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','pipe:1'])
    assert len(frame)==640*360*3,len(frame)
    (Path(output)/('interrupted-'+container+'-metadata.json')).write_text(json.dumps(metadata,indent=2)+'\n')
    print('PASS unfinalized fragmented',container,codec,'+AAC partial movie plays and decodes after owned helper interruption; recovered seconds:',metadata['format']['duration'])
print('VERDICT: PASS')
PY
else
    printf 'SKIP partial-movie playback probe: FFmpeg/ffprobe unavailable; no dependency was installed.\n'
fi
