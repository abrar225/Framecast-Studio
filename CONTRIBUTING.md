# Contributing

Framecast Studio is an independent native macOS project. Keep changes focused on an observable user problem, include a way to reproduce it, and state which macOS version and hardware you actually tested.

## Development

Build with `bash scripts/build.sh`. See the README for optional persistent local signing and the relevant verification commands. No credentials are needed for model, media or OAuth protocol fixture tests. Never use a contributor's real channel, stream keys or signed-in account in CI. Live tests require an account you control and an explicitly chosen audience.

Keep state ownership clear: `StudioModel` owns documents/workflows, `MediaEngine` owns native capture and output lifecycle, `GoogleYouTube` owns OAuth/Keychain, `YouTubeLiveAPI` owns provider protocol behavior, and `YouTubeStudioSession` coordinates streaming. Views should consume that state rather than duplicate its interpretation.

For capture/output changes, test both canvas orientations, pause/resume, stop/finalization and failure cleanup as relevant. For UI changes, inspect the native app at narrow and wide window sizes and test keyboard/accessibility behavior. Record what ran; fixture success is not proof of hardware or live-service compatibility. Changes affecting secrets, permissions or output lifecycle need particular care and targeted regression coverage.

## Pull requests

Describe the problem, resulting behavior, verification performed, and remaining limits. Include screenshots only after removing personal content. Preserve saved user documents and handle migration failures explicitly. Prefer small changes with meaningful validation over broad rewrites or tests that simply repeat implementation details.

Submit only code and assets you have the right to contribute. Do not copy proprietary application code, vendor assets, confidential documents or user session data into the project. Contributions are offered under this project's MIT license. The name and icon are independent of the reference product.

The local investigation workspace contains private research and user artifacts and is not the public distribution. Use `scripts/export-source.sh` to prepare an allowlisted snapshot; review its manifest and files before publishing. Never push the entire investigation workspace. No repository URL, maintainer response schedule or public binary release is established by these documents.
