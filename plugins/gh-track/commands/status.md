---
description: Show gh-track environment health and this workspace's tracked issue
---

Run `ghtrack doctor` and report every line to the user, verbatim, without
summarizing away the `problems=` count.

Then run `ghtrack resolve`. If it succeeds, run `ghtrack show <issue>` on the
resulting number and report the issue's title, stage, kind, size, and task
progress. If `resolve` fails (exit 3), tell the user this workspace's branch
does not resolve to a tracked issue and that `ghtrack resolve --set N` will
record one manually.

Do not create an issue, change a stage, or write anything — this command is
read-only.
