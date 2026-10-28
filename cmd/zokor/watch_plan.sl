// Path classification and filtering for zokor watch mode.

enum ChangeKind {
    Ignored,
    RebuildApp,
    LockfileChanged,
}

fn strings_has_suffix(s: str, suf: str) -> bool {
    let a = to_bytes(s);
    let b = to_bytes(suf);
    let la = len(a);
    let lb = len(b);
    if lb > la { return false; }
    return a[la - lb..la] == b;
}

fn path_split_segments(p: str) -> [str] {
    let b = to_bytes(p);
    let res: [str] = [];
    let start = 0;
    let i = 0;
    while i < len(b) {
        if b[i] == 47 { // '/'
            if i > start {
                let seg = to_str(b[start..i]);
                push(res, seg);
            }
            start = i + 1;
        }
        i = i + 1;
    }
    if start < len(b) {
        let seg = to_str(b[start..len(b)]);
        push(res, seg);
    }
    return res;
}

fn path_contains_segment(p: str, seg: str) -> bool {
    let parts = path_split_segments(p);
    for part in parts {
        if part == seg { return true; }
    }
    return false;
}

fn is_ignored_path(p: str) -> bool {
    if len(p) == 0 { return true; }

    // Exclude well-known directory segments
    for ignored_dir in [".git", ".zokor", "build", "dist", "node_modules", ".cache"] {
        if path_contains_segment(p, ignored_dir) {
            return true;
        }
    }

    // Exclude editors and backup files
    if strings_has_suffix(p, "~") ||
       strings_has_suffix(p, ".swp") ||
       strings_has_suffix(p, ".swo") ||
       strings_has_suffix(p, ".tmp") ||
       strings_has_suffix(p, ".bak") ||
       strings_has_suffix(p, ".next") ||
       strings_has_suffix(p, ".DS_Store") {
        return true;
    }

    // Emacs / Vim autosaves (#foo# or .#foo)
    let segs = path_split_segments(p);
    if len(segs) > 0 {
        let last = segs[len(segs) - 1];
        let lb = to_bytes(last);
        if len(lb) > 0 && lb[0] == 35 { // '#'
            return true;
        }
        if len(lb) > 1 && lb[0] == 46 && lb[1] == 35 { // '.#'
            return true;
        }
    }

    return false;
}

fn is_lockfile_path(p: str) -> bool {
    return p == "slang.lock" || p == "slang.project";
}

fn is_source_path(p: str) -> bool {
    if is_ignored_path(p) { return false; }

    for ext in [".sl", ".json", ".sql", ".env", ".html", ".css", ".js", ".md", ".txt"] {
        if strings_has_suffix(p, ext) {
            return true;
        }
    }
    return false;
}

fn classify_path(p: str) -> ChangeKind {
    if is_ignored_path(p) {
        return ChangeKind.Ignored;
    }
    if is_lockfile_path(p) {
        return ChangeKind.LockfileChanged;
    }
    if is_source_path(p) {
        return ChangeKind.RebuildApp;
    }
    return ChangeKind.Ignored;
}

fn filter_relevant_changes(paths: [str]) -> [str] {
    let res: [str] = [];
    for p in paths {
        let k = classify_path(p);
        if k == ChangeKind.RebuildApp || k == ChangeKind.LockfileChanged {
            push(res, p);
        }
    }
    return res;
}
