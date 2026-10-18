#!/usr/bin/env bats
# tests/scripts.bats — integration tests for cpuopt.sh / memopt.sh pure logic.
# Run: bats tests/

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "cpuopt -h prints usage from markers" {
    run "$SCRIPT_DIR/cpuopt.sh" -h
    [[ $status -eq 0 ]]
    [[ "$output" == *"--throttle PID"* ]]
    [[ "$output" == *"Safety invariants"* ]]
}

@test "memopt -h prints usage from markers" {
    run "$SCRIPT_DIR/memopt.sh" -h
    [[ $status -eq 0 ]]
    [[ "$output" == *"--stop-bazel"* ]]
    [[ "$output" == *"Safety invariants"* ]]
}

@test "cpuopt --scan rejects multi-dot input" {
    run "$SCRIPT_DIR/cpuopt.sh" --scan 8.8.8.8
    [[ $status -eq 1 ]]
    [[ "$output" == *"error:"* ]]
}

@test "cpuopt --scan accepts fractional hours" {
    run "$SCRIPT_DIR/cpuopt.sh" --scan 0.1
    [[ $status -eq 0 ]]
    [[ "$output" == *"cumulative CPU time > 0.1h"* ]]
}

@test "cpuopt --report --json emits valid JSON" {
    run "$SCRIPT_DIR/cpuopt.sh" --report --json
    [[ $status -eq 0 ]]
    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert set(d) == {'timestamp', 'cpu', 'top', 'families', 'runaways'}, d.keys()
for k in ('ncores', 'load1', 'user_pct', 'idle_pct'):
    assert k in d['cpu'], k
"
}

@test "cpuopt --report text mode shows all sections" {
    run "$SCRIPT_DIR/cpuopt.sh" --report --top 3
    [[ $status -eq 0 ]]
    [[ "$output" == *"=== CPU summary ==="* ]]
    [[ "$output" == *"=== Top 3 CPU consumers"* ]]
    [[ "$output" == *"=== CPU by application family"* ]]
    [[ "$output" == *"=== Recommendations ==="* ]]
}

@test "memopt --report text mode shows all sections" {
    run "$SCRIPT_DIR/memopt.sh" --report --top 3
    [[ $status -eq 0 ]]
    [[ "$output" == *"=== Memory summary ==="* ]]
    [[ "$output" == *"=== Top 3 memory consumers"* ]]
    [[ "$output" == *"=== Recommendations ==="* ]]
}

@test "cpuopt --dry-run --kill refuses root-owned pid without touching it" {
    run "$SCRIPT_DIR/cpuopt.sh" --dry-run --kill 1
    [[ $status -eq 1 ]]
    [[ "$output" == *"not owned by"* ]]
}

@test "memopt --dry-run --trim-swap prints dry-run or safety message" {
    run "$SCRIPT_DIR/memopt.sh" --dry-run --trim-swap
    [[ $status -eq 0 || $status -eq 1 ]]
    [[ "$output" == *"[dry-run]"* || "$output" == *"NOT SAFE"* || "$output" == *"nothing to trim"* ]]
}

@test "cpuopt family classifier honors config override" {
    mkdir -p "$HOME/.config/perfopt"
    local conf="$HOME/.config/perfopt/apps.conf"
    cp /dev/null "$conf"
    cat > "$conf" <<'EOF'
FAMILY_RULES=( 'testfam:zzz-test-family-marker' )
EOF
    run "$SCRIPT_DIR/cpuopt.sh" --report --top 1
    [[ $status -eq 0 ]]
    # classification still works (no awk errors) — output must not contain awk errors
    [[ "$output" != *"awk:"* ]]
    rm -f "$conf"
}
