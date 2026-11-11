package app.pepehub.pepehub

import android.app.Activity
import android.os.Build
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Text reader window: page turning with the volume buttons and the optional
 * phone navigation bar (back / home / recents) while the status bar stays
 * hidden. Flutter re-applies its own immersive mode on resume, so the
 * navigation bar is restored by [reapply].
 */
class ReaderWindowChannel(activity: Activity, messenger: BinaryMessenger) {
    private var owner = WeakReference(activity)
    private val channel = MethodChannel(messenger, "pepehub/reader-window")
    private var volumeKeys = false
    private var navigationBar = false

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "configure" -> {
                        val arguments = call.arguments as? Map<*, *> ?: error("Expected reader window settings")
                        volumeKeys = arguments["volumeKeys"] == true
                        val wasShown = navigationBar
                        navigationBar = arguments["navigationBar"] == true
                        if (navigationBar || wasShown) applyBars()
                        result.success(null)
                    }
                    "reset" -> {
                        // The reader is closing: the app returns to its usual bars.
                        volumeKeys = false
                        navigationBar = false
                        if (Build.VERSION.SDK_INT >= 30) {
                            owner.get()?.window?.insetsController?.show(WindowInsets.Type.systemBars())
                        }
                        result.success(null)
                    }
                    "shareText" -> {
                        val text = (call.arguments as? String)?.take(100_000) ?: error("Нет текста")
                        val activity = owner.get() ?: error("Откройте приложение")
                        val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(android.content.Intent.EXTRA_TEXT, text)
                        }
                        activity.startActivity(android.content.Intent.createChooser(send, "Поделиться"))
                        result.success(null)
                    }
                    "battery" -> {
                        val manager = owner.get()?.getSystemService(android.content.Context.BATTERY_SERVICE) as? android.os.BatteryManager
                        val level = manager?.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
                        result.success(if (level !in 0..100) null else mapOf("level" to level, "charging" to (manager?.isCharging == true)))
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("reader_window", e.message, null) }
        }
    }

    /** Consumes both the press and the release so the volume does not change. */
    fun handleKey(event: KeyEvent): Boolean {
        if (!volumeKeys) return false
        val direction = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_DOWN -> 1
            KeyEvent.KEYCODE_VOLUME_UP -> -1
            else -> return false
        }
        if (event.action == KeyEvent.ACTION_DOWN) channel.invokeMethod("volumeKey", direction)
        return true
    }

    fun attach(activity: Activity) { owner = WeakReference(activity) }
    fun detach(activity: Activity) { if (owner.get() === activity) owner.clear() }

    fun reapply() {
        if (!navigationBar) return
        owner.get()?.window?.decorView?.post { runCatching { applyBars() } }
    }

    @Suppress("DEPRECATION")
    private fun applyBars() {
        val window = owner.get()?.window ?: return
        if (Build.VERSION.SDK_INT >= 30) {
            val controller = window.insetsController ?: return
            controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsets.Type.statusBars())
            if (navigationBar) controller.show(WindowInsets.Type.navigationBars())
            else controller.hide(WindowInsets.Type.navigationBars())
        } else {
            var flags = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            if (!navigationBar) flags = flags or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            window.decorView.systemUiVisibility = flags
        }
    }

    fun dispose() {
        volumeKeys = false
        navigationBar = false
        channel.setMethodCallHandler(null)
        owner.clear()
    }
}
