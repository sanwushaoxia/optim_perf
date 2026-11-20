#!/usr/bin/env bash
# sandboxgc.sh — detect and reclaim leaked Cursor sandbox processes.
# <<usage
# Modes:
#   (no args)          report only, zero side effects (same as --report)
#   --report           leak inventory + process/thread pressure + candidates
#   --json             with --report: machine-readable JSON output
#   --gc               reclaim leaked sandboxes (prompts unless --yes)
#   --watch [SEC]      loop the leak inventory every SEC seconds (default 60)
#   --install-timer    install the hourly reclaim systemd user timer
#   --top N            rows in the candidate table (default 15)
#   --min-age SEC      only reclaim sandboxes older than SEC (default 3600)
#   --max-cpu JIFFIES  only reclaim sandboxes with cpu time <= JIFFIES (default 0)
#   --grace SEC        SIGTERM grace before SIGKILL escalation (default 5)
#   --orphans-only     restrict reclaim to ppid=1 sandboxes (default: also
#                      reclaim the ones systemd --user adopted)
#   --threshold N      --watch alert threshold for sandbox count (default 300)
#   --yes              skip confirmation prompts
#   --dry-run          print actions instead of executing them
#   -h, --help         this help
#
# Why this exists: Cursor's helper `cursorsandbox` leaks one --policy / --run-proxy
# pair per agent command and never reaps them. Each holds 15 threads, so a few
# thousand leaks add ~30k threads to a 14-core laptop and every tool that walks
# /proc (ps, top, system monitor) starts taking seconds. Leaked sandboxes are
# trivially identifiable: no child processes, zero cumulative CPU time, and no
# longer parented by the terminal that spawned them.
#
# Safety invariants: only processes owned by $USER are touched; only processes
# named exactly cursorsandbox are considered; a sandbox with any child process or
# with non-zero CPU time is never reclaimed (it is driving a live command); the
# script's own ancestry is excluded; SIGTERM first, SIGKILL only after --grace and
# separate consent; everything logged to ~/.local/share/sandboxgc.log.
# usage>>

set -euo pipefail

SCRIPT_NAME="sandboxgc.sh"
readonly LOG_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/sandboxgc.log"
readonly STATE_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/sandboxgc.state"
readonly TOP_N_DEFAULT=15
readonly MIN_AGE_DEFAULT=3600
readonly MAX_CPU_DEFAULT=0
readonly GRACE_DEFAULT=5
readonly WATCH_INTERVAL_DEFAULT=60
readonly WATCH_THRESHOLD_DEFAULT=300
readonly PROC_BASELINE=600
readonly THREAD_BASELINE=2000

TOP_N=$TOP_N_DEFAULT
MIN_AGE=$MIN_AGE_DEFAULT
MAX_CPU=$MAX_CPU_DEFAULT
GRACE=$GRACE_DEFAULT
WATCH_INTERVAL=$WATCH_INTERVAL_DEFAULT
WATCH_THRESHOLD=$WATCH_THRESHOLD_DEFAULT
# shellcheck disable=SC2034  # consumed by optlib.sh confirm()
ASSUME_YES=0
DRY_RUN=0
JSON_OUT=0
ORPHANS_ONLY=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=optlib.sh
source "$SCRIPT_DIR/optlib.sh"

json_escape() { # json_escape <string> — escape for a JSON string literal
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# scanning
# ---------------------------------------------------------------------------

# Guarded snapshot of every readable /proc entry, as "pid<TAB>rss_kb<TAB>stat".
# bash does the reads so a pid vanishing mid-scan cannot kill the consumer with
# a fatal awk error (pids churn constantly on this box).
feed_proc() {
    local d pid st rss _
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        # only processes owned by the invoking user
        [[ -O $d ]] || continue
        read -r st < "$d/stat" 2>/dev/null || continue
        rss=0
        read -r _ rss _ < "$d/statm" 2>/dev/null || true
        printf '%s\t%s\t%s\n' "$pid" "${rss:-0}" "$st"
    done
}

# Classifies cursorsandbox leaks. No ps: ps is itself the thing that hurts once
# the thread count blows up (5-7s at 2200 processes / 28k threads).
# Emits TSV: pid ppid kind cpu_jiffies threads age_s rss_kb has_children
scan_sandboxes() {
    local hz up self
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    up=$(cut -d' ' -f1 /proc/uptime)
    self=$$
    feed_proc | awk -v hz="$hz" -v up="$up" -v self="$self" '
    function commof(line,   a, b, i) {
        a = index(line, "(")
        b = 0
        for (i = length(line); i > 0; i--) if (substr(line, i, 1) == ")") { b = i; break }
        if (a == 0 || b == 0) return ""
        _comm_tail = b
        return substr(line, a + 1, b - a - 1)
    }
    {
        pid = $1; rss[pid] = $2 * 4
        line = $3
        for (i = 4; i <= NF; i++) line = line " " $i
        c = commof(line)
        if (c == "") next
        rest = substr(line, _comm_tail + 2)
        split(rest, f, " ")
        # ppid of every process is needed for the self-ancestry walk and for
        # telling systemd --user adoption apart from a live terminal parent
        allppid[pid] = f[2] + 0
        allcomm[pid] = c
        if (c != "cursorsandbox") next
        comm[pid] = c
        cpu[pid] = f[12] + f[13]
        thr[pid] = f[18] + 0
        start[pid] = f[20] + 0
    }
    END {
        for (p in comm) haschild[allppid[p]] = 1
        q = self
        while (q != "" && q != 0 && !(q in exclude)) { exclude[q] = 1; q = allppid[q] }
        for (p in comm) {
            if (p in exclude) continue
            parent = allppid[p]
            kind = (parent == 1) ? "orphan" \
                 : (allcomm[parent] ~ /^systemd/) ? "adopted" : "attached"
            printf "%s\t%d\t%s\t%d\t%d\t%d\t%d\t%d\n", p, parent, kind, cpu[p], \
                thr[p], up - start[p] / hz, rss[p], haschild[p] + 0
        }
    }'
}

# system-wide process/thread totals plus per-command thread aggregation
proc_pressure() {
    feed_proc | awk -F'\t' '
    {
        line = $3
        a = index(line, "(")
        b = 0
        for (i = length(line); i > 0; i--) if (substr(line, i, 1) == ")") { b = i; break }
        if (a == 0 || b == 0) next
        comm = substr(line, a + 1, b - a - 1)
        rest = substr(line, b + 2)
        split(rest, f, " ")
        t = f[18] + 0
        procs++
        threads += t
        tsum[comm] += t
        tcnt[comm]++
    }
    END {
        printf "@totals\t%d\t%d\n", procs, threads
        for (c in tsum) printf "@agg\t%d\t%d\t%s\n", tsum[c], tcnt[c], c
    }'
}

# ---------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------

now_epoch() { date +%s; }

# leak rate since the previous run; prints a note until a baseline exists
leak_rate() { # leak_rate <current_count>
    local cur=$1 now prev_ts prev_ct dt dc
    now=$(now_epoch)
    if [[ -f $STATE_FILE ]]; then
        read -r prev_ts prev_ct < "$STATE_FILE" || true
        if [[ ${prev_ts:-} =~ ^[0-9]+$ && ${prev_ct:-} =~ ^[0-9]+$ ]]; then
            dt=$(( now - prev_ts )); dc=$(( cur - prev_ct ))
            if (( dt > 0 )); then
                awk -v d="$dc" -v t="$dt" 'BEGIN{printf "%.1f per minute", d/(t/60.0)}'
                return 0
            fi
        fi
    fi
    echo 'n/a (no baseline yet)'
}

save_state() { # save_state <count>
    if [[ $DRY_RUN -eq 1 ]]; then return 0; fi
    printf '%s %s\n' "$(now_epoch)" "$1" > "$STATE_FILE" 2>/dev/null || true
}

reclaimable_filter() { # reclaimable_filter — reads TSV on stdin, prints the reclaimable rows
    awk -F'\t' -v min_age="$MIN_AGE" -v max_cpu="$MAX_CPU" -v orphans_only="$ORPHANS_ONLY" '
    {
        pid = $1; kind = $3; cpu = $4; age = $6; kids = $8
        if (kind == "attached") next
        if (orphans_only == 1 && kind != "orphan") next
        if (kids != 0) next
        if (cpu > max_cpu) next
        if (age < min_age) next
        print
    }'
}

fmt_duration() { # fmt_duration <seconds>
    awk -v s="${1:-0}" 'BEGIN{
        if (s >= 86400) printf "%.1f days", s/86400
        else if (s >= 3600) printf "%.1f hours", s/3600
        else if (s >= 60) printf "%.0f minutes", s/60
        else printf "%d seconds", s
    }'
}

count_lines() { # count_lines — grep -c that tolerates zero matches under pipefail
    local n
    n=$(grep -c . || true)
    echo "${n:-0}"
}

print_summary() { # print_summary <tsv-stream>
    local tsv=$1
    local total orphan adopted attached cpu_sum thr_sum rss_sum oldest reclaim
    total=$(printf '%s\n' "$tsv" | count_lines)
    read -r orphan adopted attached < <(printf '%s\n' "$tsv" | awk -F'\t' '
        { c[$3]++ } END { printf "%d %d %d\n", c["orphan"]+0, c["adopted"]+0, c["attached"]+0 }')
    read -r cpu_sum thr_sum rss_sum oldest < <(printf '%s\n' "$tsv" | awk -F'\t' '
        { cpu += $4; thr += $5; rss += $7; if ($6 > age) age = $6 }
        END { printf "%d %d %d %d\n", cpu, thr, rss, age }')
    reclaim=$(printf '%s\n' "$tsv" | reclaimable_filter | count_lines)

    echo "=== Sandbox leak summary ==="
    printf 'cursorsandbox processes: %d   (orphan %d | systemd-adopted %d | attached %d)\n' \
        "$total" "$orphan" "$adopted" "$attached"
    printf 'threads held: %d   RSS: %d MB   CPU burned: %ss   oldest: %s\n' \
        "$thr_sum" "$(( rss_sum / 1024 ))" \
        "$(awk -v j="$cpu_sum" -v hz="$(getconf CLK_TCK 2>/dev/null || echo 100)" 'BEGIN{printf "%.0f", j/hz}')" \
        "$(fmt_duration "$oldest")"
    printf 'leak rate: %s\n' "$(leak_rate "$total")"
    if (( total == 0 )); then
        echo 'OK  no Cursor sandbox processes found — nothing is leaking.'
    elif (( reclaim == total )); then
        printf 'WARN  all %d are idle leftovers (no children, %s CPU) — safe to reclaim.\n' \
            "$total" "$(fmt_cpu_guard)"
    elif (( reclaim > 0 )); then
        printf 'WARN  %d of %d are idle leftovers safe to reclaim.\n' "$reclaim" "$total"
        printf '      the other %d are not reclaimable: %s\n' "$(( total - reclaim ))" \
            "$(exclusion_reasons "$tsv")"
    else
        printf 'OK  no leaks to reclaim right now; the %d present are held back: %s\n' \
            "$total" "$(exclusion_reasons "$tsv")"
    fi
    echo
}

exclusion_reasons() { # exclusion_reasons <tsv-stream> — why rows fail the reclaim guards
    local tsv=$1
    printf '%s\n' "$tsv" | awk -F'\t' \
        -v min_age="$MIN_AGE" -v max_cpu="$MAX_CPU" -v orphans_only="$ORPHANS_ONLY" '
    {
        kind = $3; cpu = $4; age = $6; kids = $8
        if (kind == "attached") { attached++; next }
        if (orphans_only == 1 && kind != "orphan") { adopted++; next }
        if (kids != 0) { busy++; next }
        if (cpu > max_cpu) { ran++; next }
        if (age < min_age) { young++; next }
    }
    END {
        n = 0
        if (young)    { printf "%d younger than %ss", young, min_age; n++ }
        if (busy)     { printf "%s%d with live children", (n++ ? ", " : ""), busy }
        if (ran)      { printf "%s%d with CPU time > %s jiffies", (n++ ? ", " : ""), ran, max_cpu }
        if (attached) { printf "%s%d attached to a live terminal", (n++ ? ", " : ""), attached }
        if (adopted)  { printf "%s%d adopted by systemd (--orphans-only)", (n++ ? ", " : ""), adopted }
        if (n == 0) printf "none"
    }'
}

fmt_cpu_guard() { # fmt_cpu_guard — human phrasing for the --max-cpu guard
    if (( MAX_CPU == 0 )); then echo 'zero'; else echo "<=${MAX_CPU} jiffies"; fi
}

print_pressure() { # print_pressure <pressure-stream>
    local data=$1 procs threads ratio
    read -r procs threads < <(printf '%s\n' "$data" | awk -F'\t' '
        $1 == "@totals" { printf "%d %d\n", $2, $3 }')
    echo '=== System process and thread pressure ==='
    printf 'processes: %d (healthy baseline < %d)   threads: %d (healthy baseline < %d)\n' \
        "$procs" "$PROC_BASELINE" "$threads" "$THREAD_BASELINE"
    if (( procs > PROC_BASELINE || threads > THREAD_BASELINE )); then
        ratio=$(( threads / THREAD_BASELINE ))
        (( ratio < 1 )) && ratio=1
        printf 'WARN  thread count is %dx the healthy baseline; anything that walks\n' "$ratio"
        echo '      /proc (ps, top, system monitor, editor file watchers) will feel slow.'
    else
        echo 'OK  process and thread counts are within range.'
    fi
    echo
    printf '=== Top %d thread consumers by command ===\n' "$TOP_N"
    printf '%8s %8s   %s\n' 'THREADS' 'PROCS' 'COMMAND'
    printf '%s\n' "$data" | awk -F'\t' '$1 == "@agg"' |
    sort -t$'\t' -k2,2nr |
    awk -F'\t' -v n="$TOP_N" 'NR <= n { printf "%8d %8d   %s\n", $2, $3, $4 }'
    echo
}

print_candidates() { # print_candidates <tsv-stream>
    local tsv=$1 list
    list=$(printf '%s\n' "$tsv" | reclaimable_filter | sort -t$'\t' -k6,6nr)
    echo "=== Reclaim candidates (top ${TOP_N} by age) ==="
    if [[ -z $list ]]; then
        printf '  (none — %s)\n' "$(exclusion_reasons "$tsv")"
        echo
        return 0
    fi
    printf '%8s %8s %8s %12s   %s\n' 'PID' 'THREADS' 'RSS_MB' 'AGE' 'KIND'
    local shown=0
    while IFS=$'\t' read -r pid _ppid kind _cpu thr age rss _kids; do
        [[ -n ${pid:-} ]] || continue
        if (( shown >= TOP_N )); then break; fi
        printf '%8s %8s %8d %12s   %s\n' "$pid" "$thr" "$(( rss / 1024 ))" \
            "$(fmt_duration "$age")" "$kind"
        (( shown += 1 ))
    done <<<"$list"
    printf '  total reclaimable: %s\n' "$(printf '%s\n' "$list" | count_lines)"
    echo "  reclaim with:  ./$SCRIPT_NAME --gc"
    echo
}

emit_json() { # emit_json <tsv-stream>
    local tsv=$1
    local total orphan adopted attached thr_sum rss_sum reclaim
    total=$(printf '%s\n' "$tsv" | count_lines)
    read -r orphan adopted attached < <(printf '%s\n' "$tsv" | awk -F'\t' '
        { c[$3]++ } END { printf "%d %d %d\n", c["orphan"]+0, c["adopted"]+0, c["attached"]+0 }')
    read -r thr_sum rss_sum < <(printf '%s\n' "$tsv" | awk -F'\t' '
        { thr += $5; rss += $7 } END { printf "%d %d\n", thr, rss }')
    reclaim=$(printf '%s\n' "$tsv" | reclaimable_filter | count_lines)

    printf '{\n'
    printf '  "timestamp": "%s",\n' "$(date -Iseconds)"
    printf '  "sandbox": {"total": %d, "orphan": %d, "adopted": %d, "attached": %d,\n' \
        "$total" "$orphan" "$adopted" "$attached"
    printf '    "threads": %d, "rss_kb": %d, "reclaimable": %d, "leak_rate": "%s"},\n' \
        "$thr_sum" "$rss_sum" "$reclaim" "$(json_escape "$(leak_rate "$total")")"
    printf '  "candidates": ['
    local sep="" pid ppid kind cpu thr age rss kids
    while IFS=$'\t' read -r pid ppid kind cpu thr age rss kids; do
        [[ -n ${pid:-} ]] || continue
        printf '%s\n    {"pid": %s, "ppid": %s, "kind": "%s", "cpu_jiffies": %s, "threads": %s, "age_s": %s, "rss_kb": %s, "children": %s}' \
            "$sep" "$pid" "$ppid" "$kind" "$cpu" "$thr" "$age" "$rss" "$kids"
        sep=","
    done < <(printf '%s\n' "$tsv" | reclaimable_filter | sort -t$'\t' -k6,6nr)
    [[ -n $sep ]] && printf '\n  '
    printf ']\n'
    echo '}'
}

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------

action_gc() {
    local tsv list count
    tsv=$(scan_sandboxes)
    list=$(printf '%s\n' "$tsv" | reclaimable_filter | sort -t$'\t' -k6,6nr)
    count=$(printf '%s\n' "$list" | count_lines)

    echo '=== Reclaiming leaked Cursor sandboxes ==='
    printf '  candidates: %d (guards: no children, CPU %s, age >= %ss)\n' \
        "$count" "$(fmt_cpu_guard)" "$MIN_AGE"
    if (( count == 0 )); then
        echo '  nothing to reclaim.'
        echo
        return 0
    fi

    local -a pids=()
    local pid
    while IFS=$'\t' read -r pid _; do
        [[ -n ${pid:-} ]] && pids+=("$pid")
    done <<<"$list"
    echo "  each candidate holds 15 threads; reclaiming all ${#pids[@]} releases $(( ${#pids[@]} * 15 ))."
    confirm "Send SIGTERM to ${#pids[@]} leaked sandboxes?" || { echo '  skipped.'; echo; return 0; }

    if [[ $DRY_RUN -eq 1 ]]; then
        local i=0
        for pid in "${pids[@]}"; do
            if (( i < 5 )); then echo "[dry-run] SIGTERM pid $pid"; fi
            (( i += 1 ))
        done
        if (( ${#pids[@]} > 5 )); then
            echo "[dry-run] ... and $(( ${#pids[@]} - 5 )) more"
        fi
        echo
        return 0
    fi

    kill -TERM "${pids[@]}" 2>/dev/null || true
    log "SIGTERM ${#pids[@]} leaked sandboxes"
    echo "  sent SIGTERM, waiting ${GRACE}s..."
    sleep "$GRACE"

    local -a survivors=()
    for pid in "${pids[@]}"; do
        if proc_pid_alive "$pid"; then survivors+=("$pid"); fi
    done
    if (( ${#survivors[@]} > 0 )); then
        echo "  ${#survivors[@]} survived SIGTERM."
        if confirm "SIGKILL the ${#survivors[@]} survivors?"; then
            kill -KILL "${survivors[@]}" 2>/dev/null || true
            log "SIGKILL ${#survivors[@]} sandboxes that ignored SIGTERM"
            sleep 1
        else
            echo '  left alone.'
        fi
    fi

    local after total_after reclaim_after threads_now
    after=$(scan_sandboxes)
    total_after=$(printf '%s\n' "$after" | count_lines)
    reclaim_after=$(printf '%s\n' "$after" | reclaimable_filter | count_lines)
    threads_now=$(proc_pressure | awk -F'\t' '$1=="@totals"{print $3}')
    printf '  done — cursorsandbox now: %d (reclaimable %d), threads now: %s\n' \
        "$total_after" "$reclaim_after" "${threads_now:-?}"
    echo
}

action_watch() {
    echo "Watch mode: leak inventory every ${WATCH_INTERVAL}s, alerting above ${WATCH_THRESHOLD} sandboxes. Ctrl-C to stop."
    local tsv total
    while true; do
        date '+%H:%M:%S'
        tsv=$(scan_sandboxes)
        print_summary "$tsv"
        total=$(printf '%s\n' "$tsv" | count_lines)
        if (( total > WATCH_THRESHOLD )); then
            echo "WARN  ALERT: ${total} sandboxes exceed the ${WATCH_THRESHOLD} threshold — run ./$SCRIPT_NAME --gc"
            log "ALERT: ${total} sandboxes (threshold ${WATCH_THRESHOLD})"
        fi
        save_state "$total"
        sleep "$WATCH_INTERVAL"
    done
}

action_install_timer() { install_timer sandboxgc gc; }

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

usage() { usage_from_markers; }

main() {
    local mode=report
    parse_common_args "$@"
    case ${MODE:-} in
        help) usage_from_markers;;
        watch) mode=watch;;
    esac
    local -a rest=("${REMAINING_ARGS[@]}")
    while (( ${#rest[@]} )); do
        case ${rest[0]} in
            --report)        mode="report";;
            --gc)            mode="gc";;
            --json)          JSON_OUT=1;;
            --orphans-only)  ORPHANS_ONLY=1;;
            --min-age)       MIN_AGE="${rest[1]:?--min-age needs seconds}"; rest=("${rest[@]:1}");;
            --max-cpu)       MAX_CPU="${rest[1]:?--max-cpu needs jiffies}"; rest=("${rest[@]:1}");;
            --grace)         GRACE="${rest[1]:?--grace needs seconds}"; rest=("${rest[@]:1}");;
            --install-timer) mode="install-timer";;
            *) die "unknown option: ${rest[0]} (see --help)";;
        esac
        rest=("${rest[@]:1}")
    done
    [[ $MIN_AGE =~ ^[0-9]+$ ]] || die '--min-age must be an integer number of seconds'
    [[ $MAX_CPU =~ ^[0-9]+$ ]] || die '--max-cpu must be an integer number of jiffies'
    [[ $GRACE =~ ^[0-9]+$ ]] || die '--grace must be an integer number of seconds'
    [[ $TOP_N =~ ^[0-9]+$ ]] || die '--top must be an integer'

    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$SCRIPT_NAME — $(date '+%F %T')" | tee -a "$LOG_FILE" >/dev/null

    case $mode in
        report)
            local tsv pressure total
            tsv=$(scan_sandboxes)
            pressure=$(proc_pressure)
            if [[ $JSON_OUT -eq 1 ]]; then
                emit_json "$tsv"
            else
                print_summary "$tsv"
                print_pressure "$pressure"
                print_candidates "$tsv"
            fi
            total=$(printf '%s\n' "$tsv" | count_lines)
            save_state "$total"
            ;;
        gc)            action_gc;;
        watch)         action_watch;;
        install-timer) action_install_timer;;
        *) die "internal error: bad mode $mode";;
    esac
}

main "$@"
