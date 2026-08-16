# ssm-ssh-access

Plain `ssh <instance-id>` and `scp <file> <instance-id>:<path>` against any
SSM-managed EC2 instance — **no bastion host, no open port 22, no VPN.**

Traffic tunnels through `aws ssm start-session`, the same channel the AWS
Console's "Connect" button uses. The instance keeps its security group shut.

## Install

Once per machine — no clone required, this pulls straight from GitHub:

```
/plugin marketplace add mr-ashishpanda/applied-ai-innovation
/plugin install ssm-ssh-access@applied-ai-innovation
```

(If you already added the marketplace for `gh-track`, you only need the second
line.)

Then, once per machine, install AWS's `session-manager-plugin` binary:

```bash
ssm-install-plugin          # macOS/Linux
```

On Windows, run `skills/ssm-ssh-access/scripts/install-plugin.ps1` from the
installed plugin directory instead.

## Use it

Ask Claude in plain English — "ssh into i-0123456789abcdef0 using my prod
profile" — or use the slash commands:

| Command | Does |
|---|---|
| `/ssm-ssh-access:connect <instance-id> [--profile P] [--user U]` | Push a key and wire up `~/.ssh/config` |
| `/ssm-ssh-access:status` | Read-only: list instances with a key currently pushed |
| `/ssm-ssh-access:revoke <instance-id>` | Remove the key, locally and on the instance |

After a successful connect, the instance ID *is* an SSH host:

```bash
ssh i-0123456789abcdef0
scp ./file.txt i-0123456789abcdef0:/tmp/
```

## From a plain terminal

The plugin puts four commands on your `PATH`, so none of this requires Claude:

| Command | Does |
|---|---|
| `ssm-install-plugin` | Install AWS's `session-manager-plugin` (one-time) |
| `ssm-connect --instance-id i-… [--profile P] [--region R] [--user U]` | Push key, wire `~/.ssh/config` |
| `ssm-status` | List instances with a key currently pushed |
| `ssm-revoke --instance-id i-… [--profile P]` | Revoke and clean up |

These are shims over the PowerShell/bash scripts in
`skills/ssm-ssh-access/scripts/`. They dispatch to the `.sh` versions, so on
Windows they work under Git Bash; native PowerShell users call the `.ps1`
scripts directly (`connect.ps1 -InstanceId … -User …`).

Omitting `--user` on `ssm-connect` opens an interactive picker over the
instance's real users — convenient in a terminal, but it needs a TTY, so
Claude always passes `--user` explicitly.

## Prerequisites

- **AWS CLI v2**, authenticated for the target account.
- **`session-manager-plugin`** on `PATH` (see `ssm-install-plugin` above).
- **On the instance:** SSM Agent running, plus an IAM role carrying
  `AmazonSSMManagedInstanceCore` or equivalent. `connect` checks this and fails
  with a clear message if it isn't met.
- **For your identity:** `ssm:SendCommand`, `ssm:GetCommandInvocation`,
  `ssm:DescribeInstanceInformation`, `ssm:StartSession` on the target
  instance(s).

## What it writes

Nothing here is hidden in a script you'd have to read to find out:

| Write | When | Undone by |
|---|---|---|
| A per-instance ed25519 keypair under `~/.ssh/` | `connect` | `revoke` |
| The public key appended to the instance's `authorized_keys`, via `ssm send-command` | `connect` | `revoke` |
| A `Host <instance-id>` block prepended to `~/.ssh/config` | `connect` | `revoke` |
| `session-manager-plugin`, via the system package manager (may use `sudo`) | `ssm-install-plugin` | your package manager |

The key is **temporary by intent**: `revoke` removes all three at once. Leaving
it in place is a valid choice too — reconnecting to the same instance reuses the
existing key instead of pushing a new one. Claude will offer to revoke when it
finishes working with an instance, and won't do it unprompted.

## Troubleshooting

See the [skill](./skills/ssm-ssh-access/SKILL.md#troubleshooting) for the full
list — the two that bite most often:

- **`ssh` hangs or fails after a successful connect** — `session-manager-plugin`
  must be on `PATH` in the *same* shell running `ssh`; it's invoked as the
  `ProxyCommand`.
- **403 "Server authentication failed"** — an earlier, more generic `Host i-*`
  block in `~/.ssh/config` is matching first. ssh resolves first-match-wins per
  keyword, which is why this plugin always *prepends* its block.

## License

MIT
