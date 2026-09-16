#!/usr/bin/env bash
# test-hpc-guard.sh — the decision table hpc-guard.sh must never get wrong.
# The stakes are a shared cluster, so the cases that matter are the ones the
# guard must REFUSE: a direct submission, a keypress I sent myself, an edit to
# the script you already approved, and any attempt to switch the guard off.
#
# purpose:     hold hpc-guard.sh to its decision table
# expectation: all assertions pass; a failure means a class of cluster-reaching
#              command is now allowed through without a human keypress
# created:     2026-09-08
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
guard="$here/hpc-guard.sh"
pass=0 fail=0

t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/.hpc/actions" "$t/.hpc/logs"
cp "$here/guard.conf.example" "$t/.hpc/guard.conf"
cat >>"$t/.hpc/guard.conf" <<'EOF'
remote  login1\.hpc\.example\.edu
path    ^/mnt/cluster/
EOF

# ask the guard about one tool call; echoes the rule it applied, or "allow"
ask() { # ask <tool> <json-of-tool_input> [session_id]
    local out
    out=$(jq -cn --arg t "$1" --arg c "$t" --argjson i "$2" --arg s "${3:-sessaaaa}" \
              '{session_id:$s,cwd:$c,tool_name:$t,tool_input:$i}' | bash "$guard")
    if [[ -z $out ]]; then echo allow
    else jq -r '.hookSpecificOutput.permissionDecision' <<<"$out"; fi
}
bash_call() { ask Bash "$(jq -cn --arg c "$1" '{command:$c}')" "${2:-}"; }
file_call() { ask "$1" "$(jq -cn --arg p "$2" '{file_path:$p}')"; }

check() { # check <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else
        fail=$((fail+1)); printf 'FAIL  %s\n      expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

# --- mode off: the guard has no opinion and writes nothing -------------------
check "mode off is a no-op"          "allow" "$(bash_call 'ssh login1.hpc.example.edu uptime')"
check "mode off writes no log"       "0"     "$(ls "$t/.hpc/audit.jsonl" 2>/dev/null | wc -l)"

touch "$t/.hpc/ON"

# --- reaching the cluster directly ------------------------------------------
check "ssh denied"                   "deny"  "$(bash_call 'ssh login1.hpc.example.edu uptime')"
check "sbatch denied"                "deny"  "$(bash_call 'sbatch job.slurm')"
check "rsync denied"                 "deny"  "$(bash_call 'rsync -a ./out/ remote:/scratch/')"
check "hostname denied"              "deny"  "$(bash_call 'cat /dev/null; login1.hpc.example.edu')"
check "local work still passes"      "allow" "$(bash_call 'python fit.py --seed 1')"
check "a word containing ssh passes" "allow" "$(bash_call 'python parse_sshkeys_test.py')"

# --- mounted cluster storage: reads yes, writes no --------------------------
check "read of mount allowed"        "allow" "$(bash_call 'cat /mnt/cluster/x.log')"
check "redirect onto mount denied"   "deny"  "$(bash_call 'echo x > /mnt/cluster/x.log')"
check "tee onto mount denied"        "deny"  "$(bash_call 'cat a | tee /mnt/cluster/x.log')"
check "rm on mount denied"           "deny"  "$(bash_call 'rm -rf /mnt/cluster/run7')"
check "Write onto mount denied"      "deny"  "$(file_call Write /mnt/cluster/job.slurm)"
check "Edit onto mount denied"       "deny"  "$(file_call Edit /mnt/cluster/job.slurm)"

# --- the guard's own files --------------------------------------------------
check "rm .hpc/ON denied"            "deny"  "$(bash_call 'rm .hpc/ON')"
check "editing guard.conf denied"    "deny"  "$(file_call Edit "$t/.hpc/guard.conf")"
check "editing settings.json denied" "deny"  "$(file_call Edit "$t/.claude/settings.json")"
check "truncating the log denied"    "deny"  "$(bash_call ': > .hpc/audit.jsonl')"
check "reading the log allowed"      "allow" "$(bash_call 'tail -n 20 .hpc/audit.jsonl')"

# --- staging: the action script contract ------------------------------------
act="$t/.hpc/actions/0001-say-hello.sh"
printf '#!/usr/bin/env bash\n# purpose: prove the loop\n# target:  local\n# effect:  prints one line\n# undo:    none — read-only\nset -euo pipefail\necho hello\n' >"$act"
W="tmux -L hpcguard send-keys -t hpc-x:sessaaaa"
stage="$W 'bash .hpc/actions/0001-say-hello.sh 2>&1 | tee -a .hpc/logs/0001.log'"

check "complete action stages"       "allow" "$(bash_call "$stage")"
check "staging logs the script hash" "1"     "$(grep -c "$(sha256sum "$act" | cut -d' ' -f1)" "$t/.hpc/audit.jsonl")"
check "Enter denied"                 "deny"  "$(bash_call "$stage Enter")"
check "C-m denied"                   "deny"  "$(bash_call "$stage C-m")"
check "hex send denied"              "deny"  "$(bash_call 'tmux -L hpcguard send-keys -H -t hpc-x:sessaaaa 0d')"
check "arbitrary text not staged"    "deny"  "$(bash_call "$W 'sbatch job.slurm'")"
check "no tail may ride along"      "deny"  "$(bash_call "$W 'bash .hpc/actions/0001-say-hello.sh; sbatch job.slurm'")"
check "no head may ride along"      "deny"  "$(bash_call "$W 'rm .hpc/ON; bash .hpc/actions/0001-say-hello.sh'")"
check "stage without tee allowed"   "allow" "$(bash_call "$W 'bash .hpc/actions/0001-say-hello.sh'")"
check "new-session denied"          "deny"  "$(bash_call 'tmux -L hpcguard new-session -d -s hpc-x sbatch')"
check "missing script denied"        "deny"  "$(bash_call "$W 'bash .hpc/actions/0099-nope.sh'")"

printf '#!/usr/bin/env bash\n# purpose: p\n# target:  local\n# effect:  e\nset -euo pipefail\n' >"$t/.hpc/actions/0002-no-undo.sh"
check "missing undo: denied"         "deny"  "$(bash_call "$W 'bash .hpc/actions/0002-no-undo.sh'")"

# --- tmux verbs that run without a keypress ---------------------------------
check "run-shell denied"             "deny"  "$(bash_call 'tmux -L hpcguard run-shell -t hpc-x "sbatch job.slurm"')"
check "paste-buffer denied"          "deny"  "$(bash_call 'tmux -L hpcguard paste-buffer -t hpc-x')"
check "respawn-pane denied"          "deny"  "$(bash_call 'tmux -L hpcguard respawn-pane -k -t hpc-x "sh -c sbatch"')"
check "capture-pane allowed"         "allow" "$(bash_call 'tmux -L hpcguard capture-pane -p -t hpc-x')"

# --- one window per session -------------------------------------------------
# Added 2026-09-15: two agents sharing a pane splice their staged lines together
# (send-keys appends to the current input line), so a session may only stage into
# the window named after its own session id.
W2="tmux -L hpcguard send-keys -t hpc-x:sessbbbb"
check "staging into another session's window denied" \
    "deny"  "$(bash_call "$W2 'bash .hpc/actions/0001-say-hello.sh'")"
check "that same window is fine for its owner" \
    "allow" "$(bash_call "$W2 'bash .hpc/actions/0001-say-hello.sh'" sessbbbb)"
check "staging off the guard socket denied" \
    "deny"  "$(bash_call "tmux send-keys -t hpc-x:sessaaaa 'bash .hpc/actions/0001-say-hello.sh'")"
check "bare pane name denied"        "deny"  "$(bash_call "tmux -L hpcguard send-keys -t hpc-x 'bash .hpc/actions/0001-say-hello.sh'")"
check "opening my own window allowed" "allow" \
    "$(bash_call 'tmux -L hpcguard new-window -d -t hpc-x -n sessaaaa -c /tmp/p')"
check "opening it without -c allowed" "allow" \
    "$(bash_call 'tmux -L hpcguard new-window -d -t hpc-x -n sessaaaa')"
check "opening someone else's window denied" "deny" \
    "$(bash_call 'tmux -L hpcguard new-window -d -t hpc-x -n sessbbbb')"
check "new-window carrying a command denied" "deny" \
    "$(bash_call 'tmux -L hpcguard new-window -d -t hpc-x -n sessaaaa sbatch job.slurm')"

# --- action scripts are immutable once written ------------------------------
check "editing a staged action denied" "deny"  "$(file_call Edit "$t/.hpc/actions/0001-say-hello.sh")"
check "overwriting it denied"          "deny"  "$(file_call Write "$t/.hpc/actions/0001-say-hello.sh")"
check "a new action number allowed"    "allow" "$(file_call Write "$t/.hpc/actions/0003-next.sh")"
check "local job scripts still free"   "allow" "$(file_call Edit "$t/jobs/train.slurm")"

# --- immutability holds through Bash, not only Write/Edit -------------------
# Added 2026-09-13: mv/rm/sed on an action used to fall through to `allow pass`,
# and `bash .hpc/actions/...` let the agent run a script staged for the human.
check "rm of an action denied"       "deny"  "$(bash_call 'rm .hpc/actions/0001-say-hello.sh')"
check "sed -i on an action denied"   "deny"  "$(bash_call 'sed -i s/hello/bye/ .hpc/actions/0001-say-hello.sh')"
check "running an action myself denied" "deny" "$(bash_call 'bash .hpc/actions/0001-say-hello.sh')"
check "reading an action allowed"    "allow" "$(bash_call 'cat .hpc/actions/0001-say-hello.sh')"

# --- retiring an unrun action: the one sanctioned mutation ------------------
check "abort rename allowed"         "allow" "$(bash_call 'mv .hpc/actions/0001-say-hello.sh .hpc/actions/0001-say-hello.sh.abort')"
check "abort to another name denied" "deny"  "$(bash_call 'mv .hpc/actions/0001-say-hello.sh .hpc/actions/0009-other.sh.abort')"
check "abort with a tail denied"     "deny"  "$(bash_call 'mv .hpc/actions/0001-say-hello.sh .hpc/actions/0001-say-hello.sh.abort; sbatch j')"
check "rename without .abort denied" "deny"  "$(bash_call 'mv .hpc/actions/0001-say-hello.sh .hpc/actions/0001-renamed.sh')"
printf 'retired\n' >"$t/.hpc/actions/0004-retired.sh.abort"
check "staging an aborted action denied" "deny" "$(bash_call "$W 'bash .hpc/actions/0004-retired.sh.abort'")"
check "editing an aborted action denied" "deny" "$(file_call Edit "$t/.hpc/actions/0004-retired.sh.abort")"
check "overwriting an aborted action denied" "deny" "$(file_call Write "$t/.hpc/actions/0004-retired.sh.abort")"

# --- watching a staged action without polling the pane ----------------------
check "log wait allowed"             "allow" "$(bash_call "until grep -q '=== action done' .hpc/logs/0001.log 2>/dev/null; do sleep 3; done")"
check "log wait without redirect ok" "allow" "$(bash_call "until grep -q 'done' .hpc/logs/0042.log; do sleep 5; done")"
check "log wait with a tail denied"  "deny"  "$(bash_call "until grep -q 'done' .hpc/logs/0001.log; do sleep 3; done; sbatch j")"
check "log wait hiding a submit denied" "deny" "$(bash_call "until grep -q 'x' .hpc/logs/0001.log; do sbatch j; done")"
check "log wait onto another file denied" "deny" "$(bash_call "until grep -q 'x' .hpc/audit.jsonl; do sleep 3; done")"

# --- SessionStart tells the session its own window name ---------------------
ctx=$(jq -cn --arg c "$t" '{session_id:"sessaaaa-rest",cwd:$c,hook_event_name:"SessionStart"}' |
      bash "$guard" | jq -r '.hookSpecificOutput.additionalContext // ""')
check "SessionStart names the window" "1" "$(grep -c '"sessaaaa"' <<<"$ctx")"
check "SessionStart logs nothing"     "0" "$(grep -c SessionStart "$t/.hpc/audit.jsonl")"

# --- the audit chain --------------------------------------------------------
check "every call was logged"        "allow" "$(bash_call 'echo counted')"
check "chain verifies"               "0"     "$(bash "$guard" --verify "$t/.hpc/audit.jsonl" >/dev/null; echo $?)"
sed -i '3s/"tool":"Bash"/"tool":"Edit"/' "$t/.hpc/audit.jsonl"
check "an edited line is detected"   "1"     "$(bash "$guard" --verify "$t/.hpc/audit.jsonl" >/dev/null; echo $?)"
check "and it names the line"        "4"     "$(bash "$guard" --verify "$t/.hpc/audit.jsonl" | grep -oE 'line [0-9]+' | grep -oE '[0-9]+')"

# Added 2026-09-15: read-prev-then-append is a read-modify-write. Before flock,
# two sessions logging at once both chained off the same predecessor.
# Its own project dir: the chain in $t was deliberately corrupted just above.
c=$(mktemp -d); mkdir -p "$c/.hpc"; touch "$c/.hpc/ON" "$c/.hpc/guard.conf"
for i in $(seq 1 12); do
    jq -cn --arg c "$c" --arg s "sess$i" \
        '{session_id:$s,cwd:$c,tool_name:"Bash",tool_input:{command:"echo parallel"}}' |
        bash "$guard" >/dev/null &
done; wait
check "12 parallel sessions all logged" "12" "$(wc -l <"$c/.hpc/audit.jsonl")"
check "chain survives 12 parallel sessions" "0" \
    "$(bash "$guard" --verify "$c/.hpc/audit.jsonl" >/dev/null; echo $?)"
rm -rf "$c"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
