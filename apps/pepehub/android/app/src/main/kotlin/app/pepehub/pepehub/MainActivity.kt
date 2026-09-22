package app.pepehub.pepehub

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    companion object {
        private val channels = java.util.WeakHashMap<FlutterEngine, AudioFolderChannel>()
        private val bookChannels = java.util.WeakHashMap<FlutterEngine, BookFileChannel>()
    }
    private var folders: AudioFolderChannel? = null
    private var books: BookFileChannel? = null
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState?.getBoolean("bookIntentConsumed") != true) books?.receive(intent)
    }
    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        books?.receive(intent)
    }
    override fun onSaveInstanceState(outState: android.os.Bundle) {
        outState.putBoolean("bookIntentConsumed", true)
        super.onSaveInstanceState(outState)
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        folders = channels[flutterEngine] ?: AudioFolderChannel(this, flutterEngine.dartExecutor.binaryMessenger).also { channel ->
            channels[flutterEngine] = channel
            flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() {}
                override fun onEngineWillDestroy() { channel.dispose(); channels.remove(flutterEngine) }
            })
        }
        folders?.attach(this)
        books = bookChannels[flutterEngine] ?: BookFileChannel(this, flutterEngine.dartExecutor.binaryMessenger).also { channel ->
            bookChannels[flutterEngine] = channel
            flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() {}
                override fun onEngineWillDestroy() { channel.dispose(); bookChannels.remove(flutterEngine) }
            })
        }
        books?.attach(this)
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        if (folders?.onActivityResult(requestCode, resultCode, data) != true) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
    override fun onDestroy() {
        folders?.detach(this)
        books?.detach(this)
        super.onDestroy()
    }
}
