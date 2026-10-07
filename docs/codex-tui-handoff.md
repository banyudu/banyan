# Existing Codex CLI → ChatGPT Remote handoff

An interactive Codex CLI can retain its thread's writer after a completed turn.
Detaching Banyan's terminal display or a tmux client does not exit that CLI.
Changing the launch preference only affects new sessions.

Select the existing Codex terminal in Banyan and use its **Codex CLI ownership**
panel:

1. Finish the turn and answer pending approvals/questions. Save any composer draft.
2. Click **Prepare Remote Handoff**. Wait for **Completed turn — ready to exit CLI**.
3. In that same CLI, type `/quit` and press Enter. This is an explicit user action;
   Banyan never injects the command, sends termination signals, or cancels a turn.
4. Click **Check CLI Exit**. **Last check: CLI exited** is a dated observation,
   not a continuously monitored ownership claim. Recheck after terminal activity.
5. Reopen the same thread in ChatGPT Remote. Keep the recorded thread ID for comparison.
   Avoid restarting the CLI while Remote is using that thread.

The equivalent authenticated control commands are:

```sh
banyanctl codex-handoff --id SESSION_ID
# Enter /quit in that session's CLI after preparation succeeds.
banyanctl codex-handoff --id SESSION_ID --detail check
```

Preparation binds the selected thread to the live CLI's open rollout, verifies
its `session_meta` ID and cwd, checks for a completed turn, and refuses visible
running/pending input. It records kernel start identities for both the pane root
and the CLI, sets and verifies pane-local `remain-on-exit`, then saves a receipt
on that pane. This retains even an older one-shot pane when its final command
exits. The receipt can be checked after Banyan restarts; it does not require a
shell to survive. The rollout and worktree are never modified or deleted.

Confirmation requires the same pane and process identities. An unavailable or
incomplete process inspection, a reused PID, a changed active thread, or a new
CLI requires a new preparation. A surviving host/shell is inspected as a complete
process tree; an empty process table never establishes exit. Existing permission
settings, launch command, storage location, and `--no-daemon` intent are preserved.

If preparation fails, keep the CLI open, finish pending work, refresh history or
correct its storage configuration, and retry. Do not quit a one-shot pane until
preservation succeeds. If the CLI remains open, the check reports that state;
it never escalates to killing it. Missing history/worktree or changed pane
identity is a recovery error, and never starts a replacement thread. A daemon
or another client may still own the thread after this CLI exits: use that
client's supported lifecycle and retry Remote. Native Banyan writer conflicts
also link this guided sequence in their recovery message.

## Design

The root cause is competing writer ownership, not the worktree. Automatic
`/quit` injection could race a new turn or overwrite composer text; legacy CLIs
have no atomic external idle-and-exit RPC. The supported explicit-user flow
therefore arms preservation before the normal CLI exit and verifies it after.
Using `thread/unsubscribe` on a separate stdio server cannot release an unrelated
TUI writer, and unsubscribe itself may retain a loaded thread during a grace period.

Official semantics: [CLI exit commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli)
and [App Server subscription lifecycle](https://learn.chatgpt.com/docs/app-server).

## Automated and live verification

```sh
swift test --filter 'codexTUIHandoff|codexHandoffControl'
python3 scripts/verify-codex-integration.py --tui-handoff
```

The installed-Codex harness reuses the private loopback Responses provider. It
runs an exact-ID interactive resume with `--no-daemon` in a unique disposable
tmux server, refuses a real running turn and pending question, attempts a
pre-exit resume and records the real server response, preserves the one-shot
pane, performs the user's
`/quit`, and resumes the same persisted thread through a real local App Server.
It checks thread ID, completed messages, pane, rollout, and worktree retention.
Unit fixtures additionally cover pending requests, queued turns, incomplete
transcripts, mismatched live threads, unavailable inspection, PID reuse, and
preservation failure recovery. No user/worker agent or live tmux server is touched.

A successful local stdio resume does **not** prove Desktop or phone behavior.
Some versions may permit that local resume even before CLI exit. The harness
retains `legacy-before-resume.json` and `legacy-after-resume.json` so the actual
result is distinguishable from a simulated active-writer error.

The supervisor should collect the remaining live evidence with the user:

1. In the review build, select an existing Banyan CLI thread that previously
   failed mobile reconnect. Record its thread ID and last completed reply.
2. While the CLI remains open, try that exact task in ChatGPT mobile Remote.
   Record the result and, if it fails, the Desktop server error and timestamp.
3. Follow preparation → `/quit` → exit check above. Verify the pane remains,
   the worktree files remain, and the thread ID has not changed.
4. Refresh/reopen that same task on the phone through its connected Desktop.
   Verify messages include the recorded completed reply and reconnect succeeds.
5. Record phone/desktop versions, timestamps, and success/failure in the review
   evidence. If desired, send a phone follow-up and verify it belongs to the same
   thread. Do not restart the TUI concurrently.

Until step 4 is observed on a phone, mobile acceptance remains unverified.
