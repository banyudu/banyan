# Banyan Agent Instructions

Guidance for coding agents (and human contributors) working in this repository.

## Project context

Project context lives in `.agents/context.md`. Read it first when you need a
project-level third-party ID or a per-environment URL — GitHub repo, Linear
project, or service IDs. It is a short fenced-YAML index, IDs/URLs only; it
never holds secrets. Schema and maintenance rules, including the self-healing
rule for stale values:
`~/.agents/references/project-context-format.md`. Org-level facts (people,
Slack channels) are not in it — those stay in the `team-context` skill.

`CLAUDE.md` is a symlink to this file, so the import below makes the context
always-loaded for Claude Code; other agents read the path above.

@.agents/context.md

## Shareable content only

This repository is shared beyond its original author. Never commit personal or
internal identifiers, in any file — sources, tests, docs, scripts, or commit
messages:

- No real issue-tracker IDs (e.g. `ENG-1234`). Use `TASK-123`-style
  placeholders in docs, examples, and test fixtures.
- No personal home paths (`/Users/<real-name>/...`) or private
  project/workspace names. Use `~/dev/my-project` in docs and
  `/Users/example/...` in test fixtures.
- No internal org slugs, tracker workspace names, or company-specific URLs.
  Org-specific values must come from configuration (environment variables or
  Preferences) with a neutral or documented default.
- Machine- or person-specific workflow assumptions (personal wrapper scripts,
  log file conventions) must be optional and detected at runtime, never
  hardcoded as required.

If a task's context contains such identifiers (a real issue ID, a local path),
generalize them before writing them into the repo.

## Engineering conventions

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
