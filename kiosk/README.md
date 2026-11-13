# Home HQ kiosk (RK3126 Android 6 build)

Full-screen WebView kiosk that loads a configurable URL. This is **Home HQ** by Wes Bos
(from [wesbos/photo-frame-dashboard](https://github.com/wesbos/photo-frame-dashboard), MIT),
with the changes needed to run on a Frameo RK3126 / Android 6.0.1 frame.

## Changes from upstream

- **API-23 crash fix.** `MainActivity.onCreate` called `ServiceWorkerController.getInstance()`
  (API 24+) unconditionally, which throws on Android 6 and crashes on launch. It's moved into a
  `@TargetApi(N)` method guarded by `Build.VERSION.SDK_INT >= N`. On API 23 only service-worker
  asset interception is skipped — irrelevant for a hosted dashboard.
- **Daily screen on/off schedule.** [`ScreenScheduleReceiver`](src/com/wesbos/homehq/ScreenScheduleReceiver.java)
  is fired by `AlarmManager` (RTC_WAKEUP) and does a true display off/on via root
  (`su -c 'input keyevent 26'` / `224`). Default **08:00 on / 22:00 off**.
- **Screensaver toggle.** The idle dim-overlay screensaver can be turned off; the schedule replaces
  its night role.

## Build

No Gradle — `build.sh` drives the raw Android SDK tools. You need **JDK 17**, Android
**build-tools 34.0.0**, and **platform 34**. A self-contained toolchain works too (portable JDK +
`sdkmanager`), nothing needs root:

```sh
# Example self-contained setup (Linux x64)
curl -sfL -o jdk.tgz "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse"
tar xzf jdk.tgz && export JAVA_HOME="$PWD/$(ls -d jdk-17*)" && export PATH="$JAVA_HOME/bin:$PATH"
curl -sfL -o clt.zip "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
mkdir -p sdk/cmdline-tools && unzip -q clt.zip -d sdk/cmdline-tools && mv sdk/cmdline-tools/cmdline-tools sdk/cmdline-tools/latest
export ANDROID_HOME="$PWD/sdk"
yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_HOME" "build-tools;34.0.0" "platforms;android-34"

# Build
ANDROID_HOME="$ANDROID_HOME" bash build.sh      # -> build/homehq.apk
```

> If your host has no `zip`, `build.sh` stops at the step that inserts `classes.dex` into the APK.
> Either `apt install zip`, or insert it another way (e.g. `jar uf build/base.apk -C build classes.dex`)
> then run `zipalign` and `apksigner` as `build.sh` does.

## Install & configure

```sh
adb install -r build/homehq.apk

# Dashboard URL (saved for later launches)
adb shell am start -n com.wesbos.homehq/.MainActivity --es url https://your-dashboard/

# Screen schedule + disable screensaver
adb shell am start -n com.wesbos.homehq/.MainActivity \
  --ei screen_on_hour 8 --ei screen_on_min 0 \
  --ei screen_off_hour 22 --ei screen_off_min 0 --ez screensaver false

# Turn the schedule off (screen stays on 24/7)
adb shell am start -n com.wesbos.homehq/.MainActivity --ez screen_schedule false
```

Making it the Home launcher (boot to dashboard) is covered in
[../docs/04-kiosk-and-launcher.md](../docs/04-kiosk-and-launcher.md).

## Intent extras

| Extra | Type | Meaning |
|---|---|---|
| `url` | string | Dashboard URL; saved and reused on later launches |
| `screen_on_hour` / `screen_on_min` | int | Daily wake time |
| `screen_off_hour` / `screen_off_min` | int | Daily sleep time |
| `screen_schedule` | bool | `false` disables the schedule |
| `screensaver` | bool | `false` disables the idle screensaver |
| `home` | bool | `true` enables the `.Home` launcher alias |
| `menu_button` | bool | Single-tap menu button (for panels where the 2-finger gesture is flaky) |
| `debug` | bool | WebView remote debugging |
