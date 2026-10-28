#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_ROOT/research/media-validation/generated}"
mkdir -p "$OUTPUT_DIR"
TEMP_DIR="$(mktemp -d -t vidyst-media-validation)"
trap 'rm -rf "$TEMP_DIR"' EXIT
ENGINE="$PROJECT_ROOT/Sources/VidystStudio/MediaEngine.swift"
if [ "${FRAMECAST_STREAM_ONLY:-0}" != "1" ]; then
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.2" "$PROJECT_ROOT/Sources/VidystStudio/MediaTypes.swift" "$PROJECT_ROOT/Sources/VidystStudio/VideoColor.swift" "$PROJECT_ROOT/Sources/VidystStudio/RecordingOutput.swift" "$PROJECT_ROOT/Sources/VidystStudio/RecordingStorage.swift" "$PROJECT_ROOT/Sources/VidystStudio/StreamPipe.swift" "$PROJECT_ROOT/Sources/VidystStudio/MediaPreferences.swift" "$PROJECT_ROOT/Sources/VidystStudio/MediaFailure.swift" "$PROJECT_ROOT/Sources/VidystStudio/AudioMixer.swift" "$PROJECT_ROOT/Sources/VidystStudio/AudioSignalMonitor.swift" "$PROJECT_ROOT/Sources/VidystStudio/CaptureDelivery.swift" "$PROJECT_ROOT/Sources/VidystStudio/ScreenCaptureSession.swift" "$ENGINE" "$PROJECT_ROOT/scripts/MediaSelfTest.swift" -o "$TEMP_DIR/media-test"
"$TEMP_DIR/media-test" "$OUTPUT_DIR"
fi
FFMPEG=""
for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
    if [ -x "$candidate" ]; then FFMPEG="$candidate"; break; fi
done
if [ -z "$FFMPEG" ]; then
    echo 'SKIP streaming encoder: FFmpeg is not installed. No software was installed.'
    exit 0
fi
FFPROBE="$(dirname "$FFMPEG")/ffprobe"
cat "$ENGINE" "$PROJECT_ROOT/scripts/StreamSelfTest.swift" > "$TEMP_DIR/stream-test.swift"
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.2" "$PROJECT_ROOT/Sources/VidystStudio/MediaTypes.swift" "$PROJECT_ROOT/Sources/VidystStudio/VideoColor.swift" "$PROJECT_ROOT/Sources/VidystStudio/RecordingOutput.swift" "$PROJECT_ROOT/Sources/VidystStudio/RecordingStorage.swift" "$PROJECT_ROOT/Sources/VidystStudio/StreamPipe.swift" "$PROJECT_ROOT/Sources/VidystStudio/MediaPreferences.swift" "$PROJECT_ROOT/Sources/VidystStudio/MediaFailure.swift" "$PROJECT_ROOT/Sources/VidystStudio/AudioMixer.swift" "$PROJECT_ROOT/Sources/VidystStudio/AudioSignalMonitor.swift" "$PROJECT_ROOT/Sources/VidystStudio/CaptureDelivery.swift" "$PROJECT_ROOT/Sources/VidystStudio/ScreenCaptureSession.swift" "$TEMP_DIR/stream-test.swift" -o "$TEMP_DIR/stream-test"
STREAM_FILE="$OUTPUT_DIR/stream-$(uuidgen).flv"
"$TEMP_DIR/stream-test" "$FFMPEG" "$STREAM_FILE"
"$FFPROBE" -v error -show_streams -of json "$STREAM_FILE" > "$OUTPUT_DIR/ffprobe.json"
python3 - "$FFMPEG" "$STREAM_FILE" "$OUTPUT_DIR/ffprobe.json" "${STREAM_FILE%.flv}.canvas.flv" <<'PY'
import sys,subprocess,json,array
ffmpeg,path,metadata,canvas_path=sys.argv[1:]
with open(metadata) as source:
    streams=json.load(source)['streams']
assert {s['codec_name'] for s in streams} >= {'h264','aac'},streams
assert next(s for s in streams if s['codec_name']=='aac')['channels']==2,streams
assert next(s for s in streams if s['codec_name']=='aac')['sample_rate']=='48000',streams
result=subprocess.run([ffmpeg,'-v','error','-i',path,'-map','0:a:0','-f','s16le','-acodec','pcm_s16le','pipe:1'],capture_output=True,check=True)
samples=array.array('h',result.stdout)
peak=max(map(abs,samples))
assert peak>3000,peak
print('PASS actual H264 + AAC tracks; decoded synthetic audio peak:',peak)
for selector in ['v:0','a:0']:
    timestamps=subprocess.run([ffmpeg.replace('ffmpeg','ffprobe'),'-v','error','-select_streams',selector,'-show_packets','-show_entries','packet=pts_time','-of','csv=p=0',path],capture_output=True,text=True,check=True).stdout
    pts=[float(line.strip().split(',')[0]) for line in timestamps.splitlines() if line.strip()]
    assert pts and max(pts)>2.8,(selector,pts[-5:])
print('PASS sparse video submissions preserve elapsed video/audio time instead of compressing the video clock')

for seconds,channel in [(0.4,0),(1.5,1),(2.6,1)]:
    frame=subprocess.run([ffmpeg,'-v','error','-ss',str(seconds),'-i',canvas_path,'-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','pipe:1'],capture_output=True,check=True).stdout
    assert len(frame)==320*180*3,len(frame)
    center=frame[(90*320+160)*3:(90*320+160)*3+3]
    assert center[channel]>180 and all(center[i]<70 for i in range(3) if i!=channel),(seconds,list(center))
mixed=subprocess.run([ffmpeg,'-v','error','-i',canvas_path,'-map','0:a:0','-f','s16le','-acodec','pcm_s16le','pipe:1'],capture_output=True,check=True).stdout
stereo=array.array('h',mixed)
assert len(stereo)>44100*2,len(stereo)
difference=(sum((int(stereo[i])-int(stereo[i+1]))**2 for i in range(0,len(stereo)-1,2))/(len(stereo)//2))**0.5
assert 2500<difference<7000,difference
print('PASS decoded engine stereo mixer through FFmpeg/AAC; left/right difference RMS:',difference)
print('PASS decoded horizontal stream remains pinned: red before switch, updated green after editing switches to portrait, latest green retained when horizontal preview is hidden')
print('VERDICT: PASS')
PY
