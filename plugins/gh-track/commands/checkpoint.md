---
description: Post a gh-track checkpoint (spec, plan, build-started, scope-change, blocked, done, repro, root-cause) for this workspace's tracked issue
argument-hint: <event>
---

The user wants to post a checkpoint for event: $ARGUMENTS

Use the `tracking-work-in-github` skill to do this. Resolve the issue with
`ghtrack resolve` first, read `references/issue-anatomy.md` for the exact
template for this event, and follow the checkpoint procedure in the skill
(publish artifact if applicable, write the comment, update the body, advance
the stage) in that order.

If `$ARGUMENTS` is empty or not one of the known events, ask the user which
event they mean instead of guessing.
