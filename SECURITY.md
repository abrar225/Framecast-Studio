# Security and privacy

This early release has not undergone an independent security audit. There is currently no maintained-version support guarantee or published security response SLA.

Do not put OAuth JSON downloads, access/refresh tokens, stream keys, remote-control tokens, private screenshots, user projects or signing keys in a public issue. Report a minimal reproduction with secrets removed. Once a public repository exists, use its private security advisory channel if enabled; if no private reporting channel has been established, ask for one without disclosing exploitation details publicly. This source snapshot does not invent a maintainer email or reporting service.

## Boundaries

Camera, microphone and display access are mediated by macOS. Capture is explicitly started by the user. The app stores project/configuration data in its own Application Support directory and credentials in macOS Keychain. A desktop OAuth client is not a confidential server client: do not treat a distributed desktop client secret as proof of application identity. YouTube scopes are broad; review the Google consent screen and connect only a channel you intend to control.

The optional remote-control server is loopback-only and uses an authentication token. Keep its address/token private, and do not expose the listener with a proxy or tunnel without a separate threat review. FFmpeg is launched as a separately installed encoder; verify the provenance of the executable you install.

Disconnect YouTube through the app or revoke the grant through your Google account if you suspect compromise. Rotate a leaked stream key at the destination service. Do not assume deleting a local project removes Keychain credentials or ends a remote broadcast. Explicitly end the broadcast and verify its state at the provider when a crash or network failure makes the outcome uncertain.

Distribution signing, notarization, third-party OAuth verification, protocol fuzzing and failure/recovery testing remain work for a broadly distributed release. A successful local self-test is not a security certification.
