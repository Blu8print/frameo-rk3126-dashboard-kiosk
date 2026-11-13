package com.wesbos.homehq;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * Turns the display off at night and on in the morning on a daily schedule (see MainActivity's
 * screen-schedule constants). An ordinary app can't sleep the display itself, so this uses the
 * shipped root (`su -c 'input keyevent 26'` to sleep, `224` to wake) — the frame grants root with
 * no prompt. Declared in the manifest and fired by RTC_WAKEUP alarms, so it runs even while the
 * screen is off and after the process was killed; each firing re-arms the same alarm for the next
 * day (AlarmManager alarms don't survive a reboot — MainActivity re-arms them when it starts).
 */
public class ScreenScheduleReceiver extends BroadcastReceiver {
  static final String ACTION_ON = "com.wesbos.homehq.SCREEN_ON";
  static final String ACTION_OFF = "com.wesbos.homehq.SCREEN_OFF";

  @Override
  public void onReceive(Context ctx, Intent intent) {
    final String action = intent.getAction();
    final boolean on = ACTION_ON.equals(action);
    if (!on && !ACTION_OFF.equals(action)) return;
    final Context app = ctx.getApplicationContext();
    final PendingResult pr = goAsync();
    new Thread(() -> {
      exec(on);
      // Re-arm this alarm for the same time tomorrow.
      MainActivity.scheduleOne(app, action, MainActivity.savedScheduleMinute(app, action));
      pr.finish();
    }).start();
  }

  /** Fire-and-forget true screen on/off via root; safe to call from the UI thread. */
  static void setScreen(boolean on) {
    new Thread(() -> exec(on)).start();
  }

  private static void exec(boolean on) {
    try {
      // keyevent 26 = KEYCODE_POWER (sleep), 224 = KEYCODE_WAKEUP.
      Process p = Runtime.getRuntime().exec(new String[]{"su", "-c", "input keyevent " + (on ? 224 : 26)});
      p.waitFor();
      Log.i(MainActivity.TAG, "Scheduled screen " + (on ? "ON" : "OFF"));
    } catch (Exception e) {
      Log.w(MainActivity.TAG, "Screen " + (on ? "on" : "off") + " failed: " + e);
    }
  }
}
