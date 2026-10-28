// Execution and supervisor orchestration for zokor start / zokor watch.

import "zokor";
import "proc";
import "io";
import "os";
import "time";
import "fs";
import "strings";

fn locate_entry(specified: str) -> str {
    if len(specified) > 0 {
        if !os.is_file(specified) {
            io.eprintln("zokor: entry point not found: " + specified);
            exit(2);
        }
        return specified;
    }
    if os.is_file("src/main.sl") {
        return "src/main.sl";
    }
    if os.is_file("main.sl") {
        return "main.sl";
    }
    io.eprintln("zokor: no main.sl found in src/ or current directory");
    exit(2);
}

fn compiler_cmd() -> str {
    let env_c = proc.getenv("SLANGC") ?? "";
    if len(env_c) > 0 {
        return env_c;
    }
    return "slangc";
}

// The environment a watch build runs with: this process's own, with
// SLANG_DEV=1 unless `release`, and without it if `release` (so a
// SLANG_DEV=1 set in the shell cannot turn --release back into a
// development build). slangc's development build compiles unoptimized C
// about ten times faster (a 21k-line service: 16 s a rebuild against 73 s).
// It goes through the environment, not a --dev flag: a slangc older than
// the flag ignores the variable and builds optimized, where it would fail
// on an unknown option. proc.spawn's list replaces the whole environment,
// so it carries all of it.
fn build_env(release: bool) -> [str] {
    let env: [str] = [];
    for kv in os.environ() {
        if !strings_has_prefix(kv, "SLANG_DEV=") {
            push(env, kv);
        }
    }
    if !release {
        push(env, "SLANG_DEV=1");
    }
    return env;
}

// Build number `build`: its process is reported as soon as it is spawned, so
// the supervisor can kill it if files change under it, and every result
// carries the number, so a cancelled build's result is recognised and dropped.
fn execute_build_task(entry: str, staging_path: str, env: [str], build: int, ch: chan[SupervisorEvent]) {
    let p = parent_of(staging_path);
    if len(p) > 0 {
        let _md = make_dirs(p);
    }
    let res = proc.spawn([compiler_cmd(), entry, "-o", staging_path], env, "", proc.SPAWN_GROUP | proc.SPAWN_NULL_STDIN);
    guard let bpid = res else let e = err_of(res) {
        io.eprintln("zokor: failed to spawn compiler: " + e);
        chan_send(ch, SupervisorEvent {
            kind: SupervisorEventKind.BuildFailed,
            paths: [],
            exit_code: 1,
            err_msg: e,
            build: build,
            pid: 0
        });
        return;
    }
    chan_send(ch, SupervisorEvent {
        kind: SupervisorEventKind.BuildStarted,
        paths: [],
        exit_code: 0,
        err_msg: "",
        build: build,
        pid: bpid
    });
    let wr = proc.wait(bpid, until_never());
    let code = wr ?? 1;
    if code == 0 {
        chan_send(ch, SupervisorEvent {
            kind: SupervisorEventKind.BuildSucceeded,
            paths: [],
            exit_code: 0,
            err_msg: "",
            build: build,
            pid: 0
        });
    } else {
        chan_send(ch, SupervisorEvent {
            kind: SupervisorEventKind.BuildFailed,
            paths: [],
            exit_code: code,
            err_msg: "compiler exited with code " + to_str(code),
            build: build,
            pid: 0
        });
    }
}

fn child_wait_task(pid: int, ch: chan[SupervisorEvent]) {
    let wr = proc.wait(pid, until_never());
    let code = wr ?? 1;
    chan_send(ch, SupervisorEvent {
        kind: SupervisorEventKind.ChildProcessExited,
        paths: [],
        exit_code: code,
        err_msg: "",
        build: 0,
        pid: 0
    });
}

fn debounce_timer_task(ms: int, ch: chan[SupervisorEvent]) {
    time.sleep(ms * 1000000);
    chan_send(ch, SupervisorEvent {
        kind: SupervisorEventKind.DebounceTimerFired,
        paths: [],
        exit_code: 0,
        err_msg: "",
        build: 0,
        pid: 0
    });
}

fn fallback_kill_timer_task(pid: int, ms: int) {
    time.sleep(ms * 1000000);
    let _k = proc.kill(-pid, 9);
}

fn watcher_task(handle: int, ch: chan[SupervisorEvent]) {
    while true {
        let r = os.watch_next(handle, until_never());
        guard let paths = r else let e = err_of(r) {
            if e == "shutdown" || e == "interrupted" || proc.shutdown_requested() {
                break;
            }
            break;
        }
        chan_send(ch, SupervisorEvent {
            kind: SupervisorEventKind.FilesChanged,
            paths: paths,
            exit_code: 0,
            err_msg: "",
            build: 0,
            pid: 0
        });
    }
}

fn shutdown_checker_task(ch: chan[SupervisorEvent]) {
    while !proc.shutdown_requested() {
        time.sleep(250000000); // 250ms
    }
    chan_send(ch, SupervisorEvent {
        kind: SupervisorEventKind.ShutdownRequested,
        paths: [],
        exit_code: 0,
        err_msg: "",
        build: 0,
        pid: 0
    });
}

fn stop_child_safely(pid: int) {
    if pid <= 0 { return; }
    // Graceful shutdown first
    let _k = proc.kill(-pid, 15);
    // Arm 2-second forced kill fallback in case process refuses to exit
    spawn fallback_kill_timer_task(pid, 2000);
}

fn log_info(msg: str) {
    println(msg);
    io.flush();
}

fn run_foreground(entry: str, bin_path: str, passthrough: [str]) {
    let p = parent_of(bin_path);
    if len(p) > 0 {
        let _md = make_dirs(p);
    }
    log_info("[zokor] building " + entry + " -> " + bin_path + "...");
    let env: [str] = [];
    let bres = proc.spawn([compiler_cmd(), entry, "-o", bin_path], env, "", proc.SPAWN_GROUP | proc.SPAWN_NULL_STDIN);
    guard let bpid = bres else let e = err_of(bres) {
        io.eprintln("zokor: failed to spawn compiler: " + e);
        exit(1);
    }
    let bwait = proc.wait(bpid, until_never());
    let bcode = bwait ?? 1;
    if bcode != 0 {
        io.eprintln("zokor: build failed");
        exit(bcode);
    }

    let cmd: [str] = [bin_path];
    for a in passthrough {
        push(cmd, a);
    }
    let sres = proc.spawn(cmd, env, "", proc.SPAWN_GROUP);
    guard let spid = sres else let e = err_of(sres) {
        io.eprintln("zokor: failed to spawn application: " + e);
        exit(1);
    }
    let swait = proc.wait(spid, until_never());
    let scode = swait ?? 0;
    exit(scode);
}

fn run_watch(entry: str, bin_path: str, staging_path: str, debounce_ms: int, passthrough: [str], verbose: bool, release: bool) {
    log_info("[zokor] starting in watch mode...");
    log_info("[zokor] watching directory: .");
    log_info("[zokor] entry point: " + entry);
    if release {
        log_info("[zokor] optimized builds (--release)");
    } else {
        log_info("[zokor] development builds: unoptimized, quick to compile (--release for optimized)");
    }
    let benv = build_env(release);

    if !os.is_dir(".zokor") {
        let _m1 = fs.mkdir(".zokor");
    }
    if !os.is_dir(".zokor/watch") {
        let _m2 = fs.mkdir(".zokor/watch");
    }

    let excludes: [str] = [".git", ".zokor", "build", "dist", "node_modules", ".cache"];
    let wr = os.watch(".", excludes);
    guard let watch_handle = wr else let e = err_of(wr) {
        io.eprintln("zokor: failed to start file watcher: " + e);
        exit(1);
    }

    let ev_ch: chan[SupervisorEvent] = make_chan(64);
    spawn watcher_task(watch_handle, ev_ch);
    spawn shutdown_checker_task(ev_ch);

    let sup = make_supervisor(entry, bin_path, staging_path, verbose);

    // Initial build
    log_info("[zokor] initial build...");
    let first = trigger_build(sup, "");
    spawn execute_build_task(entry, staging_path, benv, first.build, ev_ch);

    while true {
        select {
            case let ev_opt = chan_recv(ev_ch) {
                guard let ev = ev_opt else {
                    break;
                }
                let act = supervisor_step(sup, ev);
                if len(act.log_msg) > 0 {
                    log_info(act.log_msg);
                }

                if act.kind == ActionKind.StartDebounceTimer {
                    spawn debounce_timer_task(debounce_ms, ev_ch);
                } else if act.kind == ActionKind.TriggerBuild {
                    spawn execute_build_task(entry, staging_path, benv, act.build, ev_ch);
                } else if act.kind == ActionKind.CancelBuild {
                    // SIGKILL, not a graceful stop: its output is discarded,
                    // and it must be gone before the next build writes the
                    // same staging files.
                    if act.target_pid > 0 {
                        let _kb = proc.kill(-act.target_pid, 9);
                    }
                    spawn debounce_timer_task(debounce_ms, ev_ch);
                } else if act.kind == ActionKind.KillStaleBuild {
                    if act.target_pid > 0 {
                        let _ks = proc.kill(-act.target_pid, 9);
                    }
                } else if act.kind == ActionKind.StopChild {
                    stop_child_safely(act.target_pid);
                } else if act.kind == ActionKind.StartChild {
                    let p = parent_of(bin_path);
                    if len(p) > 0 {
                        let _md = make_dirs(p);
                    }
                    let _ren = os.rename(staging_path, bin_path);
                    let env: [str] = [];
                    let cmd: [str] = [bin_path];
                    for a in passthrough {
                        push(cmd, a);
                    }
                    let sres = proc.spawn(cmd, env, "", proc.SPAWN_GROUP);
                    guard let child_pid = sres else let e = err_of(sres) {
                        io.eprintln("zokor: failed to spawn server: " + e);
                        let failed = supervisor_child_failed(sup);
                        if failed.kind == ActionKind.StartDebounceTimer {
                            spawn debounce_timer_task(debounce_ms, ev_ch);
                        }
                        continue;
                    }
                    log_info("[zokor] server started (pid " + to_str(child_pid) + ")");
                    spawn child_wait_task(child_pid, ev_ch);
                    let next = supervisor_child_started(sup, child_pid);
                    if len(next.log_msg) > 0 {
                        log_info(next.log_msg);
                    }
                    if next.kind == ActionKind.StartDebounceTimer {
                        spawn debounce_timer_task(debounce_ms, ev_ch);
                    }
                } else if act.kind == ActionKind.CleanAndExit {
                    if act.target_pid > 0 {
                        let _k = proc.kill(-act.target_pid, 15);
                        let _w = proc.wait(act.target_pid, until_of(time.mono() + 1000000000));
                        let _k9 = proc.kill(-act.target_pid, 9);
                    }
                    let _cl = os.watch_close(watch_handle);
                    let _rm = os.remove(staging_path);
                    exit(0);
                }
            }
        }
    }
}

fn start_cmd(args: [str]) {
    let watch_mode = false;
    let entry_arg = "";
    let bin_arg = "";
    let debounce_ms = 50;
    let verbose = false;
    let release = false;
    let passthrough: [str] = [];

    let i = 2;
    let in_passthrough = false;
    while i < len(args) {
        let a = args[i];
        if in_passthrough {
            push(passthrough, a);
            i = i + 1;
        } else if a == "--" {
            in_passthrough = true;
            i = i + 1;
        } else if a == "--watch" || a == "-w" {
            watch_mode = true;
            i = i + 1;
        } else if a == "--verbose" || a == "-v" {
            verbose = true;
            i = i + 1;
        } else if a == "--release" {
            release = true;
            i = i + 1;
        } else if a == "--entry" {
            if i + 1 >= len(args) { fail_usage("--entry needs a path"); }
            entry_arg = args[i + 1];
            i = i + 2;
        } else if a == "--bin" {
            if i + 1 >= len(args) { fail_usage("--bin needs a path"); }
            bin_arg = args[i + 1];
            i = i + 2;
        } else if a == "--debounce" {
            if i + 1 >= len(args) { fail_usage("--debounce needs milliseconds"); }
            debounce_ms = to_int(args[i + 1]) ?? 50;
            i = i + 2;
        } else if strings_has_prefix(a, "--") {
            fail_usage("unknown option " + a);
        } else {
            fail_usage("unexpected argument: " + a);
        }
    }

    let entry = locate_entry(entry_arg);
    let bin_path = "bin/app";
    if len(bin_arg) > 0 {
        bin_path = bin_arg;
    } else if watch_mode {
        bin_path = ".zokor/watch/app";
    }
    let staging_path = ".zokor/watch/app.next";

    if watch_mode {
        run_watch(entry, bin_path, staging_path, debounce_ms, passthrough, verbose, release);
    } else {
        run_foreground(entry, bin_path, passthrough);
    }
}

fn watch_cmd(args: [str]) {
    // zokor watch is an alias for zokor start --watch
    let forwarded: [str] = [args[0], "start", "--watch"];
    for i in 2..len(args) {
        push(forwarded, args[i]);
    }
    start_cmd(forwarded);
}
