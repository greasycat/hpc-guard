#!/usr/bin/env bash
# hpc-pane.sh — start or attach the guarded tmux server for this project. YOU run
# this, never the agent: the server must be born from your shell so it holds your
# ssh agent and Kerberos ticket, which the agent's shell has had stripped.
#
# Run it once per project, from the project root. Agents then open their own
# windows in it (one per session, named after the session id) and stage into
# those; you watch, read, and press Enter.
#
# purpose:     give every agent session its own credential-holding pane, unattended
# expectation: idempotent — re-running attaches to the existing server rather than
#              reconfiguring it; each window logs itself to .hpc/logs/pane-<name>.log
# created:     2026-09-15
set -euo pipefail

sock=hpcguard
sess="hpc-$(basename "$PWD")"
[ -d .hpc ] || { echo "no .hpc/ here — run /hpc on in this project first" >&2; exit 1; }
mkdir -p .hpc/logs

if ! tmux -L "$sock" has-session -t "$sess" 2>/dev/null; then
    tmux -L "$sock" new-session -d -s "$sess" -c "$PWD"
    # The whole point: a window opened by the agent's tmux client must NOT inherit
    # the agent's emptied SSH_AUTH_SOCK. Emptying update-environment freezes the
    # server on the environment it was born with — yours.
    tmux -L "$sock" set -g update-environment ""
    # Every window logs itself, including ones you open and type in by hand.
    tmux -L "$sock" set-hook -g after-new-window \
        "pipe-pane -o 'cat >> $PWD/.hpc/logs/pane-#{window_name}.log'"
    tmux -L "$sock" pipe-pane -o -t "$sess:0" "cat >> $PWD/.hpc/logs/pane-user.log"
    echo "started $sess on socket $sock"
fi

# ponytail: the server keeps the SSH_AUTH_SOCK it was born with. After a re-login
# that socket is stale — `tmux -L hpcguard kill-server` and run this again.
exec tmux -L "$sock" attach -t "$sess"
