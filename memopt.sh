#!/usr/bin/env bash
# memopt.sh — memory usage analysis & tiered optimization for Linux desktops.
#
# Modes:
#   (no args)          report + safe auto-tier (stop idle bazel server)
#   --report           analysis only, zero side effects
#   --stop-bazel       stop idle bazel server JVM (lossless, rebuilt on demand)
#   --clean            drop page cache (sudo, prompts unless --yes)
#   --trim-swap        cycle swap off/on to flush stale swap pages (safety-checked)
#   --restart APP      graceful restart of chrome|feishu|cursor (prompts unless --yes)
#   --watch [SEC]      loop report every SEC seconds (default 60), alerts when low
#   --install-timer    install user systemd timer for daily reports
#   --top N            rows in the top-process table (default 15)
#   --threshold PCT    low-memory alert threshold for --watch (default 15)
#   --yes              skip confirmation prompts (not honored for sudo)
#   --dry-run          print actions instead of executing them
#
# Safety invariants: only processes owned by $USER are touched, apps are matched
# by exact binary path, SIGTERM first, everything logged to ~/.local/share/memopt.log.

set -euo pipefail

readonly SCRIPT_NAME="memopt.sh"
readonly LOG_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/memopt.log"
readonly TOP_N_DEFAULT=15
readonly WATCH_INTERVAL_DEFAULT=60
readonly WATCH_THRESHOLD_DEFAULT=15

TOP_N=$TOP_N_DEFAULT
WATCH_INTERVAL=$WATCH_INTERVAL_DEFAULT
WATCH_THRESHOLD=$WATCH_THRESHOLD_DEFAULT
ASSUME_YES=0
DRY_RUN=0

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

die() { echo "error: $*" >&2; exit 1; }

confirm() {
    # confirm <prompt> -> returns 0 if approved
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local reply
    read -r -p "$1 [y/N] " reply </dev/tty 2>/dev/null || reply=""
    [[ $reply =~ ^[Yy]([Ee][Ss])?$ ]]
}

run_or_dry() {
    # run_or_dry <description> <command...>
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

mb() { # kilobytes -> megabytes
    echo $(( $1 / 1024 ))
}

# ---------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------

mem_fields() {
    # emits: total available used_kb swap_total swap_used (KB, except pct)
    awk '
        /^MemTotal:/     {t=$2}
        /^MemAvailable:/ {a=$2}
        /^SwapTotal:/    {st=$2}
        /^SwapFree:/     {sf=$2}
        END {
            u = t - a
            su = st - sf
            printf "%d %d %d %d %d\n", t, a, u, st, su
        }' /proc/meminfo
}

print_summary() {
    read -r total_kb avail_kb used_kb swap_total_kb swap_used_kb <<<"$(mem_fields)"
    local total_mb avail_mb used_mb
    total_mb=$(mb "$total_kb"); avail_mb=$(mb "$avail_kb"); used_mb=$(mb "$used_kb")
    local avail_pct=0 swap_pct=0
    (( total_mb > 0 )) && avail_pct=$(( avail_mb * 100 / total_mb ))
    (( swap_total_kb > 0 )) && swap_pct=$(( swap_used_kb * 100 / swap_total_kb ))

    echo "=== Memory summary ==="
    printf 'RAM:  %d MB total | %d MB in use | %d MB available (%d%%)\n' \
        "$total_mb" "$used_mb" "$avail_mb" "$avail_pct"
    if (( swap_total_kb > 0 )); then
        printf 'Swap: %d MB total | %d MB used (%d%%)\n' \
            "$(mb "$swap_total_kb")" "$(mb "$swap_used_kb")" "$swap_pct"
    else
        echo 'Swap: none configured'
    fi

    if (( avail_pct < 10 )); then
        echo "⚠  LOW MEMORY: only ${avail_pct}% available — system at risk of thrashing."
    elif (( avail_pct < WATCH_THRESHOLD )); then
        echo "⚠  Memory getting tight (${avail_pct}% available)."
    else
        echo "✓  Memory pressure is normal."
    fi
    if (( swap_pct >= 60 )); then
        echo "⚠  Swap is ${swap_pct}% full — the kernel has been evicting a lot of app memory."
    fi
    echo
}

# Print top processes, aggregated per application family: all renderer/helper
# children of chrome/feishu/cursor roll into one row for their parent app.
print_top() {
    local n=$1
    echo "=== Top ${n} memory consumers (aggregated by application) ==="
    printf '%-26s %10s %8s   %s\n' 'APPLICATION' 'TOTAL_MB' 'PROCS' 'EXAMPLE COMMAND'
    local tmpf
    tmpf=$(mktemp)
    # Line format from ps: rss(kb) comm args-with-spaces. Strip rss and comm,
    # family() classifies by binary path in the remaining args blob.
    ps -eo rss=,comm=,args= --sort=-rss |
    awk '
        function family(args, comm,    f) {
            if      (args ~ /\/opt\/google\/chrome\/chrome/)    f = "google-chrome"
            else if (args ~ /\/usr\/share\/cursor\/cursor/)     f = "cursor"
            else if (args ~ /\/opt\/bytedance\/feishu\/feishu/) f = "feishu"
            else if (args ~ /A-server\.jar/)                    f = "bazel-server"
            else if (args ~ /^\/proc\/self\/exe/)               f = "jash-jsruntime"
            else                                                f = comm
            return f
        }
        {
            rss = $1; comm = $2
            sub(/^[ ]*[0-9]+[ ]+[^ ]+[ ]+/, "", $0)   # strip rss and comm, keep args
            f = family($0, comm)
            tot[f] += rss; cnt[f]++
            if (!(f in ex)) ex[f] = $0
        }
        END {
            for (f in tot) printf "%.0f\t%s\t%d\t%s\n", tot[f]/1024, f, cnt[f], substr(ex[f],1,90)
        }
    ' | sort -rn > "$tmpf"
    local -a rows
    mapfile -t rows < "$tmpf"
    rm -f "$tmpf"
    local row i
    for (( i=0; i<n && i<${#rows[@]}; i++ )); do
        row=${rows[i]}
        IFS=$'\t' read -r mb name procs ex <<<"$row"
        printf '%-26s %10s %8s   %s\n' "$name" "$mb" "$procs" "$ex"
    done
    echo
}

print_swap_consumers() {
    echo "=== Top swap consumers (over 50 MB) ==="
    local lines=0
    local out
    out=$(for f in /proc/[0-9]*/status; do
        [[ -r $f ]] || continue
        local pid=${f#/proc/}; pid=${pid%/status}
        local name swap
        name=$(awk '/^Name:/{print $2}' "$f" 2>/dev/null) || continue
        swap=$(awk '/^VmSwap:/{print $2}' "$f" 2>/dev/null) || continue
        [[ -n $swap && $swap -gt 51200 ]] || continue
        printf '%8d MB  %-20s (pid %s)\n' $(( swap / 1024 )) "$name" "$pid"
    done | sort -rn)
    if [[ -n $out ]]; then
        printf '%s\n' "$out"
        lines=1
    fi
    (( lines )) || echo '  (no process is using significant swap)'
    echo
}

print_recommendations() {
    cat <<'EOF'
=== Recommendations ===
 1. Chrome: enable Memory Saver (chrome://settings/performance) and close
    dormant tabs — each renderer tab holds 370-450 MB.
 2. Cursor: close unused project windows; renderers hold 380-650 MB each.
 3. Feishu: its backend accumulates memory over days. Quitting and relaunching
    reclaims 1.5-2 GB:  ./memopt.sh --restart feishu
 4. Bazel: idle server JVMs are safe to stop (rebuilt automatically on next
    build):  ./memopt.sh --stop-bazel   (or add --max_idle_secs=1800 to bazelrc)
 5. Swap: if swap stays >60% full, consider zram or a larger swapfile (needs
    root + reboot):  sudo apt install zram-tools   # or fallocate a bigger swapfile
 6. Restart Chrome (closes all tabs — bookmark/unsaved data may be lost):
    ./memopt.sh --restart chrome
EOF
    echo
}

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------

find_user_pids() { # find_user_pids <exact binary path or pattern...> -> pids on stdout
    local -a patterns=("$@")
    local pids="" pid cmd
    for pid in $(ps -u "$USER" -o pid= 2>/dev/null); do
        cmd=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") || continue
        [[ -n $cmd ]] || continue
        local pat
        for pat in "${patterns[@]}"; do
            # shellcheck disable=SC2254  # pattern is intentionally glob-matched
            case $cmd in
                $pat) pids+="${pids:+ }$pid"; break ;;
            esac
        done
    done
    echo "$pids"
}

proc_cpu_jiffies() { # total CPU jiffies of a pid
    awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0
}

is_idle() { # is_idle <pid> -> 0 if CPU delta over 2s is < 5% of one core
    [[ -r /proc/$1/stat ]] || return 1
    local j1 j2
    j1=$(proc_cpu_jiffies "$1")
    sleep 2
    j2=$(proc_cpu_jiffies "$1")
    local hz
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    # idle = less than 5% of one core over the 2s sample => < 0.1 * hz jiffies
    (( (j2 - j1) * 10 < hz ))
}

action_stop_bazel() {
    echo '=== Stopping idle bazel server ==='
    # Match the bazel server JVM (A-server.jar) regardless of how it was invoked.
    local pids
    pids=$(find_user_pids '*A-server.jar*')
    if [[ -z $pids ]]; then
        echo '  No bazel server running — nothing to do.'
        return 0
    fi
    local pid stopped=0
    for pid in $pids; do
        if is_idle "$pid"; then
            run_or_dry "stopping idle bazel server (pid $pid)" kill "$pid"
            stopped=1
        else
            echo "  pid $pid is actively building — leaving it alone."
        fi
    done
    if (( stopped )) && (( ! DRY_RUN )); then
        log "stopped idle bazel server pids: $pids"
    fi
    echo
}

action_clean_caches() {
    echo '=== Dropping page cache ==='
    echo '  This frees file cache the kernel would release on demand anyway.'
    echo '  Value is usually small; effects last seconds. Requires sudo.'
    confirm 'Drop page cache now?' || { echo '  skipped.'; echo; return 0; }
    if [[ $DRY_RUN -eq 1 ]]; then
        echo '[dry-run] $ sync && sudo tee /proc/sys/vm/drop_caches <<< 1'
    else
        sync
        echo 1 | sudo tee /proc/sys/vm/drop_caches >/dev/null
        log 'dropped page cache'
        echo '  done.'
    fi
    echo
}

action_trim_swap() {
    echo '=== Trimming swap (off/on cycle) ==='
    read -r _ avail_kb _ _ swap_used_kb <<<"$(mem_fields)"
    local avail_mb=$(( avail_kb / 1024 )) swap_mb=$(( swap_used_kb / 1024 ))
    if (( swap_mb == 0 )); then
        echo '  Swap is empty — nothing to trim.'
        echo; return 0
    fi
    local need_mb=$(( swap_mb + swap_mb / 5 ))   # swap used + 20% margin
    if (( avail_mb < need_mb )); then
        echo "  NOT SAFE: ${avail_mb} MB available but ${need_mb} MB needed to"
        echo '  pull all swap back into RAM. Free memory first (restart apps),'
        echo '  then retry.'
        echo; return 1
    fi
    confirm "Cycle swap off/on to force stale pages back into RAM (${swap_mb} MB)?" \
        || { echo '  skipped.'; echo; return 0; }
    if [[ $DRY_RUN -eq 1 ]]; then
        echo '[dry-run] $ sudo swapoff -a && sudo swapon -a'
    else
        echo '  this can take a minute...'
        sudo swapoff -a
        sudo swapon -a
        log "trimmed swap (${swap_mb} MB cycled)"
        echo '  done — stale swap pages are back in RAM and swap is empty.'
    fi
    echo
}

# app definitions for --restart: <binary-path> <launch-command>
APP_CHROME=('/opt/google/chrome/chrome' '/opt/google/chrome/chrome')
APP_FEISHU=('/opt/bytedance/feishu/feishu' '/opt/bytedance/feishu/feishu')
APP_CURSOR=('/usr/share/cursor/cursor' '/usr/share/cursor/cursor')

action_restart_app() {
    local app=$1
    local -a def
    case $app in
        chrome) def=("${APP_CHROME[@]}");;
        feishu) def=("${APP_FEISHU[@]}");;
        cursor) def=("${APP_CURSOR[@]}");;
        *) die "unknown app '$app' (choose: chrome, feishu, cursor)";;
    esac
    local binary=${def[0]} launcher=${def[1]}

    echo "=== Graceful restart: $app ==="
    echo '  ⚠  Unsaved state in this application may be lost.'
    local pids
    pids=$(find_user_pids "$binary*")
    if [[ -z $pids ]]; then
        echo "  $app is not running — starting it fresh."
    else
        local total_rss
        total_rss=$(ps -o rss= -p "$pids" 2>/dev/null | awk '{s+=$1} END {print int(s/1024)}')
        echo "  currently using ~${total_rss:-?} MB across $(wc -w <<<"$pids") processes."
        confirm "Send SIGTERM to all $app processes and relaunch?" \
            || { echo '  skipped.'; echo; return 0; }
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] kill (SIGTERM) pids: $pids"
        echo "[dry-run] wait up to 15s, then launch: setsid $launcher &"
        echo; return 0
    fi

    if [[ -n $pids ]]; then
        # shellcheck disable=SC2086  # pids is a whitespace-separated list on purpose
        kill $pids 2>/dev/null || true
        local i=0
        while (( i < 15 )); do
            pgrep -u "$USER" -f "$binary" >/dev/null 2>&1 || break
            sleep 1; i=$((i+1))
        done
        if pgrep -u "$USER" -f "$binary" >/dev/null 2>&1; then
            echo "  some processes ignored SIGTERM after 15s — leaving them (no SIGKILL)."
            echo "  Aborting relaunch to avoid two instances; close them manually and retry."
            log "$app restart aborted: processes survived SIGTERM: $pids"
            return 1
        fi
        log "$app stopped gracefully: $pids"
    fi

    echo "  launching $app..."
    setsid "$launcher" >/dev/null 2>&1 < /dev/null &
    disown    log "$app relaunched"
    echo '  done.'
    echo
}

action_watch() {
    echo "Watch mode: reporting every ${WATCH_INTERVAL}s, alerting below ${WATCH_THRESHOLD}% available. Ctrl-C to stop."
    while true; do
        {
            date '+%H:%M:%S'
            print_summary
        } | tr -s '\n'
        local total_kb avail_mb total_mb pct
        read -r total_kb avail_kb _ _ _ <<<"$(mem_fields)"
        total_mb=$(( total_kb / 1024 )); avail_mb=$(( avail_kb / 1024 ))
        (( total_mb > 0 )) && pct=$(( avail_mb * 100 / total_mb )) || pct=100
        if (( pct < WATCH_THRESHOLD )); then
            echo "⚠ ALERT: only ${pct}% available — consider: ./memopt.sh --restart feishu"
            log "ALERT: low memory (${pct}% available)"
        fi
        sleep "$WATCH_INTERVAL"
    done
}

action_install_timer() {
    echo '=== Installing daily-report systemd user timer ==='
    local src_dir destination
    src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/systemd"
    destination=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
    if [[ ! -f $src_dir/memopt-report.timer ]]; then
        die "systemd units not found next to script (expected $src_dir)"
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] cp $src_dir/*.service $src_dir/*.timer -> $destination"
        echo '[dry-run] systemctl --user daemon-reload && systemctl --user enable --now memopt-report.timer'
        return 0
    fi
    mkdir -p "$destination"
    local abs_script
    abs_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/memopt.sh"
    sed "s|__MEMOPT_PATH__|$abs_script|" \
        "$src_dir"/memopt-report.service > "$destination"/memopt-report.service
    cp "$src_dir"/memopt-report.timer "$destination/"
    systemctl --user daemon-reload
    systemctl --user enable --now memopt-report.timer
    log 'installed and enabled memopt-report.timer'
    echo '  installed and enabled. Reports run daily; view with:'
    echo '    journalctl --user -u memopt-report.service'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

usage() {
    sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

main() {
    local mode=auto
    while (( $# )); do
        case $1 in
            --report)      mode="report";;
            --stop-bazel)  mode="stop-bazel";;
            --clean)       mode="clean";;
            --trim-swap)   mode="trim-swap";;
            --restart)     mode="restart"; shift; RESTART_APP=${1:?--restart needs an app: chrome|feishu|cursor};;
            --watch)       mode="watch"; [[ ${2:-} =~ ^[0-9]+$ ]] && { WATCH_INTERVAL=$2; shift; };;
            --install-timer) mode="install-timer";;
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
        report)       print_summary; print_top "$TOP_N"; print_swap_consumers; print_recommendations;;
        stop-bazel)   action_stop_bazel;;
        clean)        action_clean_caches;;
        trim-swap)    action_trim_swap;;
        restart)      action_restart_app "$RESTART_APP";;
        watch)        action_watch;;
        install-timer) action_install_timer;;
        auto)
            print_summary
            print_top "$TOP_N"
            print_swap_consumers
            action_stop_bazel
            echo '--- after safe actions ---'
            print_summary
            print_recommendations
            ;;
        *) die "internal error: bad mode $mode";;
    esac
}

main "$@"
