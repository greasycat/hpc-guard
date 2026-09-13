---
name: hpc
description: "HPC guard mode: while it is on, nothing reaches the cluster except as a numbered, purpose-stating bash script that the user runs by pressing Enter in their own tmux pane. Every guarded decision is logged to a hash-chained audit trail. Use when work touches a shared cluster — ssh to a login node, Slurm submission, cluster-mounted storage, or shipping job scripts."
trigger: /hpc
---

# /hpc

Cluster work is other people's work too: a stray `scancel`, an `rsync --delete` with the
slash in the wrong place, a job charged to the wrong account. On a machine where nothing
prompts, the guard is what stands between a plausible-looking command and a shared machine.

**The rule while the mode is on: I never touch the cluster. I write the action down, stage
it in your pane, and stop. You read it and press Enter.**

## Usage

```
/hpc on          # set the project up and turn the guard on
/hpc status      # is it on, what does it consider "the cluster", recent decisions
/hpc start       # print the tmux bootstrap for you to run
/hpc off         # prints the command — you run it, I cannot
/hpc verify      # check the audit chain for edits or gaps
```

## Where this sits

The action-script header is the project-wide provenance contract, specialized. Every code file
in the project carries `purpose` / `expectation` / `created` (`/organize` → Project layout
conventions — that skill ships in [sortyourpaper](https://github.com/greasycat/sortyourpaper) and is optional here); a cluster action adds `target` / `effect` / `undo`, because its reader is about to
press Enter on it and needs to know what it touches and how to undo it. Same idea, three extra
fields, enforced here by `hpc-guard.sh` rather than by the repo checker.

## Step 0 — read the project's conventions

Before staging anything, read from `CLAUDE.md`, the experiment registry, and the nearest
closed experiment: the **submission command** this project uses, its **account/partition**,
where **scratch** lives, and how results come back. Restate them before the first action so a
mismatch gets caught before a job is submitted, not after.

## `/hpc on`

Order matters — the guard is inert until `.hpc/ON` exists, and once it exists it refuses to
let me write these files.

1. `mkdir -p .hpc/actions .hpc/logs`
2. Copy `guard.conf.example` to `.hpc/guard.conf`. Resolve it from the skill symlink — the
   guard and its example config live beside `SKILL.md` in this repo, not in your project:

   ```bash
   for s in .claude/skills/hpc ~/.claude/skills/hpc; do
       [ -e "$s" ] && GUARD="$(dirname "$(readlink -f "$s")")" && break
   done
   ```
 **Ask which login hosts and mounted paths to add** — the shipped file
   has the Slurm and ssh verbs filled in and the site-specific lines commented out.
3. Write `.hpc/.gitignore` = `logs/`, `audit.jsonl`, `ON` — the action scripts stay tracked,
   so the ledger of what was run against the cluster lives in `git log`.
4. Register the hook in the project's `.claude/settings.json` (create it, or merge if present):

```json
{
  "env": { "SSH_AUTH_SOCK": "", "KRB5CCNAME": "FILE:/dev/null" },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash|Write|Edit|NotebookEdit",
        "hooks": [ { "type": "command", "timeout": 10,
                     "command": "<$GUARD>/hpc-guard.sh" } ] }
    ]
  }
}
```

The `env` block is the half that does not depend on pattern matching: it leaves my shell
with no ssh agent and no Kerberos ticket, so a command that slips past the patterns still
cannot authenticate. Your tmux server, started before this, keeps the real credentials.

5. `touch .hpc/ON`
6. **Tell the user to restart the session** — hooks are read at startup, so the registration
   takes one restart. After that `on`/`off` flips the mode file and takes effect immediately.

## `/hpc start` — the pane

You run this, not me. The pane must inherit *your* credentials; if I created it, it would
inherit my stripped environment and the separation would be pointless.

```bash
tmux new-session -s "hpc-$(basename "$PWD")"
tmux pipe-pane -o -t "hpc-$(basename "$PWD")" "cat >> $PWD/.hpc/logs/pane.log"
```

`pipe-pane` is what satisfies "everything is logged": it captures the whole pane, including
commands you type yourself, not only the ones I stage.

## The staging loop

Per action, every time:

1. **Write** `.hpc/actions/NNNN-<slug>.sh` — next unused number, four digits. Header first:

```bash
#!/usr/bin/env bash
# purpose: resubmit array tasks 12,17,23 that failed with OOM
# target:  login1.hpc.example.edu
# effect:  submits 3 jobs to partition `short`, writes $SCRATCH/exp/abc/logs/
# undo:    scancel <job id printed below>
set -euo pipefail
trap 'echo "=== action done, exit $? ==="' EXIT
```

All four keys are required and the guard checks them — `undo:` may be `none — read-only`.
Write the undo line *first*: if you cannot state how to reverse it, that is the finding, and
it goes to the user before the script does.

The `trap` is the footer the watch in step 4 keys on. On `EXIT` it fires whether the script
succeeded, failed under `set -e`, or was interrupted, so the marker means *finished*, never
*succeeded* — read the log for that.

2. **Show the whole body in chat.** The pane shows one line; the user should not have to open
   a file to know what they are approving.

3. **Stage it, without Enter:**

```bash
tmux send-keys -t "hpc-<proj>" 'bash .hpc/actions/0007-resubmit-oom-tasks.sh 2>&1 | tee -a .hpc/logs/0007.log'
```

4. **Stop, and arm one watch.** Say: the command is in the pane unexecuted — read it, Enter
   to run, Ctrl-C to reject. Then start a single background wait on the log, so the result
   comes back on its own instead of being polled or waited on by the user:

```bash
# Bash tool, run_in_background: true — one notification, then it exits
until grep -q '=== action done' .hpc/logs/0007.log 2>/dev/null; do sleep 5; done
```

   That shape is the *only* form the guard accepts against `.hpc/logs/` — whole-command
   anchored, one `sleep`, nothing riding behind the `done`. Use `Bash` with
   `run_in_background`, never the `Monitor` tool: an action fires once, so one wake-up is
   wanted, and a `tail -f` would sit armed long after the log went quiet. Arm it *after*
   staging and then say nothing further — the user may take minutes to press Enter, and a
   watch is not a reason to nag.

   Never stage a second action while one is unrun. `send-keys` appends to the pane's
   current input line, so two staged commands **concatenate**: `... | tee -a
   .hpc/logs/0003.log` followed by `bash .hpc/actions/0004-x.sh` becomes `tee -a
   .hpc/logs/0003.logbash .hpc/actions/0004-x.sh`, and tee overwrites the next action
   script with log text. One in flight at a time.

5. **Read the result** from `.hpc/logs/NNNN.log`. Never re-run an action script and never
   edit one — the body that was reviewed must be the body that ran. Changed your mind?
   Next number.

6. **Retire what never ran.** An action superseded before execution — wrong command, bad
   assumption, replaced by a later number — gets renamed in place, and this is the one
   mutation the guard permits:

```bash
mv .hpc/actions/0004-probe-shell-route.sh .hpc/actions/0004-probe-shell-route.sh.abort
```

   Same name, same number, `.abort` appended. The number stays spent so it can never be
   reused, the proposal stays in `git log` as a record of what was considered, and
   `STAGE_RE` cannot match a `.sh.abort`, so a retired action is unstageable from then on.
   Say in one line why it was retired. Abort only what has *not* run — an action that
   executed is history, and history is not tidied.

## What the guard refuses

Direct `ssh`/`rsync`/`sbatch` and friends; writes to cluster-mounted paths; any tmux verb
that can execute without a keypress (`run-shell`, `paste-buffer`, `respawn-pane`, …);
`send-keys` carrying `Enter`, `C-m` or `-H`; edits to an action script that already exists;
and anything touching `.hpc/ON`, `.hpc/guard.conf`, `.hpc/audit.jsonl`, `.hpc/logs/` or
`.claude/settings.json`.

Action scripts are immutable through **Bash** as well as Write/Edit: no `rm`, no `sed -i`,
no rename other than the `.sh.abort` retirement above — and no `bash .hpc/actions/NNNN-x.sh`,
since running a staged action is the keypress that belongs to the human. Remote verbs are
tested before the read exemptions, so a command that merely mentions a log cannot carry an
`ssh` past them.

Reads pass: `cat`, `ls`, `head`, `tail`, `grep`, `find` and similar are allowed even on
mounted paths and on the audit log, as long as there is no redirect and no `tee`. The one
non-read allowed against `.hpc/logs/` is the `until grep -q … ; do sleep N; done` watch from
step 4, matched whole-command.

Locally-authored job scripts are **not** restricted — edit them freely. The gate is the
moment bytes reach the cluster, which is a staged `rsync`. When staging one, show the user
`git status --short` of what is about to ship.

## `/hpc off`

I cannot do this, by design — an agent that can switch off its own guard has no guard.
Print it and let the user run it:

```bash
rm .hpc/ON
```

## `/hpc status`

Whether `.hpc/ON` exists, the `remote`/`path` lines currently in `.hpc/guard.conf`, whether a
`hpc-<proj>` tmux session is alive, and the last ~15 audit entries. Read-only — every one of
those reads is allowed while the mode is on.

## The audit trail

`.hpc/audit.jsonl`, one object per guarded call, allow *and* deny, each line carrying the
sha256 of the line before it. `hpc-guard.sh --verify .hpc/audit.jsonl` walks the chain
and names the first line that does not match. Staged actions log the script's own hash, so
the log says which bytes were approved.

This is tamper-**evident**, not tamper-proof: it detects an edit, it does not prevent one.
Real append-only needs `chattr +a` and root.
