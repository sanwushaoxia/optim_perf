# External HDMI Monitor Shows Nothing — Problem Analysis & Fix

- **Date:** 2026-09-21
- **Machine:** Lenovo ThinkBook 14 G7 IAH (Ubuntu 24.04.5, kernel 7.0.0-31-generic, GNOME / X11)
- **GPU:** Intel Arrow Lake-P integrated graphics (`i915` driver)
- **Monitor:** AOC Q27B30E, 2560x1440, connected via HDMI

---

## 1. Symptom

The external monitor was connected via HDMI but showed nothing. The laptop screen (eDP-1) worked normally.

Initial suspicion was a display driver problem.

## 2. Diagnosis Summary

Diagnostics were run in read-only mode. Result: **the display driver stack was completely healthy.**

| Check | Result |
|---|---|
| `lspci -nnk` | Intel iGPU present, `i915` driver bound cleanly |
| Kernel log (`journalctl -k -b`) | No GPU errors, no firmware failures, no EDID failures |
| `/sys/class/drm/card1-HDMI-A-1/status` | `connected` — kernel saw the monitor |
| EDID | Read correctly: AOC Q27B30E, serial `2S6S1HA015009`, full mode list |
| `xrandr --query` | Monitor and all modes visible, simply not enabled |
| 30s connector stability poll | Zero link drops, zero spurious hotplug events when idle |

**Conclusion:** hardware, cable, and driver were fine. The monitor was being *deliberately kept off* by the display manager.

## 3. Root Cause (two stacked issues)

### Issue 1 — GNOME had the monitor saved as "disabled"

`~/.config/monitors.xml` (GNOME/mutter's saved monitor configuration) contained:

```xml
<disabled>
  <monitorspec>
    <connector>HDMI-1</connector>
    <vendor>AOC</vendor>
    <product>Q27B30E</product>
    <serial>2S6S1HA015009</serial>
  </monitorspec>
</disabled>
```

The serial matched the live monitor byte-for-byte, so every time it was plugged in, mutter re-applied the saved decision: **output off** (`dpms: Off`, `enabled: disabled`).

### Issue 2 — the monitor emits a brief HPD (hotplug-detect) pulse when its signal first turns on

Instrumented testing caught the exact sequence once the output was enabled:

```
t+0.0s  HDMI enabled, running at 2560x1440   (connected, enabled, dpms On)
t+1.6s  kernel briefly reports "disconnected" for ~0.5s   <-- monitor's HPD pulse
t+2.1s  connector reads "connected" again — but mutter has already
        torn down the configuration and re-asserted "disabled"
```

The monitor drops its hotplug-detect line for about half a second when the signal mode first comes up. Mutter interprets this blip as "monitor unplugged," removes it from the layout, and re-enables the previously saved (disabled) configuration.

This explains both why the monitor got marked disabled in the first place, and why every single "enable" attempt appeared to work for ~1.6 seconds and then revert.

**Ruled out along the way:**

- AweSun remote-desktop (its virtual "None-1" display appears in `monitors.xml`) — pausing all its processes did not stop the revert.
- Kernel-level link flapping — 30 s of 200 ms sampling showed a rock-stable `connected` state when idle.
- Other userspace interference — `dbus-monitor` showed no other process calling `ApplyMonitorsConfig`; the revert was mutter reacting to the kernel hotplug pulse.

## 4. Solution

### Step 1 — Fix the saved configuration

Edit `~/.config/monitors.xml`: replace the `<disabled>` block for HDMI-1 with a second `<logicalmonitor>` so the stored layout is the dual-monitor arrangement (a backup was kept at `~/.config/monitors.xml.bak-hdmi-fix`):

```xml
<logicalmonitor>
  <x>0</x>
  <y>0</y>
  <scale>1</scale>
  <primary>yes</primary>
  <monitor>
    <monitorspec>
      <connector>eDP-1</connector>
      <vendor>CSW</vendor>
      <product>MNE507ZA2-3</product>
      <serial>0x00000000</serial>
    </monitorspec>
    <mode>
      <width>3072</width>
      <height>1920</height>
      <rate>60.001</rate>
    </mode>
  </monitor>
</logicalmonitor>
<logicalmonitor>
  <x>3072</x>
  <y>0</y>
  <scale>1</scale>
  <monitor>
    <monitorspec>
      <connector>HDMI-1</connector>
      <vendor>AOC</vendor>
      <product>Q27B30E</product>
      <serial>2S6S1HA015009</serial>
    </monitorspec>
    <mode>
      <width>2560</width>
      <height>1440</height>
      <rate>60.000</rate>
    </mode>
  </monitor>
</logicalmonitor>
```

### Step 2 — Apply the configuration in the live session (twice)

Plain `xrandr` changes are reverted by mutter, so the change must go through mutter's own D-Bus API (the same path GNOME Settings → Displays uses). Because of the monitor's HPD pulse, **the first apply is always torn down — apply a second time** and it sticks:

```bash
apply_dual() {
  SERIAL=$(gdbus call --session \
    --dest org.gnome.Mutter.DisplayConfig \
    --object-path /org/gnome/Mutter/DisplayConfig \
    --method org.gnome.Mutter.DisplayConfig.GetCurrentState \
    | sed 's/^(uint32 \([0-9]*\),.*/\1/')
  gdbus call --session \
    --dest org.gnome.Mutter.DisplayConfig \
    --object-path /org/gnome/Mutter/DisplayConfig \
    --method org.gnome.Mutter.DisplayConfig.ApplyMonitorsConfig \
    "$SERIAL" 2 \
    "[(0, 0, 1.0, 0, true,  [('eDP-1', '3072x1920@60.001', @a{sv} {})]), \
      (3072, 0, 1.0, 0, false, [('HDMI-1', '2560x1440@60.000', @a{sv} {})])]" \
    "@a{sv} {}"
}
apply_dual   # first attempt: torn down ~1.6 s later by the monitor's HPD pulse
sleep 3
apply_dual   # second attempt: sticks
```

Notes on the API: method `2` = persistent (saved to `monitors.xml`), `1` = temporary, `0` = verify only. The `serial` argument must come from a fresh `GetCurrentState` call — a stale serial is rejected with "The requested configuration is based on stale information".

### Verification

```bash
xrandr --query | grep -E '^(eDP-1|HDMI-1) '
# HDMI-1 connected 2560x1440+3072+0 ...
cat /sys/class/drm/card1-HDMI-A-1/enabled   # -> enabled
cat /sys/class/drm/card1-HDMI-A-1/dpms      # -> On
```

## 5. Quick Fix If It Goes Dark Again

If the monitor is replugged, power-cycled, or the laptop resumes and the screen stays black, the HPD pulse may strike again. Re-enabling once more makes it stick:

```bash
xrandr --output HDMI-1 --auto --right-of eDP-1
```

(If mutter reverts this, run it again after ~3 seconds, or use **Settings → Displays** and re-enable the AOC there — the saved configuration is now the dual-monitor layout, so it will persist.)

## 6. Side Observations

- A phantom virtual display entry (`None-1`, vendor unknown) in `monitors.xml` was created by the **AweSun** remote-desktop app. Harmless, but worth knowing if display oddities appear while AweSun is running.
- The GuC firmware notice (`mtl_guc_70.bin` 70.36.0 vs recommended 70.53.0) is cosmetic — updating `linux-firmware` would silence it, but it was unrelated to this problem.
