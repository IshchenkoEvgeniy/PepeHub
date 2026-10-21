package app.pepehub.pepehub

import android.app.*
import android.content.Intent
import android.os.IBinder

/** Started only by the visible sync screen; never restarted by a boot receiver. */
class PeerTransferService : Service() {
    private var wake: android.os.PowerManager.WakeLock? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "cancel") { PeerSyncJob.cancelTransfer(); stopSelf(); return START_NOT_STICKY }
        val manager = getSystemService(NotificationManager::class.java)
        if (android.os.Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel("peer_transfer","Синхронизация устройств",NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val cancel = PendingIntent.getService(this,1,Intent(this,PeerTransferService::class.java).setAction("cancel"),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder = if (android.os.Build.VERSION.SDK_INT >= 26) Notification.Builder(this,"peer_transfer") else Notification.Builder(this)
        val notification = builder.setSmallIcon(android.R.drawable.stat_notify_sync).setContentTitle("PepeHub: передача файлов")
            .setContentText("Передача продолжается при свёрнутом приложении").setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null,"Остановить",cancel).build()).build()
        if (android.os.Build.VERSION.SDK_INT >= 29) startForeground(42592,notification,android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(42592,notification)
        if (wake == null) wake = getSystemService(android.os.PowerManager::class.java)
            .newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "PepeHub:peer-transfer").apply { setReferenceCounted(false) }
        wake?.acquire(6 * 60 * 60 * 1000L)
        return START_NOT_STICKY
    }
    override fun onTimeout(startId: Int, fgsType: Int) { PeerSyncJob.cancelTransfer(); stopSelf() }
    override fun onDestroy() { if (wake?.isHeld == true) wake?.release(); wake = null; super.onDestroy() }
}
