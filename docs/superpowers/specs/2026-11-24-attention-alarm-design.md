# attention-alarm: design

Issue: #9

## Goal

Ring an audible, repeating alarm when Claude Code needs the user, and make it easy to stop. Install it once per Claude Code profile through this repo's marketplace.

## Behaviour

- **Starts on:** `Stop`, meaning Claude finished its turn. Also on `Notification` with matcher `permission_prompt|elicitation_dialog`. The two triggers use different sounds, and the notification trigger also shows a macOS banner.
- **Stops on:** `UserPromptSubmit`, `PostToolUse` (fires after an approved tool runs), `SessionEnd`, the `hush` command, or after `MAX_SECONDS` (default 30).
- **One alarm per session.** Each session has its own pid file at `~/.attention-alarm/state/<session_id>.pid`, so answering one session never silences another. Starting a new alarm in a session replaces the old one.
- **Hooks never block.** The ring loop runs detached through `nohup` with every file descriptor redirected, so the hook returns at once.

## Decisions

- **Plugin, not settings hooks.** The plugin installs with one command per `CLAUDE_CONFIG_DIR` profile and updates through the marketplace.
- **Config lives in `~/.attention-alarm/config`, outside any profile.** Every profile shares the same sounds and limits.
- **`idle_prompt` is excluded by default.** It would re-ring 60 seconds after the `Stop` alarm.
- **macOS only.** The plugin uses `afplay` and `osascript`.
