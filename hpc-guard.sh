#!/usr/bin/env bash
# hpc-guard.sh — PreToolUse guard for HPC mode. Protocol: SKILL.md, alongside this file.
#
# Live only while ./.hpc/ON exists. Denies anything that reaches the cluster
# directly, and requires cluster work to be staged as a reviewed action script
# that the human runs by pressing Enter in their own tmux pane.
#
# Guards a mistaken agent, not an adversarial one: command-string matching is
# defeatable by anyone trying. The control that does not rely on matching is
# credential separation (the tmux server holds the ssh agent, this shell does not).
#
# Concurrent sessions: each agent session owns one tmux window, named after the
# first 8 chars of its session_id, on the shared `hpcguard` socket. A session may
# only stage into its own window — two agents sharing a pane would concatenate
# their staged lines. The audit chain is one file, appended under flock.
#
# stdin: PreToolUse JSON. stdout: a deny decision, or nothing (= fall through).
#
# purpose:     gate every cluster-reaching tool call behind a reviewed action script
# expectation: with .hpc/ON absent this is a no-op costing one stat; with it present
#              no ssh/rsync/sbatch, no keypress I send myself, and no edit to the
#              guard's own files gets through — test-hpc-guard.sh asserts each
# created:     2026-09-08
set -uo pipefail   # deliberately not -e: a non-matching grep must not kill the guard

log=.hpc/audit.jsonl

# ---------------------------------------------------------------- --verify ---
# Each line carries the sha256 of the line before it. An edited or removed line
# breaks the chain at that point.
# ponytail: hash chain, not append-only — real immutability needs chattr +a and root.
verify_chain() {
    local f="${1:-$log}" line prev="" want n=0
    [[ -f $f ]] || { echo "no log at $f"; return 1; }
    while IFS= read -r line; do
        n=$((n + 1))
        want=$(jq -r '.prev // ""' <<<"$line" 2>/dev/null) || { echo "line $n: not JSON"; return 1; }
        [[ $want == "$prev" ]] || { echo "chain broken at line $n of $f"; return 1; }
        prev=$(printf '%s\n' "$line" | sha256sum | cut -d' ' -f1)
    done <"$f"
    echo "ok: $n entries, chain intact"
}
[[ ${1:-} == --verify ]] && { verify_chain "${2:-}"; exit $?; }

# ------------------------------------------------------------------ input ---
input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
[[ -n $cwd && -d $cwd ]] && cd "$cwd"

[[ -f .hpc/ON ]] || exit 0          # mode off: no cost, no logging, no opinion

emit_deny() {
    jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",
        permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
}

# Mode is on but the guard cannot evaluate: fail closed. A guard that degrades
# to "allow" under its own breakage is not a guard.
command -v jq >/dev/null || emit_deny "HPC mode is on but jq is missing, so the guard cannot evaluate this call. Install jq, or turn the mode off yourself with: rm .hpc/ON"

event=$(jq -r '.hook_event_name // empty' <<<"$input")
tool=$(jq -r '.tool_name // empty' <<<"$input")
sid=$(jq -r '.session_id // "?"' <<<"$input")
cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
fp=$(jq -r '.tool_input.file_path // empty' <<<"$input")

# This session's own tmux window. Everything staged must go here and nowhere
# else: send-keys appends to a pane's current input line, so two sessions sharing
# one pane splice their commands together. Stripped to [A-Za-z0-9] so it can be
# interpolated into a regex without escaping.
sid8=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9' | cut -c1-8)
sid8=${sid8:-nosid}
SOCK=hpcguard   # dedicated tmux server, started by the user, holding their credentials

# ------------------------------------------------------------ SessionStart ---
# A session cannot see its own id, and it needs it: the window it may stage into
# is named after it. Registered on SessionStart as well as PreToolUse, the guard
# hands the name over on the way in, so the first staging attempt is the right one
# rather than a denial that teaches it the name.
if [[ $event == SessionStart ]]; then
    msg=$(printf 'HPC guard mode is ON in this project.\nYour tmux window is "%s" on socket "%s" — the only pane you may stage into.\nOpen it once (it carries no command, so the guard allows it):\n  tmux -L %s new-window -d -t hpc-$(basename "$PWD") -n %s -c "$PWD"\nIf tmux reports no server, the user has not started the guarded pane yet — ask\nthem to run hpc-pane.sh from the project root.\nEvery action script must carry "# session: %s" in its header — I stage only what I wrote.\nStage an action with:\n  tmux -L %s send-keys -t hpc-<proj>:%s '"'"'bash .hpc/actions/NNNN-<slug>.sh 2>&1 | tee -a .hpc/logs/NNNN.log'"'"'\nProtocol: SKILL.md.\n' "$sid8" "$SOCK" "$SOCK" "$sid8" "$sid8" "$SOCK" "$sid8")
    jq -cn --arg c "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
    exit 0
fi

# ----------------------------------------------------------------- config ---
remote_pats=() path_pats=()
while read -r verb pat; do
    case "$verb" in
        remote) remote_pats+=("$pat") ;;
        path)   path_pats+=("$pat") ;;
    esac
done < <(grep -Ev '^[[:space:]]*(#|$)' .hpc/guard.conf 2>/dev/null)

# Files that configure or record the guard. Editing these is how a guard gets
# quietly removed, so nothing may write them while the mode is on — including
# .hpc/ON itself, which is why /hpc off is a command you run, not one I run.
# The boundary is "not a path/name character", so it catches `.hpc/ON` after a
# space or a quote as well as `/home/me/proj/.hpc/ON` after a slash.
B='(^|[^A-Za-z0-9_-])'
GUARD_OWNED="${B}\.hpc/(ON|guard\.conf|audit\.jsonl|logs(/|$))|${B}\.claude/settings(\.local)?\.json|hpc-guard\.sh"

# ------------------------------------------------------------------ audit ---
# Written before the decision is returned, so a crash in the decision path still
# leaves the record.
# Read-prev-then-append is a read-modify-write: two sessions doing it at once
# both chain off the same predecessor and the chain breaks at that point. flock
# serialises them. ponytail: no flock (macOS) degrades to the old race — fine for
# one session, and --verify still names the line if it ever bites.
audit() {  # decision rule [sha]
    mkdir -p .hpc
    {
        command -v flock >/dev/null && flock 9
        local prev=""
        [[ -s $log ]] && prev=$(tail -n1 "$log" | sha256sum | cut -d' ' -f1)
        jq -cn --arg ts "$(date -uIs)" --arg sid "$sid" --arg tool "$tool" \
            --arg d "$1" --arg r "$2" --arg t "${target:-}" --arg sha "${3:-}" --arg prev "$prev" \
            '{ts:$ts,sid:$sid,tool:$tool,decision:$d,rule:$r,target:$t,sha:$sha,prev:$prev}' >>"$log"
    } 9>>"$log"
}
deny()  { audit deny "$1" ""; emit_deny "$2"; }
allow() { audit allow "$1" "${2:-}"; exit 0; }   # silent: normal permission flow continues

# The pane target is pinned to this session's own window (`<session>:<sid8>`), on
# the guard's own socket. Another session's window is as off limits as the cluster.
PANE="[\"']?[A-Za-z0-9_.-]+:${sid8}[\"']?"
TMUX="tmux[[:space:]]+-L[[:space:]]+${SOCK}"
STAGE_RE="^[[:space:]]*${TMUX}[[:space:]]+send-keys[[:space:]]+-t[[:space:]]+${PANE}[[:space:]]+'bash[[:space:]]+\.hpc/actions/([0-9]{4}-[A-Za-z0-9._-]+\.sh)([[:space:]]+2>&1[[:space:]]+\|[[:space:]]+tee[[:space:]]+-a[[:space:]]+\.hpc/logs/[0-9]{4}\.log)?'[[:space:]]*$"

# Opening the session's own window is the one tmux mutation that is not a keypress
# risk — provided it carries no shell-command argument, which `new-window` would
# execute immediately. Anchored, so nothing may follow the window name but -c <dir>.
# The user's bootstrap sets `update-environment ""` and an after-new-window
# pipe-pane hook on this server, so a window I open still inherits *their*
# credentials and still logs itself.
NEWWIN_RE="^[[:space:]]*${TMUX}[[:space:]]+new-window[[:space:]]+-d[[:space:]]+-t[[:space:]]+[\"']?[A-Za-z0-9_.-]+[\"']?[[:space:]]+-n[[:space:]]+${sid8}([[:space:]]+-c[[:space:]]+[\"']?[A-Za-z0-9_./-]+[\"']?)?[[:space:]]*$"

# The one way to watch a staged action without polling the pane: block until the
# action's own footer marker lands in its log, then stop. Whole-command anchored
# for the same reason STAGE_RE is — a substring match would let a tail ride along.
# The only redirect permitted is grep's own 2>/dev/null, before the log exists.
LOGWAIT_RE="^[[:space:]]*until[[:space:]]+grep[[:space:]]+-q[[:space:]]+[\"'][^\"']*[\"'][[:space:]]+\.hpc/logs/[0-9]{4}\.log([[:space:]]+2>/dev/null)?[[:space:]]*;[[:space:]]*do[[:space:]]+sleep[[:space:]]+[0-9]+[[:space:]]*;[[:space:]]*done[[:space:]]*$"

STAGE_HINT='Stage it instead: write .hpc/actions/NNNN-<slug>.sh with a "# purpose:/# target:/# effect:/# undo:" header, show me the body, then send it to the tmux pane WITHOUT Enter. I press Enter.'

# A command that only reads. Any redirect or tee disqualifies it.
is_reader() {
    [[ $1 =~ (^|[^0-9<>])(>|>>)|[[:space:]]tee[[:space:]] ]] && return 1
    [[ $1 =~ ^[[:space:]]*(cat|ls|head|tail|grep|rg|wc|find|stat|du|file|md5sum|sha256sum|diff|realpath|readlink)[[:space:]] ]]
}

# ------------------------------------------------------------------- Bash ---
if [[ $tool == Bash ]]; then
    target=$cmd

    # tmux first: a staged action legitimately names .hpc/logs/, which the
    # guard-owned rule below would otherwise refuse. Safe to put first only
    # because the accepted form is an exact whole-command match — a substring
    # match here would let `send-keys 'rm .hpc/ON; bash .hpc/actions/0001-x.sh'`
    # through on the strength of its tail.
    if [[ $cmd =~ (^|[;&|[:space:]])tmux[[:space:]] ]]; then
        if [[ $cmd =~ send-keys ]]; then
            [[ $cmd =~ (Enter|C-m|\\r|\\n|[[:space:]]-H([[:space:]]|$)) ]] &&
                deny stage-carries-enter "Staging may not carry Enter — pressing it is your decision, not mine. Send the command text alone and I will stop and wait."
            [[ $cmd =~ $STAGE_RE ]] ||
                deny stage-not-an-action "Only a staged action script may go to your own window, exactly as: tmux -L $SOCK send-keys -t <session>:$sid8 'bash .hpc/actions/NNNN-<slug>.sh 2>&1 | tee -a .hpc/logs/NNNN.log'. Your window is named $sid8 — another session's window is off limits. $STAGE_HINT"
            script=".hpc/actions/${BASH_REMATCH[1]}"
            [[ -f $script ]] || deny stage-missing-file "$script does not exist yet — write it before staging it."
            for k in purpose target effect undo; do
                grep -qE "^#[[:space:]]*${k}:[[:space:]]*[^[:space:]]" "$script" ||
                    deny action-header "$script has no '# ${k}:' line. Every action states purpose, target, effect and undo before I ask you to approve it."
            done
            # An action is staged by the session that wrote it and showed you its
            # body. Without this, session A can stage B's script: the pane shows
            # one line, and the body you would be approving was reviewed in a
            # window you are not looking at.
            grep -qE "^#[[:space:]]*session:[[:space:]]*${sid8}[[:space:]]*$" "$script" ||
                deny action-authorship "$script does not carry '# session: $sid8'. An action is staged by the session that wrote it — another session's script was reviewed in a chat you are not reading. If it is mine, write the next number with that header line; if it is another session's, let that session stage it."
            allow stage "$(sha256sum "$script" | cut -d' ' -f1)"
        fi
        [[ $cmd =~ $NEWWIN_RE ]] && allow pane-new
        [[ $cmd =~ tmux[[:space:]]+([^[:space:]]+[[:space:]]+)*(capture-pane|list-|display-message|has-session|show-) ]] &&
            allow tmux-read
        deny tmux-write "That tmux verb can execute in the guarded pane without you pressing anything. Only 'send-keys' of a staged action script, and opening my own window (tmux -L $SOCK new-window -d -t <session> -n $sid8 -c <dir>), are allowed. $STAGE_HINT"
    fi

    # Remote verbs are checked before the guard-owned reads below, so that a
    # command which merely mentions a log cannot smuggle an ssh past the reader
    # exemption: `until grep -q x .hpc/logs/0001.log; do sbatch j; done` reads as
    # guard-owned-and-harmless unless the remote patterns get first look.
    for p in "${remote_pats[@]}"; do
        [[ $cmd =~ $p ]] && deny remote-cmd "That reaches the cluster directly, which HPC mode does not allow. $STAGE_HINT"
    done

    # Action scripts are immutable through Bash too, not only through Write/Edit.
    # Without this an `mv`/`rm`/`sed -i` walks straight past the immutability rule,
    # and `bash .hpc/actions/NNNN-x.sh` executes an approved-for-you script myself.
    # The single sanctioned mutation is retiring an action that was never run:
    # renaming it in place to <name>.sh.abort, which keeps the number taken and
    # leaves the proposal in the ledger. STAGE_RE cannot match a .sh.abort, so an
    # aborted action can never be staged afterwards.
    if [[ $cmd =~ ${B}\.hpc/actions/ ]]; then
        if [[ $cmd =~ ^[[:space:]]*mv[[:space:]]+\.hpc/actions/([0-9]{4}-[A-Za-z0-9._-]+\.sh)[[:space:]]+\.hpc/actions/([0-9]{4}-[A-Za-z0-9._-]+\.sh\.abort)[[:space:]]*$ ]] &&
           [[ ${BASH_REMATCH[2]} == "${BASH_REMATCH[1]}.abort" ]]; then
            allow action-abort
        fi
        is_reader "$cmd" && allow read-action
        deny action-immutable "Action scripts are immutable, and running one is your keypress, not mine. To retire an action that was never run: mv .hpc/actions/NNNN-<slug>.sh .hpc/actions/NNNN-<slug>.sh.abort — same name, same number, .abort appended. To change what an action does, write the next number."
    fi

    if [[ $cmd =~ $GUARD_OWNED ]]; then
        [[ $cmd =~ $LOGWAIT_RE ]] && allow log-wait
        is_reader "$cmd" && allow read-guard-file
        deny guard-owned "That touches the guard's own configuration or log, which is off limits while HPC mode is on. To turn the mode off, run it yourself: rm .hpc/ON"
    fi

    for p in "${path_pats[@]}"; do
        # A path pattern may be anchored for matching file paths; inside a command
        # string the path sits mid-line, so the anchor has to come off.
        if [[ $cmd =~ ${p#^} ]]; then
            is_reader "$cmd" && allow read-mount
            deny mount-write "That writes to cluster-mounted storage, which is live cluster state. $STAGE_HINT"
        fi
    done

    allow pass
fi

# ------------------------------------------------- Write / Edit / Notebook ---
target=$fp
[[ $fp =~ $GUARD_OWNED ]] &&
    deny guard-owned "That is the guard's own configuration or log. To turn HPC mode off, run it yourself: rm .hpc/ON"

for p in "${path_pats[@]}"; do
    [[ $fp =~ $p ]] &&
        deny mount-write "$fp is on cluster-mounted storage — editing it changes live cluster state. $STAGE_HINT"
done

if [[ $fp == *.hpc/actions/* ]]; then
    # Immutable once written: the script I showed you must be the script that runs.
    # An aborted action stays readable but is never writable again, under any tool.
    [[ $fp == *.abort ]] &&
        deny action-aborted "$fp is a retired action. Aborted actions are kept as a record of what was proposed, not reopened — write the next number."
    [[ $tool != Write || -e $fp ]] &&
        deny action-immutable "Action scripts are immutable once written — otherwise the body you reviewed and the body that runs can differ. Write the next number instead. (If that number appeared while you were composing, another session took it: re-read .hpc/actions/ and take the next free one.)"
    allow action-new
fi

allow pass
