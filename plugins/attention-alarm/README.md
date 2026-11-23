# attention-alarm

Rings a repeating alarm when Claude Code needs you, and goes quiet the moment you respond.

| When | Sound (default) |
|------|-----------------|
| Claude finishes its turn and is waiting for you | Glass, repeating |
| A permission prompt or a question for you | Sosumi, repeating, plus a macOS notification banner with the message |

## How it stops

- **On its own:** when you submit your next prompt, when an approved tool runs, or when the session ends.
- **Manually:** run `hush` in any terminal. It stops every ringing alarm in every session and profile.
- **Time limit:** it gives up after 30 seconds.

Each session has its own alarm, so answering one Claude window doesn't silence another.

## Install

```
/plugin marketplace add mr-ashishpanda/applied-ai-innovation
/plugin install attention-alarm@applied-ai-innovation
```

Optional: put `hush` on your shell's PATH:

```bash
cp "$(find ~/.claude*/plugins -path '*attention-alarm/bin/hush' | head -1)" ~/.local/bin/hush
```

## Configure

Copy [`config.example`](./config.example) to `~/.attention-alarm/config` and edit it. Every Claude Code profile
reads the same file, whatever its `CLAUDE_CONFIG_DIR` is. Changes apply to the next alarm.

| Setting | Default | Meaning |
|---------|---------|---------|
| `SOUND_DONE` | `Glass.aiff` | Sound played when Claude finishes its turn |
| `SOUND_NEEDED` | `Sosumi.aiff` | Sound played for a permission prompt or a question |
| `VOLUME` | `1.0` | Playback volume passed to `afplay` |
| `INTERVAL` | `1.5` | Seconds between repeats |
| `MAX_SECONDS` | `30` | Auto-stop after this many seconds |
| `SHOW_NOTIFICATION` | `1` | Also show a macOS notification banner |
| `ENABLED` | `1` | Set to `0` to mute without uninstalling |

Run `attention-alarm test` (from the plugin's `bin/`) to hear a 5-second sample.

## Notes

- Requires macOS (`afplay`, `osascript`) and `jq`.
- After you approve a permission prompt, the alarm stops when that tool finishes. Claude Code has no hook for the approval itself.
- Claude Code's "idle for 60s" notification is not hooked by default, to avoid a second ring. To add it, put `|idle_prompt` on the end of the `Notification` matcher in `hooks/hooks.json`.
