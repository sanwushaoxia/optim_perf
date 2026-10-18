#!/usr/bin/env bash
# hdmi-fix.sh — recover the external HDMI monitor when mutter keeps it off.
#
# Root cause (see hdmi-monitor-fix.md): the monitor emits a brief HPD pulse
# ~1.6s after its signal comes up; mutter treats it as an unplug and tears
# down the just-applied configuration. A single apply therefore always
# reverts — apply twice and the second one sticks.
#
# <<usage
# Usage:
#   hdmi-fix.sh [MODE]
#
# Modes:
#   (no args)       dual-monitor apply via Mutter D-Bus, twice (the fix)
#   --status        show connector/enabled/dpms state and xrandr layout
#   --quick         xrandr --output HDMI-1 --auto --right-of eDP-1, retried
#                   once after 3s if mutter reverts it
#   --dry-run       print the D-Bus calls instead of making them
#   -h, --help      this help
#
# Method argument for ApplyMonitorsConfig: 2 = persistent (saved to
# monitors.xml), 1 = temporary. Serial must come from a fresh GetCurrentState.
# usage>>

set -euo pipefail

# shellcheck disable=SC2034  # consumed by optlib.sh log()/install conventions
SCRIPT_NAME="hdmi-fix.sh"
# shellcheck disable=SC2034  # consumed by optlib.sh log()/install conventions
readonly LOG_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/cpuopt.log"
# shellcheck disable=SC2034  # consumed by optlib.sh confirm()/run_or_dry()
ASSUME_YES=0
DRY_RUN=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=optlib.sh
source "$SCRIPT_DIR/optlib.sh"

# monitor topology — adjust here if the setup changes
readonly INTERNAL_CONN="eDP-1"
readonly INTERNAL_MODE="3072x1920@60.001"
readonly EXTERNAL_CONN="HDMI-1"
readonly EXTERNAL_MODE="2560x1440@60.000"
readonly EXTERNAL_X_OFFSET=3072
readonly APPLY_METHOD=2   # 2 = persistent, 1 = temporary

readonly DBUS_DEST="org.gnome.Mutter.DisplayConfig"
readonly DBUS_PATH="/org/gnome/Mutter/DisplayConfig"

mutter_serial() {
    gdbus call --session \
        --dest "$DBUS_DEST" \
        --object-path "$DBUS_PATH" \
        --method "$DBUS_DEST".GetCurrentState \
        | sed 's/^(uint32 \([0-9]*\),.*/\1/'
}

apply_dual() {
    local serial
    serial=$(mutter_serial)
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] gdbus call --session --dest $DBUS_DEST --object-path $DBUS_PATH"
        echo "          --method $DBUS_DEST.ApplyMonitorsConfig <serial> $APPLY_METHOD"
        echo "          \"[(0, 0, 1.0, 0, true,  [('$INTERNAL_CONN', '$INTERNAL_MODE', @a{sv} {})]),"
        echo "            ($EXTERNAL_X_OFFSET, 0, 1.0, 0, false, [('$EXTERNAL_CONN', '$EXTERNAL_MODE', @a{sv} {})])]"
        echo "          \"@a{sv} {}\""
        return 0
    fi
    log "applying dual-monitor config (serial $serial, method $APPLY_METHOD)"
    gdbus call --session \
        --dest "$DBUS_DEST" \
        --object-path "$DBUS_PATH" \
        --method "$DBUS_DEST".ApplyMonitorsConfig \
        "$serial" "$APPLY_METHOD" \
        "[(0, 0, 1.0, 0, true,  [('$INTERNAL_CONN', '$INTERNAL_MODE', @a{sv} {})]),
          ($EXTERNAL_X_OFFSET, 0, 1.0, 0, false, [('$EXTERNAL_CONN', '$EXTERNAL_MODE', @a{sv} {})])]" \
        "@a{sv} {}" >/dev/null
}

action_fix() {
    echo "=== Applying dual-monitor layout ($INTERNAL_CONN + $EXTERNAL_CONN) ==="
    echo "  first apply is expected to be torn down by the monitor's HPD pulse;"
    echo "  the second one sticks."
    apply_dual
    echo '  applied (1/2), waiting 3s for the HPD pulse to pass...'
    sleep 3
    apply_dual
    echo '  applied (2/2).'
    echo
    action_status
}

action_status() {
    echo '=== Display status ==='
    local drm_base="/sys/class/drm/card1-$EXTERNAL_CONN"
    if [[ -d $drm_base ]]; then
        printf '%-12s status=%s enabled=%s dpms=%s\n' "$EXTERNAL_CONN" \
            "$(cat "$drm_base/status" 2>/dev/null || echo '?')" \
            "$(cat "$drm_base/enabled" 2>/dev/null || echo '?')" \
            "$(cat "$drm_base/dpms" 2>/dev/null || echo '?')"
    else
        echo "  $drm_base not found (card index may differ; check /sys/class/drm/)"
    fi
    echo
    if [[ $DRY_RUN -ne 1 ]]; then
        xrandr --query | grep -E "^($INTERNAL_CONN|$EXTERNAL_CONN) " || true
    fi
    echo
}

action_quick() {
    echo '=== Quick fix: xrandr right-of ==='
    echo '  mutter may revert this; it is re-run once after 3s if HDMI goes dark.'
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] xrandr --output $EXTERNAL_CONN --auto --right-of $INTERNAL_CONN"
        return 0
    fi
    xrandr --output "$EXTERNAL_CONN" --auto --right-of "$INTERNAL_CONN"
    sleep 3
    if [[ $(cat "/sys/class/drm/card1-$EXTERNAL_CONN/enabled" 2>/dev/null || echo disabled) != enabled ]]; then
        echo '  reverted — applying again...'
        xrandr --output "$EXTERNAL_CONN" --auto --right-of "$INTERNAL_CONN"
    fi
    echo '  done.'
    echo
}

usage() { usage_from_markers; }

main() {
    local mode=fix
    parse_common_args "$@"
    case ${MODE:-} in
        help) usage;;
    esac
    local -a rest=("${REMAINING_ARGS[@]}")
    if (( ${#rest[@]} > 0 )); then
        case ${rest[0]} in
            --status) mode=status;;
            --quick)  mode=quick;;
            --fix)    mode=fix;;
            *) die "unknown option: ${rest[0]} (see --help)";;
        esac
    fi

    case $mode in
        fix)    action_fix;;
        status) action_status;;
        quick)  action_quick;;
        *) die "internal error: bad mode $mode";;
    esac
}

main "$@"
