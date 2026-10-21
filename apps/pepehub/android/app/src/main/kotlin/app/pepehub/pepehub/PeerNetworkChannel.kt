package app.pepehub.pepehub

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Held only while explicit local peer discovery is enabled. */
class PeerNetworkChannel(context: Context, messenger: BinaryMessenger) {
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val channel = MethodChannel(messenger, "app.pepehub/peer_network")
    private var lock: WifiManager.MulticastLock? = null
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "multicast") result.notImplemented()
            else try {
                if (call.argument<Boolean>("enabled") == true && lock == null) {
                    lock = wifi?.createMulticastLock("pepehub-peer-discovery")?.also { it.setReferenceCounted(false); it.acquire() }
                } else if (call.argument<Boolean>("enabled") != true) release()
                result.success(null)
            } catch (_: Exception) { release(); result.error("network", "Локальный поиск Wi-Fi недоступен", null) }
        }
    }
    private fun release() { lock?.let { if (it.isHeld) it.release() }; lock = null }
    fun dispose() { release(); channel.setMethodCallHandler(null) }
}
