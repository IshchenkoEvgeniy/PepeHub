package app.pepehub.pepehub

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** One UI engine or one headless engine owns peer sync, never both. */
class PeerBackgroundChannel(contextSource: Context, messenger: BinaryMessenger) {
    private val context = contextSource.applicationContext
    private var owner = java.lang.ref.WeakReference(contextSource as? android.app.Activity)
    private var permission: MethodChannel.Result? = null
    fun attach(activity: android.app.Activity) { owner = java.lang.ref.WeakReference(activity) }
    fun detach(activity: android.app.Activity) {
        if (owner.get() === activity) { owner.clear(); permission?.error("notification", "Откройте экран синхронизации и повторите передачу", null); permission = null }
    }
    val channel = MethodChannel(messenger, "app.pepehub/peer_background")
    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "claimForeground" -> PeerSyncJob.claim(channel, result)
                    "configure" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        val wifi = call.argument<Boolean>("wifiOnly") != false
                        context.getSharedPreferences("peer_background", 0).edit().putBoolean("enabled", enabled).putBoolean("wifiOnly", wifi).apply()
                        val scheduler = context.getSystemService(JobScheduler::class.java)
                        if (!enabled) scheduler.cancel(JOB_ID)
                        else {
                            val builder = JobInfo.Builder(JOB_ID, ComponentName(context, PeerSyncJob::class.java))
                                .setPeriodic(15 * 60 * 1000L)
                                .setRequiredNetworkType(if (wifi) JobInfo.NETWORK_TYPE_UNMETERED else JobInfo.NETWORK_TYPE_ANY)
                                .setPersisted(true)
                            if (android.os.Build.VERSION.SDK_INT >= 26) builder.setRequiresBatteryNotLow(true)
                            val job = builder.build()
                            check(scheduler.schedule(job) == JobScheduler.RESULT_SUCCESS) { "Android отклонил фоновое задание" }
                        }
                        result.success(null)
                    }
                    "startTransfer" -> {
                        if (android.os.Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                            check(permission == null) { "Запрос уведомлений уже открыт" }
                            val activity = owner.get() ?: error("Откройте приложение для начала передачи")
                            permission = result
                            activity.requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), PERMISSION_ID)
                        } else startTransfer(result)
                    }
                    "stopTransfer" -> { context.stopService(Intent(context, PeerTransferService::class.java)); result.success(null) }
                    "backgroundReport" -> {
                        val prefs = context.getSharedPreferences("peer_background",0)
                        result.success(mapOf("time" to prefs.getLong("lastTime",0).toString(),"result" to prefs.getString("lastResult",null)))
                    }
                    "done" -> {
                        report(context,call.argument<String>("result") ?: "Фоновое задание завершено")
                        result.success(null); PeerSyncJob.completed()
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("peer_background", e.message, null) }
        }
    }
    private fun startTransfer(result: MethodChannel.Result) {
        val intent = Intent(context, PeerTransferService::class.java)
        if (android.os.Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        result.success(null)
    }
    fun onPermissions(code: Int, grants: IntArray): Boolean {
        if (code != PERMISSION_ID) return false
        val result = permission; permission = null
        if (result != null) {
            if (grants.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                try { startTransfer(result) } catch (e: Exception) { result.error("transfer",e.message,null) }
            } else result.error("notification","Для передачи с кнопкой остановки разрешите уведомления PepeHub в настройках Android",null)
        }
        return true
    }
    fun dispose() {
        if (PeerSyncJob.foreground === channel) PeerSyncJob.foreground = null
        channel.setMethodCallHandler(null)
        permission?.error("closed","Движок закрыт",null); permission = null; owner.clear()
    }
    companion object {
        const val JOB_ID = 42591
        private const val PERMISSION_ID = 4782
        fun report(context: Context, text: String) {
            context.getSharedPreferences("peer_background",0).edit().putLong("lastTime",System.currentTimeMillis()).putString("lastResult",text.take(1000)).apply()
        }
    }
}
