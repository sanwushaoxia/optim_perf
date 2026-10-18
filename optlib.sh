# optlib.sh — shared library for cpuopt.sh / memopt.sh.
# shellcheck shell=bash
#
# Expects the sourcing script to set before sourcing:
#   SCRIPT_NAME  — e.g. cpuopt.sh
#   LOG_FILE     — e.g. ${XDG_DATA_HOME:-$HOME/.local/share}/cpuopt.log
#   ASSUME_YES, DRY_RUN — flags (0/1), settable before or after sourcing
#
# Provides: log, die, confirm, run_or_dry, usage_from_markers,
#           install_timer, parse_common_args

log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    # shellcheck disable=SC2094  # flock + rotate + append on the same fd is intentional
    {
        flock -w 2 8 || true
        # rotate once past 5 MB, keep one previous copy
        if [[ -f $LOG_FILE ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) > 5242880 )); then
            mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
        fi
        echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    } 8>>"$LOG_FILE"
}

die() { echo "error: $*" >&2; exit 1; }

confirm() {
    # confirm <prompt> -> returns 0 if approved
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local reply
    if ! read -r -p "$1 [y/N] " reply </dev/tty 2>/dev/null; then
        echo "  (no tty available — treating as decline)" >&2
        return 1
    fi
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

usage_from_markers() {
    # usage_from_markers — print the help block delimited by
    #   # <<usage ... # usage>>  in the calling script
    local script=${BASH_SOURCE[1]}
    awk '/^# <<usage/{on=1; next} /^# usage>>/{on=0} on{sub(/^# ?/,""); print}' "$script"
    exit 0
}

install_timer() {
    # install_timer <unit-prefix> — install systemd user timer + service
    local prefix=$1
    echo '=== Installing daily-report systemd user timer ==='
    local src_dir destination abs_script
    src_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)/systemd"
    destination=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
    if [[ ! -f $src_dir/$prefix-report.timer ]]; then
        die "systemd units not found next to script (expected $src_dir)"
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] install $src_dir/$prefix-report.{service,timer} -> $destination"
        return 0
    fi
    mkdir -p "$destination"
    abs_script="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)/$SCRIPT_NAME"
    sed "s|__${prefix^^}OPT_PATH__|$abs_script|" \
        "$src_dir"/"$prefix"-report.service > "$destination"/"$prefix"-report.service
    cp "$src_dir"/"$prefix"-report.timer "$destination/"
    systemctl --user daemon-reload
    systemctl --user enable --now "$prefix-report.timer"
    log "installed and enabled $prefix-report.timer"
    echo '  installed and enabled. View reports with:'
    echo "    journalctl --user -u $prefix-report.service"
}

proc_cpu_jiffies() { # proc_cpu_jiffies <pid> -> prints utime+stime jiffies
    # /proc/[pid]/stat field 14/15: comm can contain spaces, so strip the
    # parenthesised comm first before counting fields.
    awk '{
        sub(/^[^)]*\) /, "", $0)
        n = split($0, f, " ")
        # after comm removal, utime is field 12, stime field 13 (1-based, post-state)
        print f[12] + f[13]
    }' "/proc/$1/stat" 2>/dev/null || echo 0
}

proc_pid_alive() { [[ -d /proc/$1 ]] && [[ $(ps -o comm= -p "$1" 2>/dev/null) != "" ]]; }

load_config() {
    # load_config — source ~/.config/perfopt/apps.conf if present.
    # The conf can override: APP_CHROME/APP_FEISHU/APP_CURSOR arrays and
    # FAMILY_RULES (whitespace-separated "name:ERE" pairs, longest match wins).
    local conf=${XDG_CONFIG_HOME:-$HOME/.config}/perfopt/apps.conf
    # explicit if/return 0: `[[ -f ]] && source` returning false would trip
    # the caller's set -e
    if [[ -f $conf ]]; then
        source "$conf"
    fi
    return 0
}

parse_common_args() {
    # parse_common_args -- handles: --watch, --top, --threshold, --yes,
    # --dry-run, -h/--help. Sets WATCH_INTERVAL, TOP_N, WATCH_THRESHOLD,
    # ASSUME_YES, DRY_RUN; MAY set MODE=watch / MODE=help.
    # Usage: parse_common_args "$@" ; remaining args in REMAINING_ARGS.
    REMAINING_ARGS=()
    while (( $# )); do
        # shellcheck disable=SC2034  # variables are the library's output contract
        case $1 in
            --watch)     MODE=watch; [[ ${2:-} =~ ^[0-9]+$ ]] && { WATCH_INTERVAL=$2; shift; };;
            --top)       shift; TOP_N="${1:?--top needs a number}";;
            --threshold) shift; WATCH_THRESHOLD="${1:?--threshold needs a percentage}";;
            --yes)       ASSUME_YES=1;;
            --dry-run)   DRY_RUN=1;;
            -h|--help)   MODE=help;;
            *)           REMAINING_ARGS+=("$1");;
        esac
        shift
    done
}
