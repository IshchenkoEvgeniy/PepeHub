package app.pepehub.pepehub

import android.app.Activity
import android.app.PictureInPictureParams
import android.app.PendingIntent
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.util.Rational
import android.view.WindowManager
import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/** Native immersive bars also work with the edge-to-edge target SDK 36. */
class VideoWindowChannel(activity: Activity, messenger: BinaryMessenger) {
    private var owner = WeakReference(activity)
    private val channel = MethodChannel(messenger, "pepehub/video-window")
    private var fullscreen = false
    private var legacyVisibility: Int? = null
    private var visibleBars: Int? = null
    private var barsBehavior: Int? = null
    private val context = activity.applicationContext
    private val actionName = "${context.packageName}.VIDEO_PIP_CONTROL"
    private var playing = false
    private var visual = false
    private var aspect = 16.0 / 9.0
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == actionName) channel.invokeMethod("pipAction", intent.getStringExtra("command"))
        }
    }
    private fun supportsPip() = Build.VERSION.SDK_INT >= 26 && context.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    init {
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, IntentFilter(actionName), Context.RECEIVER_NOT_EXPORTED)
        else context.registerReceiver(receiver, IntentFilter(actionName))
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                  "getCapabilities" -> result.success(mapOf("pip" to supportsPip(), "miniWindow" to false))
                  "setPlayback" -> {
                    val arguments = call.arguments as? Map<*, *> ?: error("Expected playback parameters")
                    playing = arguments["playing"] == true
                    visual = arguments["visual"] == true
                    aspect = ((arguments["aspectRatio"] as? Number)?.toDouble() ?: aspect).coerceIn(0.5, 2.35)
                    val window = owner.get()?.window
                    if (playing && visual) window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    updatePip()
                    result.success(null)
                  }
                  "enterPip" -> result.success(enterPip())
                  "setFullscreen" -> {
                    check(call.arguments is Boolean) { "Expected a fullscreen boolean" }
                    apply(call.arguments as Boolean)
                    result.success(null)
                  }
                  else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("window", e.message, null) }
        }
    }
    private fun pipParameters(): PictureInPictureParams {
        check(Build.VERSION.SDK_INT >= 26)
        val activity = owner.get() ?: error("Откройте приложение")
        fun action(command: String, icon: Int, title: String, request: Int): RemoteAction {
            val intent = Intent(actionName).setPackage(context.packageName).putExtra("command", command)
            val pending = PendingIntent.getBroadcast(context, request, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            return RemoteAction(Icon.createWithResource(context, icon), title, title, pending)
        }
        val bounds = Rect()
        activity.window.decorView.getGlobalVisibleRect(bounds)
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational((aspect * 1000).toInt(), 1000))
            .setSourceRectHint(bounds)
            .setActions(listOf(action("back", android.R.drawable.ic_media_rew, "Назад на 10 секунд", 4730), action("toggle", if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play, if (playing) "Пауза" else "Смотреть", 4731), action("forward", android.R.drawable.ic_media_ff, "Вперёд на 10 секунд", 4732)))
        if (Build.VERSION.SDK_INT >= 31) builder.setAutoEnterEnabled(playing && visual).setSeamlessResizeEnabled(true)
        return builder.build()
    }
    private fun updatePip() { if (supportsPip() && owner.get() != null) owner.get()?.setPictureInPictureParams(pipParameters()) }
    private fun enterPip(): Boolean {
        if (!supportsPip() || !visual) return false
        val activity = owner.get() ?: return false
        onPipChanged(true)
        return try { activity.enterPictureInPictureMode(pipParameters()).also { if (!it) onPipChanged(false) } }
        catch (e: Exception) { onPipChanged(false); throw e }
    }
    fun onUserLeaveHint() { if (Build.VERSION.SDK_INT in 26..30 && playing && visual) runCatching { enterPip() } }
    fun onPipChanged(enabled: Boolean) { channel.invokeMethod("pipChanged", enabled) }
    fun attach(activity: Activity) {
        if (owner.get() !== activity) {
            legacyVisibility = null
            visibleBars = null
            barsBehavior = null
        }
        owner = WeakReference(activity)
    }
    fun detach(activity: Activity) { if (owner.get() === activity) owner.clear() }
    fun reapply() {
        owner.get()?.window?.decorView?.post {
            if (fullscreen && owner.get() != null) runCatching { apply(true) }
        }
    }

    @Suppress("DEPRECATION")
    private fun apply(enabled: Boolean) {
        if (!enabled && !fullscreen && legacyVisibility == null && visibleBars == null) return
        val activity = owner.get() ?: error("Откройте приложение")
        val window = activity.window
        if (Build.VERSION.SDK_INT >= 30) {
            val controller = window.insetsController ?: error("Окно ещё не готово")
            if (enabled) {
                if (visibleBars == null) {
                    val insets = window.decorView.rootWindowInsets
                    visibleBars = if (insets == null) WindowInsets.Type.systemBars() else
                        intArrayOf(WindowInsets.Type.statusBars(), WindowInsets.Type.navigationBars(), WindowInsets.Type.captionBar())
                            .filter { insets.isVisible(it) }.fold(0) { sum, type -> sum or type }
                    barsBehavior = controller.systemBarsBehavior
                }
                controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(WindowInsets.Type.systemBars())
            } else {
                if (visibleBars != null) {
                    controller.systemBarsBehavior = barsBehavior ?: WindowInsetsController.BEHAVIOR_DEFAULT
                    controller.hide(WindowInsets.Type.systemBars() and visibleBars!!.inv())
                    controller.show(visibleBars!!)
                }
                visibleBars = null
                barsBehavior = null
            }
        } else {
            if (enabled) {
                if (legacyVisibility == null) legacyVisibility = window.decorView.systemUiVisibility
                window.decorView.systemUiVisibility = legacyVisibility!! or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            } else {
                legacyVisibility?.let { window.decorView.systemUiVisibility = it }
                legacyVisibility = null
            }
        }
        fullscreen = enabled
    }
    fun reset() {
        playing = false; visual = false
        owner.get()?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        updatePip()
        if (owner.get() != null) apply(false) else fullscreen = false
    }
    fun dispose() {
        reset()
        channel.setMethodCallHandler(null)
        runCatching { context.unregisterReceiver(receiver) }
        owner.clear()
    }
}
