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

## Timezone (Android 6)

```sh
adb shell su -c 'setprop persist.sys.timezone Europe/Amsterdam; service call alarm 3 s16 Europe/Amsterdam'
adb shell am force-stop com.wesbos.homehq && adb shell am start -n com.wesbos.homehq/.MainActivity
```

The property persists across reboots. Restart the kiosk so the page picks up the new zone.

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
