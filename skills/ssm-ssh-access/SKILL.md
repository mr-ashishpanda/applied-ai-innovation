---
name: ssm-ssh-access
description: Use when you need to SSH or SCP into a private AWS EC2 instance by instance ID (no bastion, no open port 22, no VPN) using AWS Systems Manager Session Manager as the transport. Covers installing the session-manager-plugin, pushing a temporary SSH key to the instance over SSM, configuring SSH so `ssh <instance-id>` works directly, and revoking the key afterwards.
---

# ssm-ssh-access

Lets you (and the agent) run plain `ssh <instance-id>` / `scp <file> <instance-id>:<path>`
against any AWS EC2 instance managed by SSM — even if it has no public IP and port 22 is
closed — by tunneling the SSH session through `aws ssm start-session`.

## How it works

1. A per-instance ed25519 keypair is generated locally (or reused if one already exists
   for that instance).
2. The public key is pushed to the instance's `authorized_keys` via `aws ssm send-command`
   — a one-time, idempotent copy. No port 22 is ever opened; this uses the same channel as
   the AWS Console's "Session Manager" connect button.
3. A `Host <instance-id>` block is added to your local SSH config, with `ProxyCommand`
   set to tunnel through SSM. After this, `ssh <instance-id>` behaves like normal SSH.
4. When you're done, a revoke script removes the key from the instance and cleans up
   locally.

## Prerequisites (one-time, per machine)

- AWS CLI v2, already configured with credentials/profile for the target account.
- The AWS `session-manager-plugin`. Install it with:
  - macOS/Linux: `scripts/install-plugin.sh`
  - Windows (PowerShell): `scripts/install-plugin.ps1`
- The target instance must be SSM-managed: SSM Agent running, and an IAM instance
  profile with `AmazonSSMManagedInstanceCore` (or equivalent). `connect.sh`/`connect.ps1`
  check this and fail with a clear message if not.
- Your AWS identity needs `ssm:SendCommand`, `ssm:GetCommandInvocation`,
  `ssm:DescribeInstanceInformation`, and `ssm:StartSession` permissions on the target
  instance(s).

## Usage

**Connect** (macOS/Linux):
```bash
skills/ssm-ssh-access/scripts/connect.sh --instance-id i-0123456789abcdef0 --profile my-profile
```

**Connect** (Windows):
```powershell
skills/ssm-ssh-access/scripts/connect.ps1 -InstanceId i-0123456789abcdef0 -Profile my-profile
```

You'll be prompted to pick a remote user from a real list discovered on the instance
(entries under `/home` plus `root`) — this is queried live every run, never guessed.

Once connect finishes, use the instance ID like a normal SSH host for the rest of the
session:
```bash
ssh i-0123456789abcdef0
scp ./file.txt i-0123456789abcdef0:/tmp/
```

**Check what's currently deployed:**
```bash
skills/ssm-ssh-access/scripts/status.sh        # macOS/Linux
skills/ssm-ssh-access/scripts/status.ps1       # Windows
```

**Revoke** (removes the key from the instance, deletes local key material, and removes
the SSH config block):
```bash
skills/ssm-ssh-access/scripts/revoke.sh --instance-id i-0123456789abcdef0 --profile my-profile
skills/ssm-ssh-access/scripts/revoke.ps1 -InstanceId i-0123456789abcdef0 -Profile my-profile
```

## Agent behavior: end-of-session cleanup reminder

If you (the agent) used this skill to SSH/SCP into an instance during a task, ask the
user once you're done with that instance whether they want the key revoked now — don't
revoke automatically, and don't block on an answer if the user is mid-task. A good
prompt:

> "I'm done working with `<instance-id>` over SSH. Want me to revoke the pushed key now
> (`revoke.sh`/`revoke.ps1`), or leave it in place in case you need it again soon?"

Leaving the key in place is a valid, expected choice — reconnecting to the same instance
reuses the existing key automatically instead of pushing a new one.

## Troubleshooting

- **"Instance is not SSM-managed/online"** — check `aws ssm describe-instance-information`
  for the instance; usually means the SSM Agent isn't running or the instance's IAM role
  is missing the SSM managed-instance policy.
- **`ssh` hangs or fails after connect.sh succeeded** — confirm `session-manager-plugin`
  is on `PATH` in the same shell you're running `ssh` from (it's invoked as the
  `ProxyCommand`), and that the AWS credentials used by that shell match the profile
  `connect.sh` used to push the key.
- **Re-running connect.sh for the same instance** — reuses the existing local key and
  skips re-pushing, but still asks you to reconfirm the remote user, since the instance's
  users could have changed since the last run.
