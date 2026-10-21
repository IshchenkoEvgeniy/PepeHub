package app.pepehub.pepehub

import android.app.job.JobParameters
import android.app.job.JobService
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** Short, OS-scheduled metadata exchange. Large media requires an explicit transfer. */
class PeerSyncJob : JobService() {
    private var parameters: JobParameters? = null
    private var engine: FlutterEngine? = null
    private var bridge: PeerBackgroundChannel? = null
    private var files: PeerFilesChannel? = null
    private var folders: AudioFolderChannel? = null
    private var network: PeerNetworkChannel? = null
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { cancel() }
    override fun onStartJob(params: JobParameters): Boolean {
        if (!getSharedPreferences("peer_background",0).getBoolean("enabled",false) || running != null) return false
        parameters = params; running = this
        PeerBackgroundChannel.report(applicationContext,"Android запустил фоновое задание; завершение пока не зафиксировано")
        handler.postDelayed(timeout, 2 * 60 * 1000L)
        val ui = foreground
        if (ui != null) {
            ui.invokeMethod("run", null, object : MethodChannel.Result {
                override fun success(value: Any?) { PeerBackgroundChannel.report(applicationContext,(value as? Map<*, *>)?.get("status") as? String ?: "Фоновое задание обработано текущим движком"); finish() }
                override fun error(code: String, message: String?, details: Any?) { PeerBackgroundChannel.report(applicationContext,"Ошибка фонового задания в текущем движке; подробности в журнале"); finish() }
                override fun notImplemented() { PeerBackgroundChannel.report(applicationContext,"Текущий движок ещё не готов к фоновому заданию"); finish() }
            })
        } else {
            try {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext); loader.ensureInitializationComplete(applicationContext, null)
                // Register only the plugins used by the worker. Registering
                // audio_service here can start the UI/audio engine recursively.
                val created = FlutterEngine(applicationContext, null, false); engine = created
                created.plugins.add(com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin())
                created.plugins.add(com.github.dart_lang.jni.JniPlugin())
                created.plugins.add(com.github.dart_lang.jni_flutter.JniFlutterPlugin())
                val messenger = created.dartExecutor.binaryMessenger
                bridge = PeerBackgroundChannel(applicationContext, messenger)
                files = PeerFilesChannel(applicationContext, messenger)
                folders = AudioFolderChannel(applicationContext, messenger)
                network = PeerNetworkChannel(applicationContext, messenger)
                created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "peerBackgroundMain"))
            } catch (_: Exception) { PeerBackgroundChannel.report(applicationContext,"Не удалось запустить фоновый движок Android"); finish() }
        }
        return true
    }
    private fun cancel() {
        PeerBackgroundChannel.report(applicationContext,"Android или открытие интерфейса запросили остановку фонового задания")
        (bridge?.channel ?: foreground)?.invokeMethod("cancel", null)
    }
    private fun finish() {
        if (running !== this) return
        handler.removeCallbacks(timeout)
        files?.dispose(); folders?.dispose(); network?.dispose(); bridge?.dispose()
        engine?.destroy(); engine = null
        parameters?.let { jobFinished(it, false) }; parameters = null; running = null
        val pending = waiting.toList(); waiting.clear(); pending.forEach { it.success(null) }
    }
    override fun onStopJob(params: JobParameters): Boolean { parameters = null; cancel(); return true }
    companion object {
        var foreground: MethodChannel? = null
        private var running: PeerSyncJob? = null
        private val waiting = mutableListOf<MethodChannel.Result>()
        fun claim(channel: MethodChannel, result: MethodChannel.Result) {
            foreground = channel
            val active = running
            if (active?.engine == null) result.success(null)
            else { waiting.add(result); active.cancel() }
        }
        fun completed() { Handler(Looper.getMainLooper()).post { running?.finish() } }
        fun cancelTransfer() { foreground?.invokeMethod("cancel", null) }
    }
}
