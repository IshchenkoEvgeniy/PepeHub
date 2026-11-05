package app.pepehub.pepehub

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar

class ReminderChannel(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "app.pepehub/reminders")
    private var owner = java.lang.ref.WeakReference<Activity>(null)
    private var pending: MethodChannel.Result? = null
    private var pendingConfig: Map<String, Any?>? = null
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "configure") { result.notImplemented(); return@setMethodCallHandler }
            try {
                val config = call.arguments as? Map<*, *> ?: error("Нет настроек")
                val minute = (config["minute"] as? Number)?.toInt() ?: error("Нет времени")
                check(minute in 0..1439) { "Некорректное время" }
                val values = mapOf("enabled" to (config["enabled"] == true), "minute" to minute,
                    "body" to (config["body"] as? String ?: "Проверьте цель и план чтения").take(800))
                if (values["enabled"] == true && Build.VERSION.SDK_INT >= 33 &&
                    context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                    check(config["requestPermission"] == true) { "Разрешите уведомления PepeHub в настройках Android" }
                    check(pending == null) { "Дождитесь ответа на разрешение" }
                    val activity = owner.get() ?: error("Откройте приложение")
                    pending = result; pendingConfig = values
                    activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION)
                } else { save(values); result.success(null) }
            } catch (e: Exception) {
                if (pending === result) { pending = null; pendingConfig = null }
                result.error("reminder", e.message, null)
            }
        }
    }
    fun attach(activity: Activity) { owner = java.lang.ref.WeakReference(activity) }
    fun detach(activity: Activity) {
        if (owner.get() === activity) {
            owner.clear(); pending?.error("reminder", "Откройте настройки напоминаний повторно", null)
            pending = null; pendingConfig = null
        }
    }
    fun onPermissions(code: Int, grants: IntArray): Boolean {
        if (code != PERMISSION) return false
        val result = pending; val config = pendingConfig
        pending = null; pendingConfig = null
        if (result != null && config != null) {
            try {
                check(grants.isNotEmpty() && grants[0] == PackageManager.PERMISSION_GRANTED) { "Уведомления не разрешены" }
                save(config); result.success(null)
            } catch (e: Exception) { result.error("reminder", e.message, null) }
        }
        return true
    }
    private fun save(values: Map<String, Any?>) {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (values["enabled"] == true) check(manager.areNotificationsEnabled()) { "Включите уведомления PepeHub в настройках Android" }
        ReminderReceiver.preferences(context).edit().putBoolean("enabled", values["enabled"] == true)
            .putInt("minute", values["minute"] as Int).putString("body", values["body"] as String).apply()
        ReminderReceiver.schedule(context)
        if (values["enabled"] != true) manager.cancel(ReminderReceiver.ID)
    }
    fun dispose() { pending?.error("closed", "Настройки закрыты", null); pending = null; pendingConfig = null; channel.setMethodCallHandler(null) }
    companion object { const val PERMISSION = 46812 }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val prefs = preferences(context)
        if (!prefs.getBoolean("enabled", false)) return
        if (intent.action == ACTION) {
            val manager = context.getSystemService(NotificationManager::class.java)
            val day = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.ROOT).format(java.util.Date())
            if (manager.areNotificationsEnabled() && prefs.getString("lastDay", null) != day) {
                if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
                    NotificationChannel(CHANNEL, "Цели и планы чтения", NotificationManager.IMPORTANCE_DEFAULT))
                val launch = PendingIntent.getActivity(context, ID, Intent(context, MainActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else Notification.Builder(context)
                val text = prefs.getString("body", "Проверьте цель и план чтения")!!
                try {
                    manager.notify(ID, builder.setSmallIcon(R.drawable.ic_audio_notification).setContentTitle("PepeHub · время для книги")
                        .setContentText(text).setStyle(Notification.BigTextStyle().bigText(text))
                        .setContentIntent(launch).setAutoCancel(true).build())
                    prefs.edit().putString("lastDay", day).apply()
                } catch (_: SecurityException) {
                    // The permission can be revoked while this broadcast is running.
                }
            }
        }
        schedule(context)
    }
    companion object {
        const val ID = 46813
        const val ACTION = "app.pepehub.REMINDER"
        const val CHANNEL = "pepehub-goals"
        fun preferences(context: Context) = context.getSharedPreferences("goal-reminder-v1", Context.MODE_PRIVATE)
        fun schedule(context: Context) {
            val alarm = context.getSystemService(AlarmManager::class.java)
            val operation = PendingIntent.getBroadcast(context, ID, Intent(context, ReminderReceiver::class.java).setAction(ACTION),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            alarm.cancel(operation)
            val prefs = preferences(context)
            if (!prefs.getBoolean("enabled", false)) return
            val minute = prefs.getInt("minute", 1200)
            val next = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, minute / 60); set(Calendar.MINUTE, minute % 60)
                set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                if (timeInMillis <= System.currentTimeMillis()) add(Calendar.DAY_OF_YEAR, 1)
            }
            // Inexact reminders need no exact-alarm permission and survive Doze.
            alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next.timeInMillis, operation)
        }
    }
}
