---
name: ssm-ssh-access
description: Use to SSH/SCP into a private AWS EC2 instance by instance ID (no bastion, no open port 22, no VPN) via AWS SSM Session Manager. Installs the session-manager-plugin, pushes a temporary SSH key over SSM, wires `ssh <instance-id>` to work directly, and revokes the key afterward.
---

# ssm-ssh-access

Run plain `ssh <instance-id>` / `scp <file> <instance-id>:<path>` against any SSM-managed
EC2 instance, even with no public IP and port 22 closed, by tunneling through
`aws ssm start-session`.

**How it works:** `connect.sh` generates (or reuses) a per-instance ed25519 key, pushes the
public half to the instance's `authorized_keys` via `aws ssm send-command` (same channel as
the Console's "Connect" button — no port 22 opened), then prepends a `Host <instance-id>`
block to `~/.ssh/config` with a `ProxyCommand` that tunnels through `aws ssm start-session`.
After that, `ssh <instance-id>` behaves like normal SSH. `revoke.sh` undoes both halves.

All commands below are relative to **this skill's own directory** (the folder containing
this file) — `cd` there first, or prefix each command with its absolute path (reported when
the skill loads).

## Prerequisites (one-time, per machine)

- AWS CLI v2, authenticated for the target account (`--profile` or default chain).
- `session-manager-plugin` on `PATH` — install with `./scripts/install-plugin.sh` (macOS/
  Linux) or `./scripts/install-plugin.ps1` (Windows). Idempotent and non-interactive; on
  Linux (apt/yum) and the macOS non-Homebrew fallback it runs a `sudo` package install —
  if the calling shell has no TTY for a password prompt, verify passwordless sudo first
  (`sudo -n true`) or ask the human to run it once.
- Target instance: SSM Agent running + an IAM role with `AmazonSSMManagedInstanceCore` (or
  equivalent). `connect.sh` checks this and fails with a clear message if not met.
- Your AWS identity needs `ssm:SendCommand`, `ssm:GetCommandInvocation`,
  `ssm:DescribeInstanceInformation`, `ssm:StartSession` on the target instance(s).

## Scripts

Every script here is fully non-interactive when called with the flags shown — no prompts
block on a TTY, so all of them are safe to call directly from an agent's shell tool.

**`connect.sh` / `connect.ps1`** — push the key and wire up `~/.ssh/config`:

```bash
# macOS/Linux
./scripts/connect.sh --instance-id i-0123456789abcdef0 --profile my-profile --user ec2-user

# Windows
./scripts/connect.ps1 -InstanceId i-0123456789abcdef0 -Profile my-profile -User ec2-user
```

Flags: `--instance-id`/`-InstanceId` (required), `--profile`/`-Profile`,
`--region`/`-Region`, `--user`/`-User`. Omitting `--user`/`-User` triggers an interactive
picker (`select` / `Read-Host`) over a live-discovered list of instance users — **this
needs a real TTY and hangs under a non-interactive shell tool. Agents must always pass
`--user`/`-User` explicitly.** To discover it first, without connecting yet:

```bash
CMD_ID=$(aws ssm send-command --instance-ids i-0123456789abcdef0 \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["{ ls /home 2>/dev/null; echo root; } | sort -u"]' \
  --profile my-profile --query "Command.CommandId" --output text)
sleep 3
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id i-0123456789abcdef0 \
  --profile my-profile --query "StandardOutputContent" --output text
```

If more than one candidate user exists, disambiguate with a second `send-command` (e.g.
`ps -eo user,pid,args` or `ls -la <path>`) to find which one owns what you actually need.

Note: reusing an existing local key for an instance keeps the **previously-pushed** user —
a new `--user`/`-User` is only honored on first push. Run `revoke.sh` first to switch users.

Once connected, treat the instance ID as a normal SSH host for the rest of the session:

```bash
ssh i-0123456789abcdef0
scp ./file.txt i-0123456789abcdef0:/tmp/
```

Each call opens a fresh SSM session (a few seconds of overhead) — batch multiple remote
steps into one call (`&&`/`;`/heredoc) instead of issuing many separate `ssh` invocations.

**`status.sh` / `status.ps1`** — list every instance with a currently pushed key. No
arguments, nothing interactive:

```bash
./scripts/status.sh        # macOS/Linux
./scripts/status.ps1       # Windows
```

**`revoke.sh` / `revoke.ps1`** — remove the key from the instance, delete local key
material, and remove the `~/.ssh/config` block. No interactive prompts:

```bash
./scripts/revoke.sh --instance-id i-0123456789abcdef0 --profile my-profile
./scripts/revoke.ps1 -InstanceId i-0123456789abcdef0 -Profile my-profile
```

Flags: `--instance-id`/`-InstanceId` (required), `--profile`/`-Profile` (optional — falls
back to the profile saved when the key was pushed).

## Agent behavior: end-of-session cleanup reminder

If you (the agent) used this skill to SSH/SCP into an instance during a task, ask the
user once you're done with that instance whether they want the key revoked now — don't
revoke automatically, and don't block on an answer if the user is mid-task:

> "I'm done working with `<instance-id>` over SSH. Want me to revoke the pushed key now
> (`revoke.sh`/`revoke.ps1`), or leave it in place in case you need it again soon?"

Leaving the key in place is a valid, expected choice — reconnecting to the same instance
reuses it automatically instead of pushing a new one.

## Troubleshooting

- **"Instance is not SSM-managed/online"** — check `aws ssm describe-instance-information`
  for the instance; usually the SSM Agent isn't running or the IAM role is missing the
  managed-instance policy.
- **`ssh` hangs or fails after `connect.sh` succeeded** — confirm `session-manager-plugin`
  is on `PATH` in the same shell running `ssh` (it's invoked as the `ProxyCommand`), and
  that its AWS credentials match the profile `connect.sh` used to push the key.
- **`ssh` fails with a 403 "Server authentication failed"** — a different, earlier `Host`
  block in `~/.ssh/config` is matching first (ssh resolves per-keyword, first-match-wins,
  not most-specific-wins). Common cause: a pre-existing generic `Host i-* mi-*` block.
  `connect.sh`/`connect.ps1` always prepend their block for this reason — if it still
  happens, look for another block above the `# BEGIN ssm-ssh-access ...` marker.
- **Every `ssh i-<id>` call prints "Warning: Permanently added ... to the list of known
  hosts"**, even on repeat connections — harmless. Usually the same generic `Host i-* mi-*`
  block above sets `UserKnownHostsFile /dev/null`, and since our block doesn't set that
  keyword, ssh inherits it from the later block — no host key ever actually persists.
  Safe to ignore.
