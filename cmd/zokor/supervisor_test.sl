fn test_supervisor_lifecycle_normal() {
    let s = make_supervisor("src/main.sl", ".zokor/watch/app", ".zokor/watch/app.next", false);
    assert(s.state == SupervisorState.Idle);

    // File change triggers debounce
    let a1 = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.FilesChanged,
        paths: ["src/main.sl"],
        exit_code: 0,
        err_msg: "",
        build: s.build_seq,
        pid: 0
    });
    assert(s.state == SupervisorState.Debouncing);
    assert(a1.kind == ActionKind.StartDebounceTimer);

    // Debounce timer fires -> triggers build
    let a2 = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.DebounceTimerFired,
        paths: [],
        exit_code: 0,
        err_msg: "",
        build: s.build_seq,
        pid: 0
    });
    assert(s.state == SupervisorState.Building);
    assert(a2.kind == ActionKind.TriggerBuild);

    // Initial build succeeds -> starts child (no previous child)
    let a3 = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.BuildSucceeded,
        paths: [],
        exit_code: 0,
        err_msg: "",
        build: s.build_seq,
        pid: 0
    });
    assert(s.state == SupervisorState.StartingNext);
    assert(a3.kind == ActionKind.StartChild);

    // Simulate child started with pid 100
    s.running_pid = 100;
    s.state = SupervisorState.Idle;

    // Second change while app is running
    let a4 = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.FilesChanged,
        paths: ["src/feature/service.sl"],
        exit_code: 0,
        err_msg: "",
        build: s.build_seq,
        pid: 0
    });
    assert(s.state == SupervisorState.Debouncing);
    assert(a4.kind == ActionKind.StartDebounceTimer);

    let a5 = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.DebounceTimerFired,
        paths: [],
        exit_code: 0,
        err_msg: "",
        build: s.build_seq,
        pid: 0
    });
    assert(s.state == SupervisorState.Building);
    assert(a5.kind == ActionKind.TriggerBuild);

    // Build succeeds while pid 100 is still running -> stops previous child first!
    let a6 = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.BuildSucceeded,
        paths: [],
        exit_code: 0,
        err_msg: "",
        build: s.build_seq,
        pid: 0
    });
    assert(s.state == SupervisorState.StoppingPrevious);
    assert(a6.kind == ActionKind.StopChild);
    assert(a6.target_pid == 100);

    // Previous child exits -> starts next server
    let a7 = supervisor_step(s, ev_exit(100, 0));
    assert(s.state == SupervisorState.StartingNext);
    assert(a7.kind == ActionKind.StartChild);
}

fn test_supervisor_build_failure_keeps_running_app() {
    let s = make_supervisor("src/main.sl", ".zokor/watch/app", ".zokor/watch/app.next", false);
    s.running_pid = 200;
    s.state = SupervisorState.Building;

    let a = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.BuildFailed,
        paths: [],
        exit_code: 1,
        err_msg: "syntax error",
        build: s.build_seq,
        pid: 0
    });
    assert(s.state == SupervisorState.Idle);
    assert(a.kind == ActionKind.None);
    assert(s.running_pid == 200); // previous server stays up!
}

fn test_supervisor_child_crash_no_hot_restart() {
    let s = make_supervisor("src/main.sl", ".zokor/watch/app", ".zokor/watch/app.next", false);
    s.running_pid = 300;
    s.state = SupervisorState.Idle;

    let a = supervisor_step(s, ev_exit(300, 1));
    assert(s.state == SupervisorState.Idle);
    assert(a.kind == ActionKind.None);
    assert(s.running_pid == 0); // does not auto-restart in hot loop!
}

fn test_supervisor_shutdown() {
    let s = make_supervisor("src/main.sl", ".zokor/watch/app", ".zokor/watch/app.next", false);
    s.running_pid = 400;

    let a = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.ShutdownRequested,
        paths: [],
        exit_code: 0,
        err_msg: "",
        build: s.build_seq,
        pid: 0
    });
    assert(a.kind == ActionKind.CleanAndExit);
    assert(a.target_pid == 400);
}

// One event of `kind` about `paths`; the fields every event carries but these
// tests do not look at are zero.
fn ev(kind: SupervisorEventKind, paths: [str]) -> SupervisorEvent {
    return SupervisorEvent { kind: kind, paths: paths, exit_code: 0, err_msg: "", build: 0, pid: 0 };
}

// Process `pid` exited with `code`.
fn ev_exit(pid: int, code: int) -> SupervisorEvent {
    let nopaths: [str] = [];
    return SupervisorEvent { kind: SupervisorEventKind.ChildProcessExited, paths: nopaths, exit_code: code, err_msg: "", build: 0, pid: pid };
}

// A result of build number `build`.
fn ev_build(kind: SupervisorEventKind, build: int) -> SupervisorEvent {
    let nopaths: [str] = [];
    return SupervisorEvent { kind: kind, paths: nopaths, exit_code: 0, err_msg: "", build: build, pid: 0 };
}

// A save during a build must not end with the build that started before it
// being run: that binary does not have the change.
fn test_supervisor_change_during_build_never_runs_the_stale_build() {
    let s = make_supervisor("src/main.sl", ".zokor/watch/app", ".zokor/watch/app.next", false);
    let nopaths: [str] = [];
    supervisor_step(s, ev(SupervisorEventKind.FilesChanged, ["src/a.sl"]));
    supervisor_step(s, ev(SupervisorEventKind.DebounceTimerFired, nopaths));
    assert(s.state == SupervisorState.Building);

    supervisor_step(s, ev(SupervisorEventKind.FilesChanged, ["src/b.sl"]));
    let a = supervisor_step(s, ev_build(SupervisorEventKind.BuildSucceeded, 1));
    assert(a.kind != ActionKind.StartChild, "started the build made before src/b.sl changed");
    assert(a.kind != ActionKind.StopChild, "stopped the server for a stale build");
}

// A save while the previous server is being stopped must still be built once
// the new server is up, without waiting for another save.
fn test_supervisor_change_while_restarting_is_built_next() {
    let s = make_supervisor("src/main.sl", ".zokor/watch/app", ".zokor/watch/app.next", false);
    let nopaths: [str] = [];
    s.running_pid = 100;
    supervisor_step(s, ev(SupervisorEventKind.FilesChanged, ["src/a.sl"]));
    supervisor_step(s, ev(SupervisorEventKind.DebounceTimerFired, nopaths));
    supervisor_step(s, ev_build(SupervisorEventKind.BuildSucceeded, s.build_seq));
    assert(s.state == SupervisorState.StoppingPrevious);

    supervisor_step(s, ev(SupervisorEventKind.FilesChanged, ["src/b.sl"]));
    let start = supervisor_step(s, ev_exit(100, 0));
    assert(start.kind == ActionKind.StartChild);
    let next = supervisor_child_started(s, 101);
    assert(s.running_pid == 101);
    assert(next.kind == ActionKind.StartDebounceTimer, "src/b.sl was never rebuilt");
    assert(s.state == SupervisorState.Debouncing);
}

// The server stopped for a rebuild reports its exit late, after its
// successor is up. That exit must not make the watcher forget the new
// server: shutdown would then leave it running, orphaned.
fn test_supervisor_ignores_the_previous_servers_late_exit() {
    let s = make_supervisor("src/main.sl", ".zokor/watch/app", ".zokor/watch/app.next", false);
    let _st = supervisor_child_started(s, 101);
    let a = supervisor_step(s, ev_exit(100, 143));
    assert(a.kind == ActionKind.None);
    assert(s.running_pid == 101, "forgot the running server");
    let down = supervisor_step(s, ev(SupervisorEventKind.ShutdownRequested, ["x"]));
    assert(down.kind == ActionKind.CleanAndExit);
    assert(down.target_pid == 101, "shutdown would leave the server running");
}

// Only the running server's own exit is a crash.
fn test_supervisor_reports_the_running_servers_crash() {
    let s = make_supervisor("src/main.sl", ".zokor/watch/app", ".zokor/watch/app.next", false);
    let _st = supervisor_child_started(s, 7);
    let a = supervisor_step(s, ev_exit(7, 2));
    assert(s.running_pid == 0);
    assert(a.log_msg == "[zokor] application crashed (exit code 2). Waiting for file changes...");
}
