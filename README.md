# Framecast Studio

A free, MIT-licensed native macOS studio for composing screen and camera scenes, recording landscape and portrait video, and testing private YouTube broadcasts. This is an independent implementation, with no affiliation to Vidyst. It is an early release with known gaps; it is not a feature-complete replacement or a certified production streaming system.

## Requirements and build

- macOS 14.2 or later. Development and runtime checks have been performed on Apple Silicon; Intel and a broad macOS/device matrix are not yet verified.
- Xcode Command Line Tools with a Swift compiler compatible with the sources. The only third-party Swift package is the pinned, vendored MIT CompactSlider component; the build does not fetch it remotely. The build has been exercised with Swift 6.4 in Swift 5 language mode.
- FFmpeg for streaming, available at `/opt/homebrew/bin/ffmpeg` or `/usr/local/bin/ffmpeg`. FFprobe is needed for transport validation. Install these independently; neither executable is bundled or installed by the app. Local recording uses Apple's AVFoundation and does not require FFmpeg.

```sh
bash scripts/build.sh
open "build/Framecast Studio.app"
```

Copy the generated app to Applications for everyday use and keep that installation path stable. The build script supports `FRAMECAST_SIGN_IDENTITY` for a signing identity in your Keychain. Without an override it uses the named local Framecast identity when available, or ad hoc signing on a clean machine. A persistent identity helps macOS recognize subsequent builds and retain permissions. To create a local identity, explicitly run `bash scripts/setup-local-signing.sh`, then rebuild. That script creates a self-signed code-signing identity in your default user Keychain; it does not change the trust store. Local or ad hoc signing is not Developer ID distribution or Apple notarization. Replacing an app's signer can require permission approval again. No notarized download is provided here.

## First session

1. Open the permissions guide and enable Screen Recording for Framecast Studio. Camera and Microphone are optional; enable them if you want those inputs. Follow macOS's restart prompt when required. Approval for another app does not transfer.
2. Choose a layout in the horizontally scrolling **Layouts** rail and enable **Share screen** or **Enable camera**. Capture stays off until you start it. The rail groups all nine built-ins and your saved scenes; **+ New layout** creates a blank layout, duplicates one, or adds from a template. Layouts are editable scenes: click a source in the canvas to open **Edit**, drag to move it, or use its corner and edge handles to resize. Small/Medium/Large, Fit and Center controls are in Edit. Lock position prevents accidental changes; Keep aspect preserves proportions, and circles always keep equal pixel dimensions. Hold Option to bypass edge/center snapping. Escape cancels a drag; Undo/Redo restores a whole committed gesture. Drafts stay out of autosave until release.
3. Choose Horizontal, Vertical, or both output canvases. In Both mode, **Link layouts** is enabled by default so choosing a layout updates both canvases, with separate geometry for each. Turn it off for independent layout selection. Source framing stays independently editable in either mode. Review each preview before recording; portrait output cannot fill the frame with a landscape display without either cropping or unused space. Use the source's fit/fill settings to choose the tradeoff.
4. Select **Record**. When both canvases are visible, separate landscape and portrait movies are produced with each canvas’s own frame rate, H.264/HEVC codec, bitrate and MP4/MOV container. Pause and resume share a timeline. Stop and allow finalization before opening the files.

In **Settings → Video**, adjust horizontal and vertical resolution and frame rate independently. **Settings → Recording** shows both canvases together, with each canvas's codec, file type and Good/Great/Custom quality. The space display estimates remaining recording time from the selected outputs and configured bitrates; it cannot predict exact file size. Local recording uses Apple AVFoundation/VideoToolbox; hardware encoding is required by default and fails with a recovery message if unavailable. Disable that requirement only if you accept the system choosing a fallback encoder. Audio is48kHz stereo with configurable AAC bitrate. Only finalized files appear as saved. Recording statistics count submitted frames, missed time slots and audio backpressure; export the report from Recording settings. Fragmented movies improve partial-file resilience, but they do not guarantee recovery of in-flight data. After a five-second interrupted-helper test, the first completed one-second fragment was playable; later fragments use a ten-second interval, so recent in-flight data can be lost. Low-space checks reserve ten seconds of configured output plus64MiB for finalization.

Use **Share screen** to choose a display, window, or application in Apple’s native chooser. **Change source…** replaces an active source; cancelling keeps the current capture. All screen layers share this selected input. Window selections are not saved across launches.

ScreenCaptureKit requests native source pixels up to an aspect-preserving 4K/8.3-megapixel bound. The capture bar shows the dimensions actually received. Output resolution is controlled separately in Settings; portrait screen layers default to Fit to retain the whole desktop. Native capture requests the highest required canvas/output cadence up to60fps; an unchanged source may deliver fewer frames. Previews are scaled separately from recording output. Capture-off hints appear only in the editor, never in recorded output. Untouched older templates upgrade with a backup; customized layouts are preserved.

Open **Audio** (or the waveform button in the toolbar) to see live microphone, captured-audio and output-mix meters. Your microphone becomes ready when the studio opens if permission is already granted; unmute it and raise its volume to see the post-volume level. **Enable microphone** requests access when needed. **Pause input** releases the idle microphone; recording and streaming keep the inputs they need. The meters distinguish detected signal, received silence, missing input, mute, permission denial and clipping. Ready input does not save a file. Microphone device selection, mute, meters and volume are grouped in its channel.

In Audio, enable **Capture system/app audio** to include sound from the shared source; it is off by default. Framecast excludes its own sound. Microphone and captured audio have separate volume controls and share a timestamped stereo mix for recording and RTMP. Missing input produces silence; pause boundaries are removed from the recording clock. Monitoring, noise processing and guest mix-minus remain unfinished. Native device capture and sustained performance still require device testing.

Streaming settings select Apple VideoToolbox or Software H.264 and independent video/audio bitrates. FFmpeg remains the transport dependency. Audio backlog is bounded by bytes; stalled/closed transport reports a failure rather than silently dropping partial audio. Video input uses elapsed wall-clock timestamps and fixed-rate output so dropped submissions do not compress its timeline against audio. System time jumps, network recovery and long-session synchronization remain unverified.

The studio includes source transforms, crop, fit/fill/stretch, basic color and mask controls, text/image/QR elements, a private teleprompter, and authenticated local remote control. Hardware support, output quality and sustained performance depend on your selected inputs and output settings; verify a short sample before relying on a session.

## YouTube setup

Each developer or self-hosted build supplies its own Google Desktop OAuth application. No shared Google credentials, test channel, or signed-in account ships with this source.

1. Create a Google Cloud project and enable **YouTube Data API v3**.
2. Configure the OAuth consent screen. While the project is in Testing, add your Google account as a test user.
3. Create an OAuth client of type **Desktop app** and download its JSON. In Framecast Studio, open Destinations and import it under Developer configuration.
4. Connect YouTube and select the channel. Read Google's consent screen before approving. The requested scope is `youtube.force-ssl`, which permits broad YouTube management, including video and comment changes. Gmail and Drive access are not requested.
5. Create a **private** broadcast, start the encoder, check input readiness, and choose **Go live privately**. End the broadcast explicitly when finished. Local recordings are controlled separately.

Only private YouTube broadcasts are implemented in the account workflow. YouTube's account eligibility, API quotas, test-mode limits and OAuth verification requirements still apply. A widely distributed OAuth client needs its own Google compliance and verification process; a local test client does not establish readiness for public distribution.

Google client metadata is saved locally; client secrets and refresh credentials use macOS Keychain. Normal startup can restore an existing grant. Use the app's Disconnect action to revoke the connection. Do not commit a downloaded OAuth JSON, stream key, or user project.

Official setup references: [installed-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app), [YouTube live API](https://developers.google.com/youtube/v3/live/getting-started).

## Data and dependencies

For compatibility with earlier personal builds, the app currently retains the bundle identifier `local.vidyst.reconstructed` and the data directory `~/Library/Application Support/Vidyst Reconstructed`. Default recordings are under `~/Movies/Vidyst Reconstructed`. These are legacy names, not a dependency on the original product. Back up your studio document before experimenting with development builds. Stream keys and Google tokens use separate app-owned Keychain records. Remote control binds to loopback only and requires a private token.

The application uses Apple's AppKit, SwiftUI, AVFoundation, ScreenCaptureKit, Core Image, Security and Network frameworks. FFmpeg is a separate program with its own license, which varies with build configuration. The project's MIT license does not relicense FFmpeg or Apple's frameworks. The Framecast icon is generated from the project's own drawing code. UI faders use the MIT-licensed CompactSlider 2.1.0 source pinned under ThirdParty/CompactSlider. Its upstream hashes and SDK compatibility changes are documented in UPSTREAM.json; ThirdPartyNotices.txt accompanies the app and source distribution.

## Validation

```sh
"build/Framecast Studio.app/Contents/MacOS/VidystReconstructed" --self-test
bash scripts/validate-canvas.sh build/canvas-validation
bash scripts/validate-capture.sh
bash scripts/validate-audio.sh
bash scripts/validate-quality.sh build/quality-validation
bash scripts/validate-media-failures.sh
bash scripts/validate-media.sh build/media-validation
bash scripts/validate-dual-media.sh build/dual-validation
bash scripts/validate-google-youtube.sh
```

The packaged self-test exercises model and local media behavior. Media harnesses create synthetic local recordings; transport validation additionally needs FFmpeg/ffprobe. OAuth and provider fixtures do not contact Google or use credentials. Optional `--audio-probe`, `--camera-probe` and `--screen-probe` modes use only already-authorized inputs for three seconds and report metadata without saving audio or images. The camera probe also verifies cancellation before startup. The display probe targets the main display through the studio’s native capture owner; `--screen-probe-audio` explicitly includes captured audio. `--diagnostic-result PATH` writes a new JSON result and refuses to overwrite it. macOS may attribute a tool-launched diagnostic differently from a normal LaunchServices app launch. It does not request access or record a file. These tests do not establish broad camera/microphone compatibility, every permission state, broadcast recovery, or sustained high-resolution performance. Native screen capture and a private YouTube/chat round trip have been exercised during development; reproducible testing on other machines is still needed.

## Known limits

- Guests, backstage conferencing, Twitch/Kick integrations, multi-platform chat, virtual camera and mobile companions are unfinished.
- Public/unlisted YouTube publishing, multi-destination streaming, full broadcast management, automatic record-with-stream, and crash recovery of an active broadcast are absent.
- Multiple independent camera/screen inputs, audio monitoring and advanced audio processing are incomplete. Display/window/application selection and basic captured audio are implemented for one shared screen input; physical-device validation remains open.
- H.264/HEVC and MP4/MOV plus per-canvas frame rates are implemented. ProRes/MKV, separate recording tracks, segment splitting, global shortcut configuration and full profiles management remain incomplete.
- Templates, source styling, transitions and import fidelity cover a subset of the reference application's behavior. No exact visual or feature parity is claimed.
- Signing/notarization, OAuth distribution verification, accessibility audit, long-session performance, network-loss recovery and the hardware/OS compatibility matrix remain release work.

Contributions should focus on reproducible problems and measured improvements. See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and [LICENSE](LICENSE).

## Source distribution

Run `bash scripts/export-source.sh` to create a reviewable source-only snapshot at `build/Framecast-Studio-Source`. It includes explicitly selected code, test harnesses and public documentation, plus a SHA-256 manifest. It excludes local research, recordings, screenshots, imported user layouts, built apps, credentials and signing material. The script refuses to overwrite an existing export; use its optional output path for a fresh snapshot. This creates a local folder only and does not publish anything online.
