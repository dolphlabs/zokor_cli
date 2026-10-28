fn test_watch_plan_ignored() {
    assert(is_ignored_path(".git/HEAD"));
    assert(is_ignored_path(".zokor/watch/app"));
    assert(is_ignored_path(".zokor/watch/app.next"));
    assert(is_ignored_path("build/output"));
    assert(is_ignored_path("node_modules/pkg/index.js"));
    assert(is_ignored_path("src/main.sl~"));
    assert(is_ignored_path("src/main.sl.swp"));
    assert(is_ignored_path(".DS_Store"));
    assert(is_ignored_path("sub/.DS_Store"));
    assert(is_ignored_path("app.next"));
    assert(!is_ignored_path("src/main.sl"));
    assert(!is_ignored_path("slang.project"));
}

fn test_watch_plan_classify() {
    assert(classify_path("src/main.sl") == ChangeKind.RebuildApp);
    assert(classify_path("src/domain/entity.sl") == ChangeKind.RebuildApp);
    assert(classify_path("config.json") == ChangeKind.RebuildApp);
    assert(classify_path("slang.lock") == ChangeKind.LockfileChanged);
    assert(classify_path("slang.project") == ChangeKind.LockfileChanged);
    assert(classify_path(".git/index") == ChangeKind.Ignored);
    assert(classify_path(".zokor/watch/app.next") == ChangeKind.Ignored);
    assert(classify_path("image.png") == ChangeKind.Ignored);
}

fn test_watch_plan_filter() {
    let raw: [str] = [".git/refs/heads", "src/main.sl", "notes.tmp", "slang.lock", ".DS_Store"];
    let filtered = filter_relevant_changes(raw);
    assert(len(filtered) == 2);
    assert(filtered[0] == "src/main.sl");
    assert(filtered[1] == "slang.lock");
}
