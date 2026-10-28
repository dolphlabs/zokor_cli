fn test_supervisor_lifecycle_normal() {
    let s = make_supervisor("src/main.sl", ".zokor/watch/app", ".zokor/watch/app.next", false);
    assert(s.state == SupervisorState.Idle);

    // File change triggers debounce
    let a1 = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.FilesChanged,
        paths: ["src/main.sl"],
        exit_code: 0,
        err_msg: ""
    });
    assert(s.state == SupervisorState.Debouncing);
    assert(a1.kind == ActionKind.StartDebounceTimer);

    // Debounce timer fires -> triggers build
    let a2 = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.DebounceTimerFired,
        paths: [],
        exit_code: 0,
        err_msg: ""
    });
    assert(s.state == SupervisorState.Building);
    assert(a2.kind == ActionKind.TriggerBuild);

    // Initial build succeeds -> starts child (no previous child)
    let a3 = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.BuildSucceeded,
        paths: [],
        exit_code: 0,
        err_msg: ""
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
        err_msg: ""
    });
    assert(s.state == SupervisorState.Debouncing);
    assert(a4.kind == ActionKind.StartDebounceTimer);

    let a5 = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.DebounceTimerFired,
        paths: [],
        exit_code: 0,
        err_msg: ""
    });
    assert(s.state == SupervisorState.Building);
    assert(a5.kind == ActionKind.TriggerBuild);

    // Build succeeds while pid 100 is still running -> stops previous child first!
    let a6 = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.BuildSucceeded,
        paths: [],
        exit_code: 0,
        err_msg: ""
    });
    assert(s.state == SupervisorState.StoppingPrevious);
    assert(a6.kind == ActionKind.StopChild);
    assert(a6.target_pid == 100);

    // Previous child exits -> starts next server
    let a7 = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.ChildProcessExited,
        paths: [],
        exit_code: 0,
        err_msg: ""
    });
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
        err_msg: "syntax error"
    });
    assert(s.state == SupervisorState.Idle);
    assert(a.kind == ActionKind.None);
    assert(s.running_pid == 200); // previous server stays up!
}

fn test_supervisor_child_crash_no_hot_restart() {
    let s = make_supervisor("src/main.sl", ".zokor/watch/app", ".zokor/watch/app.next", false);
    s.running_pid = 300;
    s.state = SupervisorState.Idle;

    let a = supervisor_step(s, SupervisorEvent {
        kind: SupervisorEventKind.ChildProcessExited,
        paths: [],
        exit_code: 1,
        err_msg: ""
    });
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
        err_msg: ""
    });
    assert(a.kind == ActionKind.CleanAndExit);
    assert(a.target_pid == 400);
}
