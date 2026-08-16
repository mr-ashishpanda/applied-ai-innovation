---
description: Wire up SSH access to a private EC2 instance over AWS SSM, so `ssh <instance-id>` works
argument-hint: <instance-id> [--profile P] [--region R] [--user U]
---

The user wants SSH access to this instance / with these arguments: $ARGUMENTS

Use the `ssm-ssh-access` skill. Run `ssm-connect` (on PATH; equivalently
`${CLAUDE_PLUGIN_ROOT}/skills/ssm-ssh-access/scripts/connect.sh`) with
`--instance-id` and whatever `--profile` / `--region` the user gave.

**You MUST pass `--user` explicitly.** Omitting it triggers an interactive
picker that needs a real TTY and will hang the shell tool. If the user did not
say which user, discover it first with the `send-command` snippet in the skill,
pick the obvious candidate (usually `ec2-user` on Amazon Linux, `ubuntu` on
Ubuntu), and tell the user which one you chose. If two candidates are equally
plausible, ask rather than guess — a wrong user means a revoke/re-push cycle,
since reusing an existing local key keeps the previously-pushed user.

If the run fails because `session-manager-plugin` is missing, run
`ssm-install-plugin` once and retry. On Windows outside Git Bash, use the
`.ps1` scripts instead.

Once it succeeds, report that `ssh <instance-id>` and `scp ... <instance-id>:`
now work, and remember to offer a revoke when you are done with the instance.
