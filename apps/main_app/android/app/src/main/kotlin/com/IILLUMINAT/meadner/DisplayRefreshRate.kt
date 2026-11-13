package com.IILLUMINAT.meadner

import android.app.Activity
import android.content.Context
import android.os.Build
import android.view.Display
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Максимальная частота обновления экрана (90/120/144 Гц).
 *
 * Многие прошивки (MIUI, OneOS, OxygenOS и др.) держат приложения на 60 Гц,
 * пока окно явно не попросит режим с большей частотой. Flutter сам подстраивает
 * vsync под текущий режим, поэтому достаточно выбрать режим окна.
 *
 * Настройка хранится в SharedPreferences Flutter (`flutter.` + ключ),
 * чтобы применяться ещё до первого кадра.
 */
object DisplayRefreshRate {
    const val CHANNEL = "meander/display"

    private const val PREFS = "FlutterSharedPreferences"
    private const val PREF_KEY = "flutter.display_high_refresh_rate"

    fun register(messenger: BinaryMessenger, activity: Activity) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInfo" -> {
                    val display = display(activity)
                    result.success(
                        mapOf(
                            "current" to (display?.refreshRate?.toDouble() ?: 60.0),
                            "max" to maxRate(display).toDouble(),
                            "enabled" to isEnabled(activity),
                        ),
                    )
                }
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                        .edit().putBoolean(PREF_KEY, enabled).apply()
                    apply(activity)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun apply(activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val window = activity.window ?: return
        val display = display(activity) ?: return
        val params = window.attributes

        if (isEnabled(activity)) {
            val current = display.mode
            val best = display.supportedModes
                .filter {
                    it.physicalWidth == current.physicalWidth &&
                        it.physicalHeight == current.physicalHeight
                }
                .maxByOrNull { it.refreshRate }
                ?: return
            if (params.preferredDisplayModeId == best.modeId) return
            params.preferredDisplayModeId = best.modeId
            params.preferredRefreshRate = best.refreshRate
        } else {
            if (params.preferredDisplayModeId == 0 && params.preferredRefreshRate == 0f) return
            params.preferredDisplayModeId = 0
            params.preferredRefreshRate = 0f
        }
        window.attributes = params
    }

    private fun isEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(PREF_KEY, true)

    private fun maxRate(display: Display?): Float {
        if (display == null) return 60f
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return display.refreshRate
        val current = display.mode
        return display.supportedModes
            .filter {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight
            }
            .maxOfOrNull { it.refreshRate } ?: display.refreshRate
    }

    @Suppress("DEPRECATION")
    private fun display(activity: Activity): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display
        } else {
            activity.windowManager.defaultDisplay
        }
}
