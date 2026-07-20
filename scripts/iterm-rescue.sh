#!/usr/bin/env bash
#
# iterm-rescue.sh — attach all live Banyan tmux sessions in iTerm2.
#
# Escape hatch for when the Banyan app is hung or broken: every Banyan
# session is a plain tmux session on the `-L banyan` socket, so this script
# talks to tmux directly (never the Banyan control server) and lays the
# sessions out in iTerm2 — one tab per project, one pane per session.
#
# Terminal content stays in sync with Banyan automatically: iTerm2 and the
# Banyan app are just two tmux clients attached to the same sessions.
# Closing a pane (or the whole window) only detaches; nothing is killed.
#
# Usage:
#   scripts/iterm-rescue.sh [options]
#
# Options:
#   -n, --dry-run          Print the tab/pane plan without touching iTerm2
#   -p, --project <pat>    Only projects whose name contains <pat> (case-insensitive)
#   -d, --detach-others    Attach with `tmux attach -d` (kicks other clients,
#                          including a wedged Banyan app's client)
#   -L, --socket <name>    tmux socket name (default: banyan)
#   -h, --help             Show this help

set -euo pipefail

SOCKET="banyan"
DRY_RUN=0
DETACH=0
FILTER=""
STATE_DB="$HOME/Library/Application Support/Banyan/state.sqlite"

die() { echo "error: $*" >&2; exit 1; }

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        -d|--detach-others) DETACH=1 ;;
        -p|--project) [[ $# -ge 2 ]] || die "--project needs a value"; FILTER="$2"; shift ;;
        -L|--socket) [[ $# -ge 2 ]] || die "--socket needs a value"; SOCKET="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
    shift
done

command -v tmux >/dev/null 2>&1 || die "tmux not found"
[[ "$(uname)" == "Darwin" ]] || die "macOS only (drives iTerm2 via AppleScript)"

session_names=$(tmux -L "$SOCKET" list-sessions -F '#{session_name}' 2>/dev/null) \
    || die "no tmux server on socket '$SOCKET' — no live Banyan sessions to attach"

lower() { tr '[:upper:]' '[:lower:]'; }

# Optional: map tmux session name -> Banyan display title from state.sqlite.
# Read-only and best-effort; the tool must keep working if the DB is
# unreadable, locked, or from a newer schema.
TITLE_MAP=$(mktemp -t banyan-rescue-titles)
trap 'rm -f "$TITLE_MAP"' EXIT
if command -v sqlite3 >/dev/null 2>&1 && [[ -r "$STATE_DB" ]]; then
    sqlite3 -readonly -cmd '.timeout 300' -separator '	' "$STATE_DB" \
        "SELECT tmux_session_name,
                COALESCE(NULLIF(TRIM(generated_title), ''),
                         NULLIF(TRIM(reported_title), ''),
                         NULLIF(TRIM(title), ''), id)
         FROM sessions WHERE tmux_session_name IS NOT NULL;" \
        2>/dev/null | tr -d '\r' > "$TITLE_MAP" || true
fi

title_for() {
    awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$TITLE_MAP"
}

# Same grouping Banyan's sidebar uses: git worktrees fold into their main
# repository (git-common-dir), non-git directories group by their own path.
project_for() {
    local cwd="$1" common
    if common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
        basename "$(dirname "$common")"
    elif [[ "$cwd" == "$HOME" ]]; then
        echo "home"
    else
        basename "$cwd"
    fi
}

# Collect "project<TAB>session<TAB>cwd<TAB>title" records, sorted by project.
RECORDS=$(mktemp -t banyan-rescue-plan)
trap 'rm -f "$TITLE_MAP" "$RECORDS"' EXIT
while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    cwd=$(tmux -L "$SOCKET" list-panes -t "=$name" -F '#{pane_current_path}' 2>/dev/null | head -1)
    [[ -n "$cwd" ]] || cwd="$HOME"
    project=$(project_for "$cwd")
    if [[ -n "$FILTER" ]] && [[ "$(echo "$project" | lower)" != *"$(echo "$FILTER" | lower)"* ]]; then
        continue
    fi
    title=$(title_for "$name")
    [[ -n "$title" ]] || title="$name"
    printf '%s\t%s\t%s\t%s\n' "$project" "$name" "$cwd" "$title" >> "$RECORDS"
done <<< "$session_names"

[[ -s "$RECORDS" ]] || die "no sessions matched${FILTER:+ project filter '$FILTER'}"
sort -t '	' -k1,1 -s -o "$RECORDS" "$RECORDS"

PROJECTS=$(cut -f1 "$RECORDS" | uniq)

if [[ "$DRY_RUN" == 1 ]]; then
    echo "Plan (socket '$SOCKET'): one iTerm2 tab per project, one pane per session"
    while IFS= read -r project; do
        echo
        echo "tab: $project"
        awk -F '\t' -v p="$project" '$1 == p { printf "  pane: %-28s %s  (%s)\n", $2, $4, $3 }' "$RECORDS"
    done <<< "$PROJECTS"
    exit 0
fi

# Lays out one tab: argv = tabMode, numCols, <numCols column heights>, <pane commands>.
# Panes are created column-major, chaining each split off the newest pane so
# the visual order matches the command order.
APPLESCRIPT='
on run argv
    set tabMode to item 1 of argv
    set numCols to (item 2 of argv) as integer
    set colCounts to {}
    repeat with i from 3 to (2 + numCols)
        set end of colCounts to ((item i of argv) as integer)
    end repeat
    set cmds to {}
    repeat with i from (3 + numCols) to (count of argv)
        set end of cmds to (item i of argv)
    end repeat

    tell application "iTerm"
        activate
        if tabMode is "window" or (count of windows) is 0 then
            set theWindow to (create window with default profile)
            delay 0.3
            set theTab to current tab of theWindow
        else
            tell current window
                set theTab to (create tab with default profile)
            end tell
            delay 0.3
        end if

        set colHeads to {}
        tell theTab
            set cur to current session
        end tell
        set end of colHeads to cur
        repeat with c from 2 to numCols
            tell cur
                set cur to (split vertically with default profile)
            end tell
            set end of colHeads to cur
            delay 0.1
        end repeat

        set allSessions to {}
        repeat with c from 1 to numCols
            set cur to item c of colHeads
            set end of allSessions to cur
            repeat with r from 2 to (item c of colCounts)
                tell cur
                    set cur to (split horizontally with default profile)
                end tell
                set end of allSessions to cur
                delay 0.1
            end repeat
        end repeat

        delay 0.2
        repeat with i from 1 to (count of cmds)
            tell (item i of allSessions)
                write text (item i of cmds)
            end tell
        end repeat
    end tell
end run
'

shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

DETACH_FLAG=""
[[ "$DETACH" == 1 ]] && DETACH_FLAG="-d "

tab_mode="window"
tab_count=0
while IFS= read -r project; do
    pane_cmds=()
    while IFS=$'\t' read -r _p name _cwd title; do
        # Set the pane title (tmux leaves it alone: status off, set-titles off),
        # then replace the shell with the tmux client so closing it detaches cleanly.
        safe_title=$(printf '%s' "$title" | tr -d '\000-\037' | cut -c1-60)
        pane_cmds+=("printf '\\033]0;%s\\007' $(shell_quote "$safe_title"); exec tmux -L $(shell_quote "$SOCKET") attach ${DETACH_FLAG}-t $(shell_quote "=$name")")
    done < <(awk -F '\t' -v p="$project" '$1 == p' "$RECORDS")

    n=${#pane_cmds[@]}
    cols=$(awk -v n="$n" 'BEGIN { c = int(sqrt(n)); if (c * c < n) c++; print c }')
    col_counts=()
    base=$((n / cols)); extra=$((n % cols))
    for ((c = 0; c < cols; c++)); do
        col_counts+=($((base + (c < extra ? 1 : 0))))
    done

    echo "tab '$project': $n session(s), $cols column(s)"
    osascript -e "$APPLESCRIPT" "$tab_mode" "$cols" "${col_counts[@]}" "${pane_cmds[@]}"
    tab_mode="tab"
    tab_count=$((tab_count + 1))
done <<< "$PROJECTS"

echo
echo "Attached $(wc -l < "$RECORDS" | tr -d ' ') session(s) across $tab_count tab(s)."
echo "Panes are extra tmux clients — closing them detaches; Banyan sessions keep running."
