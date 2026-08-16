---
description: List every EC2 instance that currently has an ssm-ssh-access key pushed
---

Run `ssm-status` (on PATH; equivalently
`${CLAUDE_PLUGIN_ROOT}/skills/ssm-ssh-access/scripts/status.sh`) and report its
output to the user. It takes no arguments.

This is read-only: it pushes no keys, opens no sessions, and changes nothing on
any instance or in `~/.ssh/config`. Do not connect or revoke as a follow-up
unless the user asks.
