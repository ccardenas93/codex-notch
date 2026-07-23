# Codex Notch

A native, always-available terminal for macOS. It sits at the top center of a display as a compact faux notch, expands on hover, and enters Codex only after you type `codex`.

## What works

- Starts as a persistent PTY-backed `zsh` terminal with streaming output, interactive input, Ctrl-C interruption, and shell state such as `cd`.
- Starts a local `codex app-server` only after you type `codex`, using your existing Codex login and configuration.
- Keeps a thread between launches and offers a one-click fresh thread.
- Includes a playful Brain Deck that discovers the live Codex model catalog, explains effort as a fast-to-deep spectrum, and remembers the choice.
- Adds up to six independent notches from the `+` button and keeps the whole fleet centered as it grows.
- Accepts normal Codex prompts in the built-in composer.
- Queues follow-up messages while Codex is working, with remove, clear, and run-next controls.
- Shows a minimalist session strip for Build/Plan mode, context remaining, queue depth, model/effort, and Stop.
- Streams assistant text and live activity into the notch.
- Renders `request_user_input` questions as option buttons plus a custom-answer field.
- Handles current and legacy command/file approvals, extra-permission requests, and connected-tool confirmations with explicit accept, session approval, and reject actions.
- Uses an animated rainbow edge while working, yellow attention pulse, green approval flash, cyan choice flash, and red denial shake.
- Respects the macOS Reduce Motion setting.

## Build and open

```sh
./Scripts/build-app.sh
open "Codex Notch.app"
```

The app uses the installed Codex CLI from `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, or the ChatGPT app bundle. It does not modify `~/.codex/config.toml`, so the existing Computer Use notification command remains intact.

## Controls

- Hover the compact notch to expand it.
- Click the compact notch or the pin button to keep it open.
- Type normal shell commands and press Return.
- While a command is running, type interactive input normally or use the stop button to send Ctrl-C.
- Type `codex` to enter Codex; type `/exit` to return to the terminal.
- In Codex mode, use the brain button to choose the model and reasoning effort for the next turn.
- Toggle **BUILD / PLAN** before a turn, watch the context ring, and press **STOP** (or Command-period) to interrupt active work.
- Sending while a turn is active adds a visible queue item instead of losing or merging the instruction.
- Hover a model card to read its full description in the animated ticker.
- Use `+` from any notch to add another independent terminal/Codex workspace, up to six.
- Use `−` to remove an idle notch. If it is running a command or Codex turn, confirm **Stop & close** first; the other workspaces are unaffected.
- Use **New thread** for a clean conversation.
- Clicking another app or window immediately collapses the panel back to the notch.
- Use the × button to collapse. Right-click the notch and choose **Quit Codex Notch** to quit it manually; the installed keep-alive service will reopen it.

## Always running

The installed LaunchAgent is `~/Library/LaunchAgents/com.carsk8.codex-notch.plist`. It starts the notch at login and restarts it after a crash or manual quit. To disable it permanently:

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.carsk8.codex-notch.plist
```

Codex's `request_user_input` interface is currently marked experimental by the installed app-server schema, so its wire format may require small updates after a future Codex CLI upgrade.
