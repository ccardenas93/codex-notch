# Codex Notch audit

Audited on 2026-07-28 against macOS 14+, Swift 5.10, and the installed Codex app-server.

## Scope

- Native Swift/AppKit lifecycle and PTY behavior
- Codex thread, turn, approval, interruption, and elicitation flows
- Compact, expanded, terminal, Codex, and multi-notch states
- Keyboard operation, VoiceOver labels, Reduce Motion, contrast, and interface copy
- Bundle metadata, signing, LaunchAgent health, and runtime logs

## Release fixes

- Codex threads and turns now inherit the terminal's live working directory.
- Terminal and Codex transcripts no longer bleed into each other.
- Closed/re-added notches receive collision-free workspace slots.
- A stopped shell or Codex server can be restarted in place.
- Unsupported server requests fail safely instead of receiving a guessed approval payload.
- MCP URL requests can open their destination; unsupported structured forms are clearly declined.
- PTY decoding preserves UTF-8 scalars split across read boundaries and strips ANSI after line assembly.
- Tab completion handles relative paths, current-directory changes, and shell escaping more safely.
- Expanded off-center panels remain inside the physical display bounds.
- Compact controls expose accurate accessibility labels and keyboard-accessible position presets.
- Small session-control labels were enlarged, destructive copy was clarified, and Reduce Motion now freezes decorative motion.
- The app bundle now includes validated identity, version, agent-app, and minimum-system metadata.

## Verification

- Swift build with warnings treated as errors
- Release build and strict code-signature verification
- `Info.plist` and LaunchAgent validation
- Live terminal command, current-directory Tab completion, and Control-C checks
- Live add/remove notch and compact/expanded accessibility-tree checks
- LaunchAgent running with an empty stderr log

## Known boundaries

- Completion is intentionally lightweight. It covers executable and filesystem completion, not every zsh plugin or custom completer.
- Arbitrary MCP structured forms are not rendered yet. The app declines them explicitly so a turn cannot hang on malformed input.
- The local Command Line Tools installation does not provide `XCTest`; executable smoke checks and live UI verification are used instead.

## Relevant optional skills found

- `dpearson2699/swift-ios-skills@ios-accessibility`
- `rshankras/claude-code-apple-skills@macos-development`
- `existential-birds/beagle@swiftui-code-review`
- `livsy90/ios-performance-agent-skills@swiftui-performance`

These were discovered but not installed globally during the audit.
