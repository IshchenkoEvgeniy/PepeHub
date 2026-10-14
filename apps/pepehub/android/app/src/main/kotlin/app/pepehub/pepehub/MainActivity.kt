package app.pepehub.pepehub

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    companion object {
        private val channels = java.util.WeakHashMap<FlutterEngine, AudioFolderChannel>()
        private val bookChannels = java.util.WeakHashMap<FlutterEngine, BookFileChannel>()
        private val videoChannels = java.util.WeakHashMap<FlutterEngine, VideoFilesChannel>()
        private val videoWindowChannels = java.util.WeakHashMap<FlutterEngine, VideoWindowChannel>()
    }
    private var folders: AudioFolderChannel? = null
    private var books: BookFileChannel? = null
    private var videos: VideoFilesChannel? = null
    private var videoWindow: VideoWindowChannel? = null
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
        videos = videoChannels[flutterEngine] ?: VideoFilesChannel(this, flutterEngine.dartExecutor.binaryMessenger).also { channel ->
            videoChannels[flutterEngine] = channel
            flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() {}
                override fun onEngineWillDestroy() { channel.dispose(); videoChannels.remove(flutterEngine) }
            })
        }
        videos?.attach(this)
        videoWindow = videoWindowChannels[flutterEngine] ?: VideoWindowChannel(this, flutterEngine.dartExecutor.binaryMessenger).also { channel ->
            videoWindowChannels[flutterEngine] = channel
            flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() { channel.reset() }
                override fun onEngineWillDestroy() { channel.dispose(); videoWindowChannels.remove(flutterEngine) }
            })
        }
        videoWindow?.attach(this)
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) videoWindow?.reapply()
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        if (videos?.onActivityResult(requestCode, resultCode, data) != true &&
            folders?.onActivityResult(requestCode, resultCode, data) != true) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
    override fun onUserLeaveHint() {
        videoWindow?.onUserLeaveHint()
        super.onUserLeaveHint()
    }
    override fun onPictureInPictureModeChanged(inPictureInPicture: Boolean, configuration: android.content.res.Configuration) {
        super.onPictureInPictureModeChanged(inPictureInPicture, configuration)
        videoWindow?.onPipChanged(inPictureInPicture)
    }
    override fun onPictureInPictureUiStateChanged(state: android.app.PictureInPictureUiState) {
        super.onPictureInPictureUiStateChanged(state)
        if (android.os.Build.VERSION.SDK_INT >= 35 && state.isTransitioningToPip) videoWindow?.onPipChanged(true)
    }
    override fun onDestroy() {
        folders?.detach(this)
        books?.detach(this)
        videos?.detach(this)
        videoWindow?.detach(this)
        super.onDestroy()
    }
}
