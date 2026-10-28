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
    BuildSucceeded,
    BuildFailed,
    ChildProcessExited,
    ShutdownRequested,
}

gc struct SupervisorEvent {
    kind: SupervisorEventKind,
    paths: [str],
    exit_code: int,
    err_msg: str
}

enum ActionKind {
    None,
    StartDebounceTimer,
    TriggerBuild,
    StopChild,
    StartChild,
    CleanAndExit,
}

gc struct SupervisorAction {
    kind: ActionKind,
    target_pid: int,
    log_msg: str
}

gc struct Supervisor {
    state: SupervisorState,
    entry: str,
    bin_path: str,
    staging_bin_path: str,
    running_pid: int,
    pending_paths: [str],
    rebuild_needed_while_building: bool,
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
        rebuild_needed_while_building: false,
        has_previous_run: false,
        verbose: verbose
    };
}

fn supervisor_step(s: Supervisor, ev: SupervisorEvent) -> SupervisorAction {
    if ev.kind == SupervisorEventKind.ShutdownRequested {
        let pid = s.running_pid;
        s.running_pid = 0;
        return SupervisorAction {
            kind: ActionKind.CleanAndExit,
            target_pid: pid,
            log_msg: "[zokor] shutting down watcher..."
        };
    }

    if s.state == SupervisorState.Idle {
        if ev.kind == SupervisorEventKind.FilesChanged {
            let relevant = filter_relevant_changes(ev.paths);
            if len(relevant) == 0 {
                return SupervisorAction { kind: ActionKind.None, target_pid: 0, log_msg: "" };
            }
            for p in relevant {
                push(s.pending_paths, p);
            }
            s.state = SupervisorState.Debouncing;
            return SupervisorAction {
                kind: ActionKind.StartDebounceTimer,
                target_pid: 0,
                log_msg: "[zokor] changes detected, debouncing..."
            };
        }
        if ev.kind == SupervisorEventKind.ChildProcessExited {
            s.running_pid = 0;
            if ev.exit_code != 0 {
                return SupervisorAction {
                    kind: ActionKind.None,
                    target_pid: 0,
                    log_msg: "[zokor] application crashed (exit code " + to_str(ev.exit_code) + "). Waiting for file changes..."
                };
            }
            return SupervisorAction {
                kind: ActionKind.None,
                target_pid: 0,
                log_msg: "[zokor] application exited with code 0. Waiting for file changes..."
            };
        }
    }

    if s.state == SupervisorState.Debouncing {
        if ev.kind == SupervisorEventKind.FilesChanged {
            let relevant = filter_relevant_changes(ev.paths);
            for p in relevant {
                push(s.pending_paths, p);
            }
            return SupervisorAction { kind: ActionKind.None, target_pid: 0, log_msg: "" };
        }
        if ev.kind == SupervisorEventKind.DebounceTimerFired {
            s.state = SupervisorState.Building;
            let count = len(s.pending_paths);
            s.pending_paths = [];
            return SupervisorAction {
                kind: ActionKind.TriggerBuild,
                target_pid: 0,
                log_msg: "[zokor] rebuilding application (" + to_str(count) + " files changed)..."
            };
        }
        if ev.kind == SupervisorEventKind.ChildProcessExited {
            s.running_pid = 0;
            return SupervisorAction { kind: ActionKind.None, target_pid: 0, log_msg: "" };
        }
    }

    if s.state == SupervisorState.Building {
        if ev.kind == SupervisorEventKind.FilesChanged {
            let relevant = filter_relevant_changes(ev.paths);
            if len(relevant) > 0 {
                s.rebuild_needed_while_building = true;
                for p in relevant {
                    push(s.pending_paths, p);
                }
            }
            return SupervisorAction { kind: ActionKind.None, target_pid: 0, log_msg: "" };
        }
        if ev.kind == SupervisorEventKind.BuildFailed {
            if s.rebuild_needed_while_building {
                s.rebuild_needed_while_building = false;
                s.state = SupervisorState.Debouncing;
                return SupervisorAction {
                    kind: ActionKind.StartDebounceTimer,
                    target_pid: 0,
                    log_msg: "[zokor] build error occurred, but newer changes pending. Retrying..."
                };
            }
            s.state = SupervisorState.Idle;
            if s.running_pid > 0 {
                return SupervisorAction {
                    kind: ActionKind.None,
                    target_pid: 0,
                    log_msg: "[zokor] build failed. Keeping previous server running."
                };
            }
            return SupervisorAction {
                kind: ActionKind.None,
                target_pid: 0,
                log_msg: "[zokor] build failed. Waiting for fixes..."
            };
        }
        if ev.kind == SupervisorEventKind.BuildSucceeded {
            if s.running_pid > 0 {
                s.state = SupervisorState.StoppingPrevious;
                return SupervisorAction {
                    kind: ActionKind.StopChild,
                    target_pid: s.running_pid,
                    log_msg: "[zokor] build succeeded. Stopping previous server..."
                };
            }
            s.state = SupervisorState.StartingNext;
            return SupervisorAction {
                kind: ActionKind.StartChild,
                target_pid: 0,
                log_msg: "[zokor] build succeeded. Starting server..."
            };
        }
        if ev.kind == SupervisorEventKind.ChildProcessExited {
            s.running_pid = 0;
            return SupervisorAction { kind: ActionKind.None, target_pid: 0, log_msg: "" };
        }
    }

    if s.state == SupervisorState.StoppingPrevious {
        if ev.kind == SupervisorEventKind.ChildProcessExited {
            s.running_pid = 0;
            s.state = SupervisorState.StartingNext;
            return SupervisorAction {
                kind: ActionKind.StartChild,
                target_pid: 0,
                log_msg: "[zokor] previous server stopped. Starting new server..."
            };
        }
        if ev.kind == SupervisorEventKind.FilesChanged {
            let relevant = filter_relevant_changes(ev.paths);
            if len(relevant) > 0 {
                s.rebuild_needed_while_building = true;
                for p in relevant {
                    push(s.pending_paths, p);
                }
            }
            return SupervisorAction { kind: ActionKind.None, target_pid: 0, log_msg: "" };
        }
    }

    if s.state == SupervisorState.StartingNext {
        if ev.kind == SupervisorEventKind.ChildProcessExited {
            s.running_pid = 0;
            return SupervisorAction { kind: ActionKind.None, target_pid: 0, log_msg: "" };
        }
    }

    return SupervisorAction { kind: ActionKind.None, target_pid: 0, log_msg: "" };
}
