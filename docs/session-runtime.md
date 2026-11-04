# Session runtime

Why a chat keeps working after you close it, and what happens when the process dies.

## The problem

The agent run used to live in `ChatViewModel`, which lived in `@State` inside `ChatView`.
Two consequences, both wrong:

- `onDisappear` cancelled the run, so going back to the session list killed the turn.
- Re-opening the conversation built a second `AgentSession` against the same folder, so a run
  that somehow survived had two writers and no visible progress.

## Ownership

```
AppEnvironment (process lifetime)
 └─ AgentRunRegistry            @MainActor @Observable
     └─ SessionRuntime          one per (project folder, session id)
         AgentSession · ModelClientRouter · FileWorkspace
         bubbles · cacheStats · plan · isRunning · status · pending approvals
ChatView → ChatViewModel        screen only: composer draft, attachments, open sheets
```

`ChatViewModel` forwards to the runtime; `ChatView` never owns a run. `attach()` / `detach()`
track who is watching, so the registry can tell an abandoned runtime from a visible one.

- Leaving the screen detaches and writes a checkpoint. It does **not** cancel.
- `stop()` is the only cancellation path, and it is the Stop button.
- The registry hands the same runtime to every `ChatView` for a session, so re-entering shows
  the live transcript (streamed text, tool rows, plan bar) instead of a stale snapshot.
- An idle, unwatched runtime is released after `AgentRunRegistry.idleTimeout` (10 minutes)
  and saved first, so the next attach restores from disk.

## Background

`scenePhase` in `PokeetApp` drives the registry: entering `.background` starts a
`beginBackgroundTask` for every running runtime, becoming active ends it, and anything else
checkpoints. That buys the ~30 s iOS grants before suspending — enough to finish a stream —
and nothing more. Pokeet does not claim to finish long work in the background: the process
will be suspended, and the run is recovered as interrupted work (below), not silently resumed.

## Checkpoints and interruption

Snapshots are written at most once per second (`scheduleCheckpoint`), plus immediately when a
turn starts and when a view detaches. A pending write is never cancelled in favour of a later
one: a busy run is exactly the one worth being able to recover.

`SessionSnapshot.runInFlight` records "the agent was mid-turn". It is written as part of the
turn start, mirrored into the session index (`SessionMetadata.runInFlight`) so the list can
flag a crash without opening every conversation, and cleared by the final save.

A cold start that finds `runInFlight == true` and no live runtime marks the runtime
`needsContinuation`:

- the session row shows `Interrupted` in orange;
- the chat shows a bar with **Continue** (sends `Continue from where you stopped.`) and
  **Dismiss** (clears the flag on disk).

`AgentSession.repairHistory()` backs this up: a run that stops mid tool round leaves an
assistant `tool_calls` turn without results, which every provider rejects on the next request.
`send` repairs the tail on any error, and restoring a session repairs old transcripts.

## Approvals while away

Review mode can park a run waiting for a human, and the human may have left. When proposals or
a network action arrive with no view attached, `SessionNotifier` posts a local notification
carrying the project folder and session id. Tapping it selects the project (`RootView` /
`SplitRootView`) and pushes the conversation (`ProjectSessionsView`). Everything is local; no
server is involved.

## What is not covered

- A suspended run does not continue on its own: iOS will not keep the process alive. The user
  resumes it with **Continue**.
- No `BGProcessingTask` yet. If long unattended runs matter, that is the next lever.
- Runtime memory is bounded by the idle sweep, not by trimming the transcript.

## Tests

- `PokeetTests/SessionRuntimeTests.swift` — detach keeps the run alive, re-attach shows the
  same transcript, the index flag is set and cleared, interrupted headers offer Continue.
- `Packages/PokeetCore/Tests/PokeetCoreTests/AgentHistoryRepairTests.swift` — dangling tool
  calls get answered, real answers are kept, a completed turn is untouched.
