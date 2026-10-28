#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZOKOR="$ROOT/bin/zokor"
WORK="$(mktemp -d)"

export SLANGC="${SLANGC:-slangc}"
case "$SLANGC" in
    */*)
        SLANGC_DIR="$(cd "$(dirname "$SLANGC")" && pwd)"
        PATH="$SLANGC_DIR:$PATH"
        export PATH
        ;;
esac

cleanup() {
    if [ -n "${WATCH_PID:-}" ]; then
        kill -TERM "$WATCH_PID" 2>/dev/null || true
        wait "$WATCH_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

fail() { echo "FAIL watch: $*" >&2; exit 1; }

# Create a test project with slang.project and src/main.sl
cd "$WORK"
cat <<'EOF' > slang.project
name watch_app
version 0.1.0
EOF

mkdir -p src

# 1. Non-watch mode test: runs service and handles exit
cat <<'EOF' > src/main.sl
import "io";
println("FOREGROUND_RUN_ONCE");
io.flush();
EOF

OUT=$("$ZOKOR" start 2>&1)
case "$OUT" in
    *"FOREGROUND_RUN_ONCE"*) ;;
    *) fail "expected foreground run output, got: $OUT" ;;
esac
echo "PASS non-watch start"

# 2. Watch mode test
cat <<'EOF' > src/main.sl
import "io";
import "time";

println("WATCH_APP_V1_READY");
io.flush();
while true {
    time.sleep(100000000);
}
EOF

# Launch zokor watch in background and capture output
"$ZOKOR" watch > "$WORK/watch.log" 2>&1 &
WATCH_PID=$!

# Wait for V1 to be reported ready in watch.log (up to 10s)
WAIT=0
while [ "$WAIT" -lt 100 ]; do
    if grep -q "WATCH_APP_V1_READY" "$WORK/watch.log" 2>/dev/null; then
        break
    fi
    sleep 0.1
    WAIT=$((WAIT + 1))
done

if ! grep -q "WATCH_APP_V1_READY" "$WORK/watch.log" 2>/dev/null; then
    cat "$WORK/watch.log"
    fail "watch app V1 failed to start"
fi
echo "PASS watch initial build and start"

# 3. Edit source file to V2 -> expect rebuild and reload
sleep 0.5
cat <<'EOF' > src/main.sl
import "io";
import "time";

println("WATCH_APP_V2_READY");
io.flush();
while true {
    time.sleep(100000000);
}
EOF

WAIT=0
while [ "$WAIT" -lt 100 ]; do
    if grep -q "WATCH_APP_V2_READY" "$WORK/watch.log" 2>/dev/null; then
        break
    fi
    sleep 0.1
    WAIT=$((WAIT + 1))
done

if ! grep -q "WATCH_APP_V2_READY" "$WORK/watch.log" 2>/dev/null; then
    cat "$WORK/watch.log"
    fail "watch app V2 failed to reload after valid edit"
fi
echo "PASS watch reload on source change"

# 4. Introduce a syntax error -> expect build error, but previous server should keep running
sleep 0.5
cat <<'EOF' > src/main.sl
THIS IS DELIBERATELY BROKEN SYNTAX!
EOF

WAIT=0
while [ "$WAIT" -lt 100 ]; do
    if grep -q "build failed. Keeping previous server running." "$WORK/watch.log" 2>/dev/null; then
        break
    fi
    sleep 0.1
    WAIT=$((WAIT + 1))
done

if ! grep -q "build failed. Keeping previous server running." "$WORK/watch.log" 2>/dev/null; then
    cat "$WORK/watch.log"
    fail "watch mode did not report compile failure and server retention"
fi
echo "PASS watch resilience on build error"

# 5. Fix syntax error to V3 -> expect successful build and reload
sleep 0.5
cat <<'EOF' > src/main.sl
import "io";
import "time";

println("WATCH_APP_V3_READY");
io.flush();
while true {
    time.sleep(100000000);
}
EOF

WAIT=0
while [ "$WAIT" -lt 100 ]; do
    if grep -q "WATCH_APP_V3_READY" "$WORK/watch.log" 2>/dev/null; then
        break
    fi
    sleep 0.1
    WAIT=$((WAIT + 1))
done

if ! grep -q "WATCH_APP_V3_READY" "$WORK/watch.log" 2>/dev/null; then
    cat "$WORK/watch.log"
    fail "watch app V3 failed to reload after fixing syntax error"
fi
echo "PASS watch recovery after syntax fix"

# 6. Graceful shutdown on SIGTERM / SIGINT
kill -TERM "$WATCH_PID"
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

echo "PASS watch clean shutdown"
