# Pause and Close

Every close action in the native close confirmation stays disabled until
Command is held. For active, non-imported sessions with an unfinished `workit`
workflow (`working`, `waiting`, or `needs-you`), the confirmation offers
**Pause and Close**. Pausing leaves the issue and acceptance unfinished, stops
future automatic continuation, and then closes the terminal. Closing can kill
the current agent. Children are promoted normally and the closed session stays
in history. Unmanaged, verified, paused and cancelled sessions use ordinary
close. Other workflow owners must resolve their own holds.

## Trusted configuration

Configure `~/.banyan/workit.json` in the home directory used by Banyan:

```json
{
  "invocation": ["/usr/local/bin/workit"],
  "stateDirectory": "/Users/example/.local/state/workit"
}
```

Use the state directory that owns the managed jobs. The invocation is an argv
array with an absolute executable path; it can include fixed arguments, such
as an absolute Node executable followed by a CLI script path. No shell parsing,
PATH discovery, session command, issue text or job-provided executable is used.
The child runs from Banyan's configured home with `WORKIT_STATE_DIR` set to the
configured directory. Banyan does not write Workit's database.

## Workit CLI dependency

The close refusal is a missing owner action: Banyan's projection cannot itself
stop Workit's scheduling. An immediate projection check would race Workit's
control request. The client plus a bounded event-driven wait supports projection
before or after the acknowledgement; retaining the receipt avoids repeating
owner mutations when only projection needs repair.

Requires a Workit version implementing the revision/session-checked pause
contract from [the companion Workit change](https://github.com/banyudu/workit/issues/10):

```text
workit job pause JOB_ID --detail TEXT --expected-revision N --expected-session-id SESSION_ID
```

The owner must validate both expected fields atomically, pause durably, preserve
acceptance/history and uncertain-wake audit information, and return its job as
JSON, including `id`, `sessionID`, `revision` and `stage`. Banyan requires the
same job/session, a newer revision, and `stage: "paused"`. Versions that only
support `--detail` are incompatible; Banyan retains the terminal and reports
an upgrade action. There is no fallback to an unguarded command.

The invocation runs asynchronously (30-second command deadline), so Workit can
project through Banyan's control server while the command is running. Banyan
then waits up to five seconds for the matching owner/job/revision/paused
projection and confirms the readable workflow journal agrees before calling
ordinary close. It never verifies, cancels, resumes, or synthesizes a pause.

## Recovery

Missing configuration/CLI, nonzero exit, invalid acknowledgement, changed
binding, and unreadable or mismatched journals retain the session with an
actionable error. A command error can occur after owner mutation; inspect the
job with the same configured invocation and state directory before retrying.

An acknowledged durable pause with missing projection is partial success:
the issue is paused, but the terminal remains open. Repair Workit's Banyan
control connection or wait for its existing projection recovery, then select
**Retry Pause and Close**. Banyan retains the acknowledged receipt for the
lifetime of the app and only checks projection on retry; it does not send a
second pause or undo the durable pause. A different/newer hold prevents close
and is never cleared by retry. After an app restart, a matching projected pause
uses ordinary close; if projection is still missing, repair it through Workit.

## Isolated validation

```sh
swift test --filter 'PauseAndCloseTests|WorkitPauseClientTests|SessionWorkflowStoreTests|closingAFinishedPlainSessionStillAsksFirst|relationshipPolicy'
```

The tests inject an owner client or fake Python executable, use private homes,
journals/databases and an ephemeral authenticated control server, and never
pause live jobs or restart the app. Live integration remains dependent on the
companion CLI implementing the atomic binding checks and owner projection.
