#!/usr/bin/env bash
# cpuopt.sh — CPU usage analysis & tiered optimization for Linux desktops.
#
# Modes:
#   (no args)          report + safe auto-tier (flag renice'd pids, report only)
#   --report           analysis only, zero side effects
#   --scan [HOURS]     list processes with cumulative CPU time > HOURS (default 8)
#   --throttle PID     renice +15 an always-busy non-interactive process (reversible)
#   --unthrottle PID   restore nice 0
#   --kill PID         SIGTERM a confirmed runaway (prompts; needs --yes or tty)
#   --stop-bazel-thrash  stop compiler/worker processes if a bazel build is stale
#   --watch [SEC]      loop report every SEC seconds (default 60)
#   --install-timer    install user systemd timer for daily reports
#   --top N            rows in the top-process table (default 15)
#   --threshold PCT    busy alert threshold for --watch (default 80)
#   --yes              skip confirmation prompts
#   --dry-run          print actions instead of executing them
#   -h, --help         this help
#
# Safety invariants: only processes owned by $USER are touched; interactive
# processes (GNOME shell, terminal, Xorg, ...) are never throttled or killed;
# SIGTERM first, SIGKILL only after 30s grace and only with explicit consent;
# everything logged to ~/.local/share/cpuopt.log.

set -euo pipefail

readonly SCRIPT_NAME="cpuopt.sh"
readonly LOG_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/cpuopt.log"
readonly TOP_N_DEFAULT=15
readonly WATCH_INTERVAL_DEFAULT=60
readonly WATCH_THRESHOLD_DEFAULT=80
readonly SCAN_HOURS_DEFAULT=8
readonly NICE_VALUE=15

TOP_N=$TOP_N_DEFAULT
WATCH_INTERVAL=$WATCH_INTERVAL_DEFAULT
WATCH_THRESHOLD=$WATCH_THRESHOLD_DEFAULT
SCAN_HOURS=$SCAN_HOURS_DEFAULT
ASSUME_YES=0
DRY_RUN=0

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

die() { echo "error: $*" >&2; exit 1; }

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local reply
    read -r -p "$1 [y/N] " reply </dev/tty 2>/dev/null || reply=""
    [[ $reply =~ ^[Yy]([Ee][Ss])?$ ]]
}

run_or_dry() {
    local desc=$1; shift
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] $desc:"
        echo "          \$ $*"
    else
        echo "[action]  $desc"
        log "$desc — running: $*"
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------

cpu_stats() {
    # emits: ncores load1 cpu_user_pct cpu_idle_pct (from a 1s vmstat sample)
    local ncores
    ncores=$(nproc)
    local line
    line=$(vmstat 1 2 | tail -1)
    local -a f
    read -r -a f <<<"$line"
    # vmstat columns: r b swpd free buff cache si so bi bo in cs us sy id wa st
    printf '%d %s %s %s\n' "$ncores" "${f[0]}" "${f[12]}" "${f[14]}"
}

print_summary() {
    local ncores load1 user_pct idle_pct
    read -r ncores load1 user_pct idle_pct <<<"$(cpu_stats)"
    local per_core
    per_core=$(awk -v l="$load1" -v n="$ncores" 'BEGIN{printf "%.1f", l/n}')
    local pressure
    if awk -v l="$load1" -v n="$ncores" 'BEGIN{exit !(l > n*1.5)}'; then
        pressure="⚠  OVERLOADED — load is ${per_core}x per core; desktop will lag."
    elif awk -v l="$load1" -v n="$ncores" 'BEGIN{exit !(l > n)}'; then
        pressure="⚠  Busy — load ${load1} on ${ncores} cores (${per_core}/core)."
    else
        pressure="✓  CPU load is normal (${load1} on ${ncores} cores)."
    fi
    echo "=== CPU summary ==="
    printf '%s\n' "$pressure"
    printf '1s sample: %.0f%% user, %.0f%% idle\n' "$user_pct" "$idle_pct"
    if (( $(awk -v p="$idle_pct" 'BEGIN{print (p<2)}') )); then
        echo '⚠  CPU is 100% saturated (0% idle).'
    fi
    echo
}

# Aggregated CPU% by application family — same classification as memopt.sh
print_top() {
    local n=$1
    echo "=== Top ${n} CPU consumers (by process, current %CPU) ==="
    printf '%8s %10s %8s   %s\n' 'CPU%' 'CPU_TIME' 'PID' 'COMMAND (args)'
    local i=0
    ps -eo pcpu=,time=,pid=,comm=,args= --sort=-pcpu |
    awk -v topn="$n" 'NR <= topn {
        pcpu=$1; cput=$2; pid=$3; comm=$4
        $1=$2=$3=$4=""
        sub(/^ +/, "", $0)
        printf "%8.1f %10s %8s   %.24s (%.60s)\n", pcpu, cput, pid, comm, $0
    }' | cut -c1-120
    echo
}

# ps time= can be MM:SS, HH:MM:SS or DDD-HH:MM:SS — parse by field count
print_families() {
    echo "=== CPU by application family (lifetime cumulative) ==="
    printf '%-20s %10s %8s\n' 'FAMILY' 'CPU_HOURS' 'PROCS'
    ps -eo time=,comm=,args= |
    awk '
        function to_secs(t,    n, d, secs) {
            n = split(t, d, /[-:]/)
            secs = 0
            if (n == 4) secs = d[1]*86400 + d[2]*3600 + d[3]*60 + d[4]
            else if (n == 3) secs = d[1]*3600 + d[2]*60 + d[3]
            else if (n == 2) secs = d[1]*60 + d[2]
            return secs
        }
        function fam(args, comm,    f) {
            if      (args ~ /cc1plus|cc1|as$|ld\.gold|\/bin\/ld/) f = "compilers"
            else if (args ~ /A-server\.jar/)                      f = "bazel-server"
            else if (args ~ /\/opt\/google\/chrome\/chrome/)      f = "google-chrome"
            else if (args ~ /\/usr\/share\/cursor\/cursor/)       f = "cursor"
            else if (args ~ /\/opt\/bytedance\/feishu\/feishu/)   f = "feishu"
            else                                                  f = comm
            return f
        }
        {
            t = $1; comm = $2
            $1=$2=""; sub(/^ +/, "", $0)
            f = fam($0, comm)
            hrs[f] += to_secs(t)/3600.0; cnt[f]++
        }
        END {
            for (f in hrs) printf "%10.2f\t%s\t%d\n", hrs[f], f, cnt[f]
        }
    ' | sort -rn | awk 'NR <= 10' |
    awk -F'\t' '{ printf "%-20s %10s %8s\n", $2, $1, $3 }'
    echo
}

print_scan() { # print_scan <hours>
    local min_hours=$1
    echo "=== Processes with cumulative CPU time > ${min_hours}h (runaway candidates) ==="
    local out
    out=$(ps -eo time=,pid=,pcpu=,comm=,args= --sort=-time |
    awk -v minh="$min_hours" '
        function to_secs(t,    n, d, secs) {
            n = split(t, d, /[-:]/)
            secs = 0
            if (n == 4) secs = d[1]*86400 + d[2]*3600 + d[3]*60 + d[4]
            else if (n == 3) secs = d[1]*3600 + d[2]*60 + d[3]
            else if (n == 2) secs = d[1]*60 + d[2]
            return secs
        }
        {
            t=$1; pid=$2; pcpu=$3; comm=$4
            $1=$2=$3=$4=""; sub(/^ +/, "", $0)
            secs = to_secs(t)
            if (secs > minh*3600)
                printf "%8.1f  %6s  %5.1f%%  %-18.18s  %.60s\n", secs/3600.0, pid, pcpu, comm, $0
        }')
    if [[ -n $out ]]; then
        printf '%s\n' "$out"
    else
        echo '  (none — no process has burned more than the threshold)'
    fi
    echo
}

print_recommendations() {
    cat <<'EOF'
=== Recommendations ===
 1. Bazel builds saturate all cores. Cap with:  bazel --jobs=8 build ...
    (or add build --jobs=8 to ~/.apollo.bazelrc) so the desktop stays usable.
 2. Runaway webviews: check  ./cpuopt.sh --scan 8  — anything burning days of
    CPU is a stuck renderer (e.g. AweSun's WebKitWebProcess). Restart its parent
    app, or  ./cpuopt.sh --kill <PID>  if it is confirmed stuck.
 3. Throttle instead of kill for background things you do not need fast:
    ./cpuopt.sh --throttle <PID>   (renice +15, fully reversible with --unthrottle)
 4. AweSun (remote desktop) keeps running even when idle (9h+ CPU over 6 days);
    exit it from its tray icon when not needed, or stop autorun: it is started
    with --cmd=autorun.
 5. Feishu/Cursor/Chrome accumulate background CPU over days; restarting them
    periodically (or when fans spin up) resets their CPU usage.
EOF
    echo
}

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------

is_interactive_process() { # is_interactive_process <pid> -> 0 = protect it
    local comm
    comm=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
    case $comm in
        gnome-shell|Xorg|gnome-session*|plasmashell|pulseaudio|pipewire|systemd|bash|zsh)
            return 0;;
        *) return 1;;
    esac
}

proc_pid_alive() { [[ -d /proc/$1 ]] && [[ $(ps -o comm= -p "$1" 2>/dev/null) != "" ]]; }

proc_busy_ratio() { # proc_busy_ratio <pid> -> prints CPU% sampled over 2s
    local pid=$1
    local hz t1 t2
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    t1=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null) || return 1
    sleep 2
    t2=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null) || return 1
    awk -v a="$t1" -v b="$t2" -v hz="$hz" 'BEGIN{printf "%.1f", (b-a)/hz/2*100}'
}

action_throttle() {
    local pid=$1
    proc_pid_alive "$pid" || die "pid $pid is not running"
    local owner comm ratio
    owner=$(ps -o user= -p "$pid")
    [[ $owner == "$USER" ]] || die "pid $pid is not owned by $USER (owner: $owner)"
    comm=$(ps -o comm= -p "$pid")
    is_interactive_process "$pid" && die "pid $pid ($comm) looks interactive — refusing"

    ratio=$(proc_busy_ratio "$pid")
    echo "=== Throttle pid $pid ($comm, currently ${ratio}% CPU) ==="
    echo "  renice +${NICE_VALUE} lowers its priority vs everything else. Reversible:"
    echo "  ./cpuopt.sh --unthrottle $pid"
    confirm "Apply renice +${NICE_VALUE} to pid $pid?" || { echo '  skipped.'; return 0; }
    run_or_dry "renice +${NICE_VALUE} pid $pid" renice -n "$NICE_VALUE" -p "$pid"
    echo
}

action_unthrottle() {
    local pid=$1
    proc_pid_alive "$pid" || die "pid $pid is not running"
    local owner
    owner=$(ps -o user= -p "$pid")
    [[ $owner == "$USER" ]] || die "pid $pid is not owned by $USER"
    run_or_dry "restore nice 0 on pid $pid" renice -n 0 -p "$pid"
    echo
}

action_kill() {
    local pid=$1
    proc_pid_alive "$pid" || die "pid $pid is not running"
    local owner comm
    owner=$(ps -o user= -p "$pid")
    [[ $owner == "$USER" ]] || die "pid $pid is not owned by $USER (owner: $owner)"
    is_interactive_process "$pid" && die "pid $pid looks interactive — refusing"
    comm=$(ps -o comm= -p "$pid")

    echo "=== Kill runaway pid $pid ($comm) ==="
    local etime time pcpu
    read -r etime time pcpu <<<"$(ps -o etime=,time=,pcpu= -p "$pid")"
    echo "  elapsed: ${etime}, cpu time: ${time}, current: ${pcpu}% CPU"
    echo "  ⚠  The parent app may misbehave until restarted."
    confirm "Send SIGTERM to pid $pid?" || { echo '  skipped.'; return 0; }
    run_or_dry "SIGTERM pid $pid" kill "$pid"
    if [[ $DRY_RUN -eq 1 ]]; then echo; return 0; fi

    local i=0
    while (( i < 30 )); do
        proc_pid_alive "$pid" || break
        sleep 1; i=$((i+1))
    done
    if proc_pid_alive "$pid"; then
        echo "  still alive after 30s. Send SIGKILL? (irrecoverable)"
        if confirm "SIGKILL pid $pid?"; then
            run_or_dry "SIGKILL pid $pid" kill -9 "$pid"
        else
            echo '  left alone.'
        fi
    else
        log "killed runaway pid $pid ($comm)"
        echo '  process terminated.'
    fi
    echo
}

action_stop_bazel_thrash() {
    echo '=== Stop stale bazel build processes ==='
    # The build is considered stale if no bazel client process is driving it.
    local clients compilers
    clients=$(ps -eo args= | grep -c '[b]azel(apollo)\|[b]azel --' || true)
    compilers=$(pgrep -u "$USER" -c 'cc1plus|cc1$' 2>/dev/null || echo 0)
    echo "  bazel clients: ${clients}, compiler processes: ${compilers}"
    if (( compilers == 0 )); then
        echo '  no compiler processes running — nothing to do.'
        echo; return 0
    fi
    if (( clients > 0 )); then
        echo '  a bazel client is attached — this looks like a live build.'
        confirm 'Kill the compiler processes anyway?' \
            || { echo '  skipped.'; echo; return 0; }
    else
        echo '  NO bazel client is attached — orphaned build processes.'
        confirm 'Kill orphaned compiler processes?' \
            || { echo '  skipped.'; echo; return 0; }
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        echo '[dry-run] pkill -TERM -u "$USER" -f "cc1plus|cc1 "'
    else
        pkill -TERM -u "$USER" -f 'cc1plus|cc1 ' || true
        log 'killed compiler processes (stale bazel build)'
        echo '  done.'
    fi
    echo
}

action_watch() {
    echo "Watch mode: reporting every ${WATCH_INTERVAL}s, alerting above ${WATCH_THRESHOLD}% busy. Ctrl-C to stop."
    while true; do
        date '+%H:%M:%S'
        print_summary
        local ncores load1 user_pct idle_pct
        read -r ncores load1 user_pct idle_pct <<<"$(cpu_stats)"
        local busy
        busy=$(awk -v p="$user_pct" 'BEGIN{printf "%.0f", 100-p}')
        if (( $(awk -v p="$idle_pct" -v t="$WATCH_THRESHOLD" 'BEGIN{print (p < 100-t)}') )); then
            echo "⚠ ALERT: CPU busy >${WATCH_THRESHOLD}% — top offender:"
            ps -eo pcpu=,comm=,args= --sort=-pcpu | head -3 | awk '{printf "  %5s%%  %s\n", $1, $2}'
            log "ALERT: high CPU (${idle_pct}% idle)"
        fi
        sleep "$WATCH_INTERVAL"
    done
}

action_install_timer() {
    echo '=== Installing daily-report systemd user timer ==='
    local src_dir destination abs_script
    src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/systemd"
    destination=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
    if [[ ! -f $src_dir/cpuopt-report.timer ]]; then
        die "systemd units not found next to script (expected $src_dir)"
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] install $src_dir/cpuopt-report.{service,timer} -> $destination"
        return 0
    fi
    mkdir -p "$destination"
    abs_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cpuopt.sh"
    sed "s|__CPUOPT_PATH__|$abs_script|" \
        "$src_dir"/cpuopt-report.service > "$destination"/cpuopt-report.service
    cp "$src_dir"/cpuopt-report.timer "$destination/"
    systemctl --user daemon-reload
    systemctl --user enable --now cpuopt-report.timer
    log 'installed and enabled cpuopt-report.timer'
    echo '  installed and enabled. View reports with:'
    echo '    journalctl --user -u cpuopt-report.service'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

usage() {
    sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

main() {
    local mode=auto
    while (( $# )); do
        case $1 in
            --report)      mode=report;;
            --scan)        mode=scan; [[ ${2:-} =~ ^[0-9.]+$ ]] && { SCAN_HOURS=$2; shift; };;
            --throttle)    mode=throttle; shift; THROTTLE_PID=${1:?--throttle needs a PID};;
            --unthrottle)  mode=unthrottle; shift; THROTTLE_PID=${1:?--unthrottle needs a PID};;
            --kill)        mode=kill; shift; KILL_PID=${1:?--kill needs a PID};;
            --stop-bazel-thrash) mode=stop-bazel-thrash;;
            --watch)       mode=watch; [[ ${2:-} =~ ^[0-9]+$ ]] && { WATCH_INTERVAL=$2; shift; };;
            --install-timer) mode=install-timer;;
            --top)         shift; TOP_N=${1:?--top needs a number};;
            --threshold)   shift; WATCH_THRESHOLD=${1:?--threshold needs a percentage};;
            --yes)         ASSUME_YES=1;;
            --dry-run)     DRY_RUN=1;;
            -h|--help)     usage;;
            *) die "unknown option: $1 (see --help)";;
        esac
        shift
    done

    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$SCRIPT_NAME — $(date '+%F %T')" | tee -a "$LOG_FILE" >/dev/null

    case $mode in
        report)      print_summary; print_top "$TOP_N"; print_families; print_scan "$SCAN_HOURS"; print_recommendations;;
        scan)        print_scan "$SCAN_HOURS";;
        throttle)    action_throttle "$THROTTLE_PID";;
        unthrottle)  action_unthrottle "$THROTTLE_PID";;
        kill)        action_kill "$KILL_PID";;
        stop-bazel-thrash) action_stop_bazel_thrash;;
        watch)       action_watch;;
        install-timer) action_install_timer;;
        auto)
            print_summary
            print_top "$TOP_N"
            print_families
            print_scan "$SCAN_HOURS"
            echo '--- safe tier: nothing is throttled or killed automatically ---'
            print_recommendations
            ;;
        *) die "internal error: bad mode $mode";;
    esac
}

main "$@"
