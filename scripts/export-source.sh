#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$project_root" "${1:-$project_root/build/Framecast-Studio-Source}" <<'PY'
"""Export only reviewed project source. Never copy the investigation workspace."""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
target = Path(sys.argv[2]).expanduser().absolute()
if target.exists() or target.is_symlink():
    raise SystemExit("Refusing to overwrite an existing export. Choose a fresh output path.")
if target == root or root in target.parents and 'build' not in target.relative_to(root).parts[:1]:
    raise SystemExit("An export inside the project must be under build/.")
# These names are intentionally explicit. A new source file requires review here.
files = [
    '.gitignore', 'README.md', 'LICENSE', 'CONTRIBUTING.md', 'SECURITY.md',
    'Package.swift', 'Launch.command',
    'Sources/VidystStudio/CanvasEditor.swift',
    'Sources/VidystStudio/CanvasGeometry.swift',
    'Sources/VidystStudio/CanvasInteraction.swift',
    'Sources/VidystStudio/ProductInfo.swift',
    'Sources/VidystStudio/ElementsView.swift',
    'Sources/VidystStudio/GoogleYouTube.swift',
    'Sources/VidystStudio/LaunchExperience.swift',
    'Sources/VidystStudio/Main.swift',
    'Sources/VidystStudio/MediaEngine.swift',
    'Sources/VidystStudio/MediaCompositor.swift',
    'Sources/VidystStudio/MediaSelfTests.swift',
    'Sources/VidystStudio/MediaPreferences.swift',
    'Sources/VidystStudio/MediaTypes.swift',
    'Sources/VidystStudio/MediaFailure.swift',
    'Sources/VidystStudio/RecordingOutput.swift',
    'Sources/VidystStudio/RecordingStorage.swift',
    'Sources/VidystStudio/RecordingLibrary.swift',
    'Sources/VidystStudio/RecordingLibraryView.swift',
    'Sources/VidystStudio/StreamPipe.swift',
    'Sources/VidystStudio/VideoColor.swift',
    'Sources/VidystStudio/MediaSettingsView.swift',
    'Tests/MediaQualityTests.swift',
    'scripts/RecordingInterruptionTest.swift',
    'Tests/MediaFailureTests.swift',
    'scripts/validate-quality.sh',
    'scripts/validate-media-failures.sh',
    'Sources/VidystStudio/ScreenCaptureSession.swift',
    'Sources/VidystStudio/CaptureDelivery.swift',
    'Tests/CaptureDeliveryTests.swift',
    'Tests/CaptureSizingTests.swift',
    'Sources/VidystStudio/AudioMixer.swift',
    'Sources/VidystStudio/AudioSignalMonitor.swift',
    'Sources/VidystStudio/AudioLevelsView.swift',
    'Sources/VidystStudio/AudioMixerPanel.swift',
    'Sources/VidystStudio/StudioUI.swift',
    'Sources/VidystStudio/StudioSlider.swift',
    'Resources/ThirdPartyNotices.txt',
    'Sources/VidystStudio/PrompterView.swift',
    'Sources/VidystStudio/RemoteServer.swift',
    'Sources/VidystStudio/SettingsView.swift',
    'Sources/VidystStudio/StudioLayouts.swift',
    'Sources/VidystStudio/StudioModel.swift',
    'Sources/VidystStudio/StudioView.swift',
    'Sources/VidystStudio/VidystCollectionImport.swift',
    'Sources/VidystStudio/YouTubeDestinationView.swift',
    'Sources/VidystStudio/YouTubeLiveAPI.swift',
    'Sources/VidystStudio/YouTubeStudioSession.swift',
    'scripts/build.sh', 'scripts/make-icon.swift', 'scripts/setup-local-signing.sh',
    'scripts/export-source.sh', 'scripts/validate-google-youtube.sh',
    'scripts/validate-media.sh', 'scripts/validate-dual-media.sh',
    'scripts/validate-canvas.sh', 'Tests/CanvasInteractionTests.swift',
    'scripts/validate-capture.sh', 'Tests/CaptureLifecycleTests.swift',
    'scripts/validate-audio.sh', 'Tests/AudioMixerTests.swift',
    'Tests/AudioSignalMonitorTests.swift',
    'scripts/MediaSelfTest.swift', 'scripts/DualMediaSelfTest.swift',
    'scripts/StreamSelfTest.swift',
    'Tests/OfflineGoogleTests.swift', 'Tests/YouTubeProtocolTests.swift',
    'Tests/MultiDestinationAndLibraryTests.swift',
]
# The vendored component is pinned by its reviewed upstream/patch manifest.
third_party = root / 'ThirdParty/CompactSlider'
third_party_manifest = json.loads((third_party / 'UPSTREAM.json').read_text())
third_party_files = [*third_party_manifest['upstream_sha256'], 'UPSTREAM.json', *third_party_manifest['compatibility_patch']['added_files']]
for name in third_party_files:
    relative = Path(name)
    if relative.is_absolute() or '..' in relative.parts:
        raise SystemExit('Invalid third-party source path')
    files.append('ThirdParty/CompactSlider/' + name)
actual_vendor = {str(p.relative_to(root)) for p in third_party.rglob('*') if p.is_file()}
if actual_vendor != {f for f in files if f.startswith('ThirdParty/CompactSlider/')}:
    raise SystemExit('Review changed third-party file membership before export')
# Fail if code was added without updating the reviewable list.
for directory in ('Sources', 'Tests'):
    actual = {str(p.relative_to(root)) for p in (root / directory).rglob('*.swift')}
    missing = actual - set(files)
    if missing:
        raise SystemExit('Review new source files before export: ' + ', '.join(sorted(missing)))
contents = {}
for name in files:
    source = root / name
    if not source.is_file() or any(p.is_symlink() for p in (source, *source.parents)):
        raise SystemExit('Missing, nonregular, or symlinked export input: ' + name)
    data = source.read_bytes()
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        raise SystemExit('Binary data is not allowed in this source export: ' + name)
    # Narrow checks catch concrete private material formats without rejecting
    # protocol field names or explicitly synthetic credential fixtures.
    forbidden = (
        r'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----',
        r'AIza[0-9A-Za-z_-]{30,}',
        r'ya29\.[0-9A-Za-z_-]{20,}',
        r'/' + r'Users/(?!\$)[^/\s]+/',
        r'\b\d{8,}-[a-z0-9]{20,}\.apps\.googleusercontent\.com\b',
    )
    if any(re.search(pattern, text) for pattern in forbidden):
        raise SystemExit('Potential private material; review before export: ' + name)
    contents[name] = data

target.parent.mkdir(parents=True, exist_ok=True)
staging = Path(tempfile.mkdtemp(prefix='.framecast-source-', dir=target.parent))
try:
    manifest = {}
    for name, data in contents.items():
        output = staging / name
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(data)
        executable = bool((root / name).stat().st_mode & stat.S_IXUSR)
        output.chmod(0o755 if executable else 0o644)
        manifest[name] = hashlib.sha256(data).hexdigest()
    (staging / 'SOURCE-MANIFEST.json').write_text(json.dumps({
        'format': 1,
        'description': 'Explicitly allowlisted source snapshot; SHA-256 per file. No private research or user data is included.',
        'files': manifest,
    }, indent=2, sort_keys=True) + '\n')
    # Do not replace an existing directory, including one created during export.
    target.mkdir()
    try:
        for entry in staging.iterdir():
            shutil.move(str(entry), str(target / entry.name))
    except BaseException:
        shutil.rmtree(target)
        raise
finally:
    shutil.rmtree(staging)
print('Exported ' + str(len(files)) + ' source files to ' + str(target))
print('Review SOURCE-MANIFEST.json and source before publishing. No remote was modified.')
print('VERDICT: PASS')
PY
