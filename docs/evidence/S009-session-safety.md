# S009 safe session close and restart

Date: 2026-10-16. Implemented and independently reviewed; native close/restart decisions verified.

## Behavior

Closing a running pane, tab, managed window, native window, or application presents one affected-session summary. Cancel leaves the hierarchy and processes unchanged. Authorized closure sends graceful termination, waits up to two seconds, and offers a separate Force Stop decision. There is no automatic escalation to SIGKILL.

The engine-independent closure coordinator uses an injectable monotonic clock and returns `CONFIRMATION_REQUIRED` without running-session authorization, `CLOSE_PENDING` after the grace interval, or success after cleanup. Force requires an explicit subsequent request. These are reusable lifecycle policy results; the authenticated socket/API transport is implemented in later stories.

Process-group signaling validates the owned child's parent, group, PID, and kernel start time against the launch identity. The transport remains the sole reaper and descriptor owner. Detached or remote processes are not reported as terminated.

Exited output and its exit code remain visible. Restart replaces only the session with a fresh UUID and native terminal buffer, preserving the pane, tab, layout, and launch configuration.

## Verification

Final full suite: **98 tests passed, zero failures**. New tests cover no signals on cancellation, a fake-clock grace timeout without implicit force, explicit force authorization, reused-PID rejection at both policy and real transport boundaries, fresh-session restart, old output retained until explicit replacement, and a real TERM-ignoring child surviving a declined force prompt.

Review serialized close actions, included committed in-flight panes before computing summaries, gated restart against concurrent closure, and preserved committed native view materialization through canceled quit. It separated process liveness from post-reap output draining, verified waitpid ownership before deinitialization signals, and retired per-session closure authorization after exit. Two additional regressions cover post-reap drain without force signals and canceled quit preserving the existing session.

Native checks confirmed exit code 7 remains visible with retained output, Restart replaces that buffer in the same pane, Cancel keeps a controlled session running and usable, and Keep Waiting preserves a TERM-ignoring session in Closing state after the grace interval. Initial dialog automation was interrupted by app-state changes; the Cancel and Keep Waiting paths were repeated and observed successfully. A fresh controlled TERM-ignoring session then passed the full native sequence: accepted Close, observed the separate force prompt after the grace interval, explicitly selected Force Stop, and reached the empty welcome state. The development bundle built without warnings and its ad-hoc signature verified. Controlled SSH close testing remains pending the SSH integration stories, as do prior physical platform qualification checks.
