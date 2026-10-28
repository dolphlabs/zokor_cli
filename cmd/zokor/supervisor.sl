// Pure supervisor state machine for zokor watch mode.

enum SupervisorState {
    Idle,
    Debouncing,
    Building,
    StoppingPrevious,
    StartingNext,
}

enum SupervisorEventKind {
    FilesChanged,
    DebounceTimerFired,
    BuildStarted,
    BuildSucceeded,
    BuildFailed,
    ChildProcessExited,
    ShutdownRequested,
}

// `build` and `pid` are set on the build events only: which build (the
// number TriggerBuild gave it) and, on BuildStarted, its process.
gc struct SupervisorEvent {
    kind: SupervisorEventKind,
    paths: [str],
    exit_code: int,
    err_msg: str,
    build: int,
    pid: int
}

enum ActionKind {
    None,
    StartDebounceTimer,
    TriggerBuild,
    // Kill the build in progress (target_pid, when it has started) and
    // start the debounce timer: files changed under it.
    CancelBuild,
    // Kill target_pid, a build that reported in after it was cancelled.
    KillStaleBuild,
    StopChild,
    StartChild,
    CleanAndExit,
}

// `build` is set on TriggerBuild: the number its events must carry.
gc struct SupervisorAction {
    kind: ActionKind,
    target_pid: int,
    log_msg: str,
    build: int
}

// A build's results count only while it is still the current build:
// build_seq is bumped each time one is started or cancelled, so the events
// of a cancelled build carry an old number and are dropped. A build is
// cancelled as soon as a relevant file changes under it -- it was compiling
// sources that are already out of date -- and anything that changes while
// the server restarts is built right after.
gc struct Supervisor {
    state: SupervisorState,
    entry: str,
    bin_path: str,
    staging_bin_path: str,
    running_pid: int,
    pending_paths: [str],
    build_seq: int,
    build_pid: int,
    has_previous_run: bool,
    verbose: bool
}

fn make_supervisor(entry: str, bin_path: str, staging_path: str, verbose: bool) -> Supervisor {
    return Supervisor {
        state: SupervisorState.Idle,
        entry: entry,
        bin_path: bin_path,
        staging_bin_path: staging_path,
        running_pid: 0,
        pending_paths: [],
        build_seq: 0,
        build_pid: 0,
        has_previous_run: false,
        verbose: verbose
    };
}

fn no_action() -> SupervisorAction {
    return SupervisorAction { kind: ActionKind.None, target_pid: 0, log_msg: "", build: 0 };
}

fn action(kind: ActionKind, target_pid: int, log_msg: str) -> SupervisorAction {
    return SupervisorAction { kind: kind, target_pid: target_pid, log_msg: log_msg, build: 0 };
}

// The next build: a new number, and nothing known of its process yet.
fn trigger_build(s: Supervisor, log_msg: str) -> SupervisorAction {
    s.build_seq += 1;
    s.build_pid = 0;
    s.state = SupervisorState.Building;
    return SupervisorAction {
        kind: ActionKind.TriggerBuild, target_pid: 0, log_msg: log_msg, build: s.build_seq
    };
}

// Relevant changes join the pending set; true when there were any.
fn note_changes(s: Supervisor, paths: [str]) -> bool {
    let relevant = filter_relevant_changes(paths);
    for p in relevant {
        push(s.pending_paths, p);
    }
    return len(relevant) > 0;
}

fn is_build_result(kind: SupervisorEventKind) -> bool {
    return kind == SupervisorEventKind.BuildSucceeded || kind == SupervisorEventKind.BuildFailed;
}

fn supervisor_step(s: Supervisor, ev: SupervisorEvent) -> SupervisorAction {
    if ev.kind == SupervisorEventKind.ShutdownRequested {
        let pid = s.running_pid;
        s.running_pid = 0;
        return action(ActionKind.CleanAndExit, pid, "[zokor] shutting down watcher...");
    }

    // A build that was cancelled before it reported its process: stop it now.
    if ev.kind == SupervisorEventKind.BuildStarted {
        if ev.build == s.build_seq && s.state == SupervisorState.Building {
            s.build_pid = ev.pid;
            return no_action();
        }
        return action(ActionKind.KillStaleBuild, ev.pid, "");
    }
    // The result of a cancelled build: the sources it compiled have changed.
    if is_build_result(ev.kind) && (ev.build != s.build_seq || s.state != SupervisorState.Building) {
        return no_action();
    }

    if s.state == SupervisorState.Idle {
        if ev.kind == SupervisorEventKind.FilesChanged {
            if !note_changes(s, ev.paths) {
                return no_action();
            }
            s.state = SupervisorState.Debouncing;
            return action(ActionKind.StartDebounceTimer, 0, "[zokor] changes detected, debouncing...");
        }
        if ev.kind == SupervisorEventKind.ChildProcessExited {
            s.running_pid = 0;
            if ev.exit_code != 0 {
                return action(ActionKind.None, 0,
                    "[zokor] application crashed (exit code " + to_str(ev.exit_code) + "). Waiting for file changes...");
            }
            return action(ActionKind.None, 0, "[zokor] application exited with code 0. Waiting for file changes...");
        }
    }

    if s.state == SupervisorState.Debouncing {
        if ev.kind == SupervisorEventKind.FilesChanged {
            let _n = note_changes(s, ev.paths);
            return no_action();
        }
        if ev.kind == SupervisorEventKind.DebounceTimerFired {
            let count = len(s.pending_paths);
            s.pending_paths = [];
            return trigger_build(s, "[zokor] rebuilding application (" + to_str(count) + " files changed)...");
        }
        if ev.kind == SupervisorEventKind.ChildProcessExited {
            s.running_pid = 0;
            return no_action();
        }
    }

    if s.state == SupervisorState.Building {
        if ev.kind == SupervisorEventKind.FilesChanged {
            if !note_changes(s, ev.paths) {
                return no_action();
            }
            let pid = s.build_pid;
            s.build_seq += 1;
            s.build_pid = 0;
            s.state = SupervisorState.Debouncing;
            return action(ActionKind.CancelBuild, pid, "[zokor] files changed during the build; restarting it...");
        }
        if ev.kind == SupervisorEventKind.BuildFailed {
            s.build_pid = 0;
            s.state = SupervisorState.Idle;
            if s.running_pid > 0 {
                return action(ActionKind.None, 0, "[zokor] build failed. Keeping previous server running.");
            }
            return action(ActionKind.None, 0, "[zokor] build failed. Waiting for fixes...");
        }
        if ev.kind == SupervisorEventKind.BuildSucceeded {
            s.build_pid = 0;
            if s.running_pid > 0 {
                s.state = SupervisorState.StoppingPrevious;
                return action(ActionKind.StopChild, s.running_pid, "[zokor] build succeeded. Stopping previous server...");
            }
            s.state = SupervisorState.StartingNext;
            return action(ActionKind.StartChild, 0, "[zokor] build succeeded. Starting server...");
        }
        if ev.kind == SupervisorEventKind.ChildProcessExited {
            s.running_pid = 0;
            return no_action();
        }
    }

    if s.state == SupervisorState.StoppingPrevious {
        if ev.kind == SupervisorEventKind.ChildProcessExited {
            s.running_pid = 0;
            s.state = SupervisorState.StartingNext;
            return action(ActionKind.StartChild, 0, "[zokor] previous server stopped. Starting new server...");
        }
        if ev.kind == SupervisorEventKind.FilesChanged {
            let _n = note_changes(s, ev.paths);
            return no_action();
        }
    }

    if s.state == SupervisorState.StartingNext {
        if ev.kind == SupervisorEventKind.ChildProcessExited {
            s.running_pid = 0;
            return no_action();
        }
        if ev.kind == SupervisorEventKind.FilesChanged {
            let _n = note_changes(s, ev.paths);
            return no_action();
        }
    }

    return no_action();
}

// The run loop started the new server as `pid`: what the supervisor does
// next. Changes that came in while the server restarted are built now; they
// used to wait for the next save.
fn supervisor_child_started(s: Supervisor, pid: int) -> SupervisorAction {
    s.running_pid = pid;
    s.state = SupervisorState.Idle;
    if len(s.pending_paths) > 0 {
        s.state = SupervisorState.Debouncing;
        return action(ActionKind.StartDebounceTimer, 0,
            "[zokor] changes came in while restarting, rebuilding...");
    }
    return no_action();
}

// The run loop could not start the new server: nothing runs now.
fn supervisor_child_failed(s: Supervisor) -> SupervisorAction {
    s.running_pid = 0;
    s.state = SupervisorState.Idle;
    if len(s.pending_paths) > 0 {
        s.state = SupervisorState.Debouncing;
        return action(ActionKind.StartDebounceTimer, 0, "");
    }
    return no_action();
}
