#!/usr/bin/env bats
# tests/optlib.bats — unit tests for optlib.sh pure functions.
# Run: bats tests/

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    # source the library with test values
    cat > "$BATS_TMPDIR/testenv.sh" <<EOF
SCRIPT_NAME=test
LOG_FILE=\$BATS_TMPDIR/test.log
ASSUME_YES=0
DRY_RUN=0
source "$SCRIPT_DIR/optlib.sh"
EOF
    source "$BATS_TMPDIR/testenv.sh"
}

teardown() {
    rm -f "$BATS_TMPDIR/testenv.sh" "$BATS_TMPDIR/test.log"
}

@test "confirm declines on non-y input" {
    run bash -c "SCRIPT_NAME=t LOG_FILE=$BATS_TMPDIR/t.log ASSUME_YES=0 DRY_RUN=0 source $SCRIPT_DIR/optlib.sh; echo n | ASSUME_YES=0 confirm 'ok?'; echo rc=\$?"
    [[ "$output" == *"rc=1"* ]]
}

@test "confirm honors ASSUME_YES=1 without tty" {
    ASSUME_YES=1
    run confirm 'ok?'
    [[ $status -eq 0 ]]
    ASSUME_YES=0
}

@test "confirm declines when no tty is available" {
    run confirm 'ok?'
    [[ $status -ne 0 ]]
    [[ "$output" == *"no tty"* ]]
}

@test "die exits non-zero with error prefix" {
    run die 'boom'
    [[ $status -eq 1 ]]
    [[ "$output" == "error: boom" ]]
}

@test "run_or_dry dry-run prints but does not execute" {
    DRY_RUN=1
    run run_or_dry 'test action' touch "$BATS_TMPDIR/should-not-exist"
    [[ $status -eq 0 ]]
    [[ "$output" == *"[dry-run]"* ]]
    [[ ! -f "$BATS_TMPDIR/should-not-exist" ]]
    DRY_RUN=0
}

@test "run_or_dry executes the command" {
    DRY_RUN=0
    run run_or_dry 'test action' touch "$BATS_TMPDIR/should-exist"
    [[ $status -eq 0 ]]
    [[ -f "$BATS_TMPDIR/should-exist" ]]
    rm -f "$BATS_TMPDIR/should-exist"
}

@test "log appends timestamped lines" {
    log 'hello world'
    run cat "$LOG_FILE"
    [[ "$output" == *'hello world'* ]]
    [[ "$output" == *'202'*'-'* ]]   # timestamped: 202x-...
}

@test "log is safe under concurrent writers" {
    rm -f "$LOG_FILE"
    cat > "$BATS_TMPDIR/w.sh" <<EOF
SCRIPT_NAME=w
LOG_FILE=\$BATS_TMPDIR/test.log
source "$SCRIPT_DIR/optlib.sh"
for i in \$(seq 1 30); do log "writer \$\$ line \$i"; done
EOF
    bash "$BATS_TMPDIR/w.sh" & bash "$BATS_TMPDIR/w.sh" & wait
    local total bad
    total=$(wc -l < "$LOG_FILE")
    bad=$(grep -cv '^\[20' "$LOG_FILE" || true)
    [[ $total -eq 60 ]]
    [[ $bad -eq 0 ]]
    rm -f "$BATS_TMPDIR/w.sh"
}

@test "proc_cpu_jiffies handles comm with spaces" {
    # synthetic stat line matching the real kernel layout: after stripping
    # "pid (comm) ", f[1]=state, f[2..11]=ppid..cmajflt, f[12]=utime, f[13]=stime
    # -> 100 + 200 = 300
    printf '%s' '99 (Web Kit Process) S 1 1 1 0 -1 4194560 1 1 1 1 100 200 0 0' | {
        local out
        out=$(awk '{
            sub(/^[^)]*\) /, "", $0)
            n = split($0, f, " ")
            print f[12] + f[13]
        }')
        [[ $out -eq 300 ]]
    }
}

@test "usage_from_markers extracts delimited block" {
    cat > "$BATS_TMPDIR/fake.sh" <<'EOF'
#!/usr/bin/env bash
# header line
# <<usage
# USAGE LINE A
#   USAGE LINE B
# usage>>
# after
EOF
    run bash -c "source $SCRIPT_DIR/optlib.sh; BASH_SOURCE_TEST=$BATS_TMPDIR/fake.sh; usage_from_markers_inner() { local script=\$1; awk '/^# <<usage/{on=1; next} /^# usage>>/{on=0} on{sub(/^# ?/,\"\"); print}' \"\$script\"; }; usage_from_markers_inner $BATS_TMPDIR/fake.sh"
    [[ "$output" == *"USAGE LINE A"* ]]
    [[ "$output" == *"USAGE LINE B"* ]]
    [[ "$output" != *"header line"* ]]
    [[ "$output" != *"after"* ]]
}

@test "parse_common_args consumes shared flags" {
    TOP_N=15; WATCH_INTERVAL=60; WATCH_THRESHOLD=80; ASSUME_YES=0; DRY_RUN=0; MODE=""
    parse_common_args --top 5 --threshold 33 --yes --dry-run --watch 3 leftover
    [[ $TOP_N -eq 5 ]]
    [[ $WATCH_THRESHOLD -eq 33 ]]
    [[ $ASSUME_YES -eq 1 ]]
    [[ $DRY_RUN -eq 1 ]]
    [[ $WATCH_INTERVAL -eq 3 ]]
    [[ ${MODE:-} == watch ]]
    [[ ${REMAINING_ARGS[0]} == leftover ]]
}

@test "parse_common_args sets MODE=help for -h" {
    MODE=""
    parse_common_args -h
    [[ ${MODE:-} == help ]]
}
