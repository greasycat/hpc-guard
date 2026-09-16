# hpc-guard

Guard mode for agent work that touches a shared HPC cluster. While it is on, the agent
never reaches the cluster itself: every cluster-bound command becomes a numbered,
purpose-stating bash script staged **unexecuted** in your own tmux pane. You read it and
press Enter. Every guarded decision — allow and deny — lands in a hash-chained audit log.

Built for machines running Claude Code with `permissions.defaultMode: "auto"`, where
nothing prompts and the blast radius is other people's jobs.

## Files

| file | what it is |
|---|---|
| `SKILL.md` | the `/hpc` skill — the protocol the agent follows |
| `hpc-guard.sh` | the `PreToolUse` hook that enforces it |
| `hpc-pane.sh` | you run this once per project: starts the guarded tmux server |
| `guard.conf.example` | what counts as "the cluster": remote verbs and mounted paths |
| `test-hpc-guard.sh` | the decision table, 73 assertions |

## Install

Symlink this directory in as a skill, then let `/hpc on` do the rest:

```bash
ln -sfn "$PWD" ~/.claude/skills/hpc
```

In the project you want guarded, run `/hpc on`. It writes `.hpc/`, registers
`hpc-guard.sh` as a `PreToolUse` hook in that project's `.claude/settings.json`, and
strips `SSH_AUTH_SOCK`/`KRB5CCNAME` from the agent's shell — so a command that slips past
the patterns still cannot authenticate. Hooks are read at startup, so it takes one session
restart. `SKILL.md` is the full protocol.

## Several agents at once

`bash hpc-pane.sh` starts one tmux server per project, from *your* shell, so it holds your
credentials. Each agent session then opens its own window in it, named after its session id,
and may stage into that window and no other — otherwise two sessions' staged commands
splice together on one input line. The audit chain is one file for the project, appended
under `flock` and tagged with the session id, so parallel work stays one readable timeline.

The guard is inert unless `.hpc/ON` exists. `/hpc off` prints `rm .hpc/ON` for you to run:
an agent that can switch off its own guard has no guard.

## Test

```bash
./test-hpc-guard.sh     # needs jq
```

## Used by

[sortyourpaper](https://github.com/greasycat/sortyourpaper) vendors this as a submodule at
`skills/hpc`.
