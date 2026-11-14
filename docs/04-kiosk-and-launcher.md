# 4. Build, install & configure the kiosk

Build the APK as in [kiosk/README.md](../kiosk/README.md), then:

```sh
adb install -r kiosk/build/homehq.apk
adb shell am start -n com.wesbos.homehq/.MainActivity --es url https://your-dashboard/
```

## Screen on/off schedule & screensaver

An unprivileged app can't sleep the display, but these frames grant root freely, so the kiosk's
`ScreenScheduleReceiver` does a **true** display off/on via `su -c 'input keyevent 26'` (sleep) and
`224` (wake), fired by `AlarmManager` (RTC_WAKEUP). Set the hours and turn the idle screensaver off:

```sh
adb shell am start -n com.wesbos.homehq/.MainActivity \
  --ei screen_on_hour 8 --ei screen_on_min 0 \
  --ei screen_off_hour 22 --ei screen_off_min 0 --ez screensaver false
```

- Verify in the log: `adb logcat -d | grep -i 'Screen schedule'` → `on 08:00, off 22:00`.
- `--ez screen_schedule false` turns it off (screen stays on 24/7).
- **AlarmManager alarms don't survive a reboot** — the kiosk re-arms them each time it starts,
  which is why making it the Home app (next section) also keeps the schedule alive across reboots.
- Manual control any time: `adb shell input keyevent 26` (off) / `224` (on). While off, touching
  the panel does **not** wake these frames — use `224`.
- The backlight sysfs (`/sys/class/backlight/rk28_bl/*`) is kernel read-only here, so the keyevent
  path is the way to a real off; `screenBrightness = 0` only dims an LCD.

## The screen goes dark after 30 minutes

Stock Android's **display inactivity timeout** is set to **30 minutes**
(`screen_off_timeout=1800000`) on these frames, and **nothing in the kiosk keeps the display
awake** — there is no `FLAG_KEEP_SCREEN_ON` or wake lock anywhere in the app. A wall-mounted
frame gets no touch input, so the idle timer simply expires and the panel goes dark about half
an hour after boot.

This surprises people because it only starts *after* you replace Frameo: the Frameo app held the
screen on itself, so swapping it for the kiosk exposes a timeout that was always configured.

Disable it:

```sh
# Effectively never time out (max int ms, ~24.8 days)
adb shell settings put system screen_off_timeout 2147483647

# Belt and braces: stay awake whenever powered (these frames report AC powered)
adb shell settings put global stay_on_while_plugged_in 7
```

Both are stored in the settings provider and survive reboots. Confirm they took effect:

```sh
adb shell settings get system screen_off_timeout        # 2147483647
adb shell settings get global stay_on_while_plugged_in  # 7
adb shell dumpsys power | grep -E 'mStayOn|mScreenOffTimeoutSetting'
```

`stay_on_while_plugged_in` is a bitmask — `1` AC, `2` USB, `4` wireless, `7` all. It only works
if the frame reports as powered; check with `adb shell dumpsys battery` (`AC powered: true`,
`mPlugType=1`).

**These settings do not break the nightly schedule.** A stay-awake device still honours an
explicit `keyevent 26`: tested with `mStayOn=true`, the display went to `Asleep`/`OFF` and stayed
off, with `keyevent 224` waking it normally. So the schedule above remains the only thing that
turns the panel off.

### Why not `FLAG_KEEP_SCREEN_ON`?

The obvious "proper kiosk" fix — adding `FLAG_KEEP_SCREEN_ON` to the activity — is deliberately
**not** used here. It holds a screen-bright wake lock while the window is visible, which fights
the nightly `keyevent 26` sleep, and it needs an APK rebuild. The two settings above are
one-liners with no such conflict.

### Predicting exactly when it will sleep

`dumpsys power` exposes the idle timer, which makes this diagnosable rather than guesswork:

```sh
adb shell dumpsys power | grep -E 'mLastUserActivityTime|mScreenOffTimeoutSetting|mWakefulness'
```

`mLastUserActivityTime` is on the elapsed-realtime clock; add `mScreenOffTimeoutSetting` to it to
get the moment the display will go off. A wake (`keyevent 224`, or boot) resets that timer.

If the screen is going off and you want to know *what* did it, rule out the candidates in this
order — on the unit this was written against, only the last one was guilty:

| Suspect | How to check |
|---|---|
| Frameo running in the background | `adb shell ps \| grep frameo` — if there is no process, it isn't Frameo |
| The kiosk's idle screensaver | `--ez screensaver false`, or check `screensaver` in `/data/data/com.wesbos.homehq/shared_prefs/kiosk.xml` |
| The kiosk's nightly schedule | `adb shell dumpsys alarm \| grep -i homehq` — fires once daily, can't explain a 30-minute delay |
| Something holding a wake lock | `adb shell dumpsys power \| grep -i 'Wake Locks'` — `size=0` means nothing is held |
| **Stock inactivity timeout** | **`adb shell settings get system screen_off_timeout`** |

## Timezone (Android 6)

```sh
adb shell su -c 'setprop persist.sys.timezone Europe/Amsterdam; service call alarm 3 s16 Europe/Amsterdam'
adb shell am force-stop com.wesbos.homehq && adb shell am start -n com.wesbos.homehq/.MainActivity
```

The property persists across reboots. Restart the kiosk so the page picks up the new zone.

Check what the device thinks the time is, and whether it agrees with a known-good clock:

```sh
adb shell 'date; date +%s'; date +%s      # compare the two epochs - should match
adb shell getprop persist.sys.timezone
adb shell settings get global auto_time       # 1 = keep the clock NTP-synced
adb shell settings get global auto_time_zone  # 0 is fine, see below
```

### Daylight saving changes on their own

**You don't need to do anything for summer/winter time.** DST is encoded *inside* the zone, so
`Europe/Amsterdam` switches by itself; `auto_time_zone=0` does not prevent it. That setting only
controls whether the network may change *which zone* the device is in — which you don't want on a
fixed-location frame anyway.

You can verify it against the frame's own data rather than taking it on faith. Pull the device's
timezone database and ask it directly:

```sh
adb pull /system/usr/share/zoneinfo/tzdata .
python3 - <<'PY'
import struct, io, datetime
from zoneinfo import ZoneInfo
b = open("tzdata","rb").read()
print("version:", b[:12].rstrip(b"\0").decode())          # e.g. tzdata2016a
idx, data, _ = struct.unpack(">III", b[12:24])
zone = "Europe/Amsterdam"                                  # <- your zone
for o in range(idx, data, 52):                             # 40b name + 3x uint32
    if b[o:o+40].rstrip(b"\0").decode() == zone:
        off, length, _ = struct.unpack(">III", b[o+40:o+52])
        z = ZoneInfo.from_file(io.BytesIO(b[data+off:data+off+length]), key=zone)
        for d in (datetime.datetime(2027,3,27,12), datetime.datetime(2027,3,28,12),
                  datetime.datetime(2027,7,1,12), datetime.datetime(2027,10,31,12)):
            a = d.replace(tzinfo=z)
            print(f"  {d:%Y-%m-%d}: {a.tzname():5s} UTC{a.utcoffset()}")
PY
```

On the unit this was written against (`tzdata2016a`) that prints CET before 2027-03-28, **CEST
after it**, and CET again from 2027-10-31 — i.e. the transitions are present and will be applied.

The **schedule survives the change too.** `MainActivity.scheduleOne` arms each alarm from a
wall-clock minute-of-day and rolls it forward with `Calendar.add(Calendar.DAY_OF_MONTH, 1)`, which
is calendar-field arithmetic that preserves wall-clock time across a DST boundary. (A fixed
`+ 86400000` would have put a 22:00 alarm at 23:00 on the transition day — that is the bug to
avoid if you rewrite this.) `ScreenScheduleReceiver` also re-arms from the saved minute-of-day
after every firing, so the schedule recomputes daily and self-corrects regardless.

Two caveats:

- **Avoid schedule times in the skipped hour.** On spring-forward day 02:00–02:59 local does not
  exist; `Calendar` in lenient mode rolls such a time into 03:xx. The 08:00/22:00 defaults are
  nowhere near it.
- An old `tzdata` is fine because the EU rule (last Sunday in March/October) is recurring and
  already baked in. Only a *rule change* — e.g. the EU abolishing DST — would require updating
  `tzdata`, which Android 6 will never receive by itself.

## Make it the Home launcher (boot to dashboard)

This replaces Frameo as the launcher so a power-cycle lands on your dashboard.

**This Android 6 build has no `cmd` and no `pm set-home-activity`**, so the usual scripted methods
don't exist. Use the Home chooser instead — it still works even though SystemUI is disabled:

```sh
# 1) Enable the kiosk's Home alias (the shell can't enable a component of a release app; the app does it)
adb shell am start -n com.wesbos.homehq/.MainActivity --ez home true

# 2) Trigger the Home chooser
adb shell am start -a android.intent.action.MAIN -c android.intent.category.HOME
```

A **"Select a Home app"** dialog appears with *Home HQ* and *Frameo* and **JUST ONCE / ALWAYS**
buttons. Tap **Home HQ**, then **ALWAYS** — on the panel, or by screenshotting and tapping with
`adb shell input tap <x> <y>` (on a 1366×768 panel the Home HQ row and the ALWAYS button are
roughly at `553 614` and `872 733`; confirm against your own screenshot).

Verify the default stuck, then reboot:

```sh
# The write is delayed ~30s on this firmware — wait, then check before rebooting:
adb exec-out "su -c 'cat /data/system/users/0/package-restrictions.xml'" | grep -A6 '<preferred-activities>'
# want: <item name="com.wesbos.homehq/.Home" ... always="true" ...> with category.HOME
adb reboot
```

After reboot the frame should resume in the kiosk (`dumpsys activity activities | grep mResumedActivity`
→ `com.wesbos.homehq/.Home`). **Frameo stays installed**, just no longer the launcher.

### If Frameo keeps grabbing Home

Some firmware re-asserts Frameo as Home at boot. If that happens, remove Frameo as a Home
candidate with root (reversible):

```sh
adb shell su -c 'pm disable-user --user 0 net.frameo.frame'   # or just its home activity component
# wait ~30s (delayed package-restrictions write) or verify the xml, THEN reboot
```

With the kiosk as the only enabled Home app, Android launches it at boot with no chooser.

## Undo

```sh
# Stop being Home: pick another Home app in Settings, or:
adb shell am start -n com.wesbos.homehq/.MainActivity --ez home false
adb shell su -c 'pm enable net.frameo.frame'      # if you disabled Frameo
adb uninstall com.wesbos.homehq                    # remove the kiosk entirely
```

### Recovery note

Keep ADB (ideally over TCP, [doc 1](01-adb-root-backup.md)) reachable while changing the Home app.
If you end up with no working launcher, ADB + root is your way back in: re-enable Frameo or re-run
the chooser.
