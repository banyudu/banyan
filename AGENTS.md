# Banyan Agent Instructions

Guidance for coding agents (and human contributors) working in this repository.

- Delivery workflow: when asked to ship a change, review the scoped diff, commit,
  push the current branch, rebuild/package the app (`scripts/package-app.sh`),
  restart the requested Banyan channel (`scripts/restart-app.sh`), and verify that
  the app's control server comes back up. Report the commit, push, build, restart,
  and verification results, including any pre-existing test failures or build
  warnings.

- Prefer native SwiftUI controls, toolbar items, window styling, and layout APIs for the macOS app. Avoid custom AppKit titlebar/accessory replacements unless there is no native SwiftUI path and the tradeoff is explicitly accepted.
- Prefer async, event-driven app logic for UI and runtime state. Avoid polling loops and repeating timers for state that can come from delegate callbacks, notifications, filesystem/process events, async sequences, or SwiftUI/Observation updates; if polling is unavoidable, document why and keep the interval adaptive to foreground/background, battery, and session count.
- When spawning child terminals or coding-agent sessions while working on Banyan, use Banyan-native commands such as `banyanctl session new` or `banyanctl agent run` rather than external terminal-automation helpers, unless the user explicitly asks for an external workflow.
- When investigating performance or "CWV-like" issues, read Banyan's local performance telemetry before guessing. Use `banyanctl perf report --since 7d` or `banyanctl perf report --since 7d --json`; the events are stored in `~/Library/Application Support/Banyan/state.sqlite` under `performance_events`. Key metrics include `session_switch.total`, `session_switch.to_terminal_ready`, `session_switch.to_first_output`, `terminal.ready_wait`, `terminal.start_client`, `terminal.reattach_client`, `tmux.refresh_clients`, and `selected_context.resolve`. Use `banyanctl perf prompt` to prepare an evidence-backed fix prompt, or `banyanctl perf fix` to spawn a Banyan-native agent session for targeted performance work.
