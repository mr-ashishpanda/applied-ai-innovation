---
description: Revoke the pushed SSH key for an EC2 instance and clean up local key material and ~/.ssh/config
argument-hint: <instance-id> [--profile P]
---

The user wants to revoke access for: $ARGUMENTS

Run `ssm-revoke` (on PATH; equivalently
`${CLAUDE_PLUGIN_ROOT}/skills/ssm-ssh-access/scripts/revoke.sh`) with
`--instance-id`. `--profile` is optional — without it the script falls back to
the profile saved when the key was pushed, which is usually what you want.

If the user did not name an instance, run `ssm-status` first and show them
which instances currently have a key pushed rather than guessing.

This removes the key from the instance's `authorized_keys`, deletes the local
key material, and removes the `~/.ssh/config` block — after it, `ssh
<instance-id>` stops working until a fresh connect. Report what was removed.
