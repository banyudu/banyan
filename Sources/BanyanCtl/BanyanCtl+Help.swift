import BanyanCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension BanyanCtl {
    func printHelp() {
        print("""
        banyanctl controls a running Banyan app on localhost:7842.

        Puck sessions use the local puckd socket and work while Banyan is closed:
          banyanctl puck list
          banyanctl puck new [--id ID] [--engine codex|native] [--provider codex|opencode-go|anthropic|gemini] [--account LABEL] [--model MODEL] [--cwd PATH] [--prompt TEXT]
          banyanctl puck attach --id ID
          banyanctl puck plan --id ID
          banyanctl puck reject --id ID --call-id CALL_ID --reason REASON
          banyanctl puck show --id ID
          banyanctl puck turn --id ID --prompt TEXT
          banyanctl puck decide --id ID --call-id CALL --decision approve|deny|session
          banyanctl puck answer --id ID --call-id CALL --selections JSON

        Usage:
          banyanctl coordination bind|status|release --id OWNER --group-id GROUP
          banyanctl coordination helper|retire-helper --id HELPER --parent OWNER --group-id GROUP --worker CHILD --run-id RUN --job-id JOB [--revision N]
          banyanctl coordination observe --id CHILD --parent OWNER --group-id GROUP
          banyanctl coordination inspect-recovery --id CHILD --parent OWNER --group-id GROUP
          banyanctl coordination recover --id CHILD --parent OWNER --group-id GROUP --inspection-id ID --detail TEXT
          banyanctl coordination deliver --id OWNER --group-id GROUP --revision N --wake-id ID --text TEXT
          banyanctl coordination resolve --id OWNER --group-id GROUP --revision N --wake-id ID --outcome delivered|not-delivered --detail TEXT
          banyanctl coordination retire --id CHILD --parent OWNER --group-id GROUP --job-id JOB --revision N [--intervention-id ID]
          banyanctl workflow set --id ID --owner workit --job-id JOB --revision N --state working|waiting|needs-you|verified|paused|cancelled [--detail TEXT]
          banyanctl workflow wake --id ID --job-id JOB --revision N --wake-id WAKE --text TEXT
          banyanctl workflow resolve --id ID --job-id JOB --revision N --wake-id WAKE --outcome delivered|not-delivered --detail TEXT
          banyanctl workflow close-verified
          banyanctl codex-remote configure --path policy.json
          banyanctl codex-remote resolve --workspace ID --operationID ID [--kind native|terminalFollowup]
          banyanctl codex-handoff --id ID [--detail prepare|check]
          banyanctl session current
          banyanctl session list [--all] [--id ID] [--query TEXT]
          banyanctl spawn  [--id ID] [--title TITLE] [--title-url URL] [--cwd PATH] [--command CMD] [--cmd CMD] [--parent ID] [--no-parent] [--tone blue] [--focus|--background]
          banyanctl session new [--id ID] [--title TITLE] [--title-url URL] [--cwd PATH] [--command CMD] [--cmd CMD] [--parent ID] [--no-parent] [--tone blue] [--focus|--background]
          banyanctl session title --title TEXT [--id ID]  (automatic title; preserves manual renames)
          banyanctl agent queue [status | cancel ID | prioritize ID | retry ID | limit N]
          banyanctl agent run (--agent codex|claude|deepseek|gemini|glm|hunyuan|mimo|minimax|muse|opencode | --profile ID) [--id ID] [--title TITLE] [--title-url URL] [--cwd PATH] [--parent ID] [--no-parent] [--prompt TEXT] [--prompt-file PATH] [--focus|--background] [prompt...]

        Spawns open in the background by default (they do not steal focus from the
        current session). Pass --focus to select the new session, or --background
        to force background even when nothing is currently selected.

        A spawn issued from inside a Banyan session nests under it by default:
        --parent comes from $BANYAN_PARENT_SESSION_ID, then the enclosing tmux
        session, then $BANYAN_SESSION_ID. Pass --parent ID to pick a different
        parent, or --no-parent for a top-level session.
          banyanctl mark   --id ID [--status running|executing|long-running-shell|subagents|need-input|asking|review|completed|failed] [--tone red] [--title TITLE] [--title-url URL]
          banyanctl select --id ID
          banyanctl reparent --id ID (--parent PARENT_ID | --no-parent)
          banyanctl tick   [--id ID]
          banyanctl suspend --id ID
          banyanctl resume  --id ID
          banyanctl session freeze --id ID
          banyanctl session unfreeze --id ID
          banyanctl session suspend ID
          banyanctl session resume ID
          banyanctl close  --id ID
          banyanctl respawn --id ID
          banyanctl restart --id ID
          banyanctl remove --id ID
          banyanctl screenshot --output PATH
          banyanctl prune  [--older-than DAYS] [--dry-run]
          banyanctl perf report [--since 7d] [--json]
          banyanctl perf captures [--since 7d] [--json]
          banyanctl perf energy [--seconds 10] [--json]
          banyanctl perf prompt [--since 7d]
          banyanctl perf fix [--since 7d] [--agent codex|claude] [--cwd PATH]
          banyanctl window-state
          banyanctl list [--all] [--id ID] [--query TEXT]

        Lists return active sessions with details by default, including parked,
        completed and failed rows that remain open. --all includes closed history.
        --id reads one exact session, including closed history. --query searches
        IDs, titles, issue URLs and working directories without regard to case;
        combine it with --all to search history. HTTP clients use GET /list with
        all=true, id=ID and query=TEXT parameters.

        reparent moves an existing session and its children within one project
        sidebar group. --no-parent moves it to the root. It preserves the session,
        process, metadata and manual order. HTTP: POST /reparent with id and parent;
        an empty or absent parent moves to root. The CLI requires an explicit target
        and never inherits a parent from the environment.

        suspend parks a session: Banyan stops supervising and rendering it, while
        its tmux session and any agent inside keep running. resume is lossless and
        keeps the status the session had when it was parked. Neither one signals or
        terminates the agent. `session suspend ID` instead deep-suspends a verified
        idle agent with agent-only SIGTERM; `session resume ID` restores its exact
        disk session inside the surviving pane. --id ID is also accepted.
        Focus resumes deep-suspended agents. Per-provider automatic policies are
        off by default. See docs/agent-deep-suspend.md for owned launch requirements.
        freeze sends SIGSTOP to verified idle agent process groups; unfreeze sends
        SIGCONT. Select another session and detach external tmux clients first.
        Interaction resumes frozen agents. Automatic freezing is off by default;
        enable it and set the idle threshold in Preferences. See docs/agent-freeze.md.

        `prune` drops closed sessions that aged out of the retention window set
        in Preferences (default 30 days), which Banyan also applies at launch.
        --older-than overrides the window for this run without changing the
        setting, and --dry-run reports how many rows would go without touching
        any. A session is only ever removed when it is closed, older than the
        window, not selected, and not the parent of a session that stays.

        Suggesting work instead of starting it:
          banyanctl suggest --title TEXT --command CMD [--detail TEXT] [--target ID] [--key KEY] [--cwd PATH] [--run session|background] [--ttl SECONDS]

        `suggest` pushes a proposal into the app's sidebar and returns. Nothing
        runs until the human presses Run; Dismiss drops it. The command and
        --target are opaque to Banyan, so the policy behind a suggestion — which
        issue has gone stale, whose review is overdue — stays in the script that
        computes it. A suggestion is live for --ttl seconds (default 3600, min 60,
        max 86400): while it is live it holds the single pending slot, and its
        --key is refused, so a picker on a short cron cannot raise the same nudge
        twice. --key defaults to --target, then to the command. Answering frees
        the slot but keeps the key suppressed for the rest of the TTL. A refused
        suggestion exits 75 (temporary failure), not 64 — a scheduled picker
        should skip that tick and try again. With the app not running, `suggest`
        exits 69 like every other command, which is the fail-closed skip.

        Reading and answering a blocked agent:
          banyanctl output --id ID [--lines N]
          banyanctl send   --id ID [--key Enter]... [--text "…"] [--submit]
          banyanctl answer --id ID (--option N | --choice yes|no|always | --confirm) --footprint H
          banyanctl events [--since CURSOR]

        `output` prints the pane text plus, when the session is genuinely waiting
        on a human, the parsed question, its options and a `footprint`. `answer`
        requires that footprint and refuses if the pane has moved on, so a stale
        reply can never land on a newer question. `send` is the raw path: --text is
        typed verbatim and is never read as a key name. `events` holds the request
        open until a session changes status.
        """)
    }
}
