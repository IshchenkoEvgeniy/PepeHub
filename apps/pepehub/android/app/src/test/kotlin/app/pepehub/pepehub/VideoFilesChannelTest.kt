package app.pepehub.pepehub

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.lang.reflect.Proxy
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 35])
class VideoFilesChannelTest {
    private lateinit var activity: Activity
    private lateinit var channel: VideoFilesChannel
    private lateinit var handler: BinaryMessenger.BinaryMessageHandler
    @Before fun setup() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val messenger = Proxy.newProxyInstance(BinaryMessenger::class.java.classLoader, arrayOf(BinaryMessenger::class.java)) { _, method, args ->
            if (method.name == "setMessageHandler" && args?.get(1) != null) {
                handler = args[1] as BinaryMessenger.BinaryMessageHandler
            }
            null
        } as BinaryMessenger
        channel = VideoFilesChannel(activity, messenger)
    }
    @After fun close() { channel.dispose() }
    private fun request(method: String) {
        val message = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, null))
        message.flip()
        handler.onMessage(message) { }
    }
    @Test fun mediaPickerAcceptsAudioAndVideoWithPersistentReadAccess() {
        request("pickFiles")
        val launched = shadowOf(activity).nextStartedActivityForResult
        assertEquals(4720, launched.requestCode)
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, launched.intent.action)
        assertEquals("*/*", launched.intent.type)
        val types = launched.intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES)!!.toSet()
        assertTrue(types.containsAll(listOf("video/*", "audio/*", "application/ogg", "application/x-flac")))
        assertTrue(launched.intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
        assertTrue(launched.intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        assertTrue(launched.intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0)
        assertTrue(channel.onActivityResult(4720, Activity.RESULT_CANCELED, null))
        // Cancellation releases the picker so a second request can proceed.
        request("pickFiles")
        assertEquals(4720, shadowOf(activity).nextStartedActivityForResult.requestCode)
    }
    @Test fun subtitlePickerRetainsItsSeparateFiltersAndSingleSelection() {
        request("pickSubtitle")
        val launched = shadowOf(activity).nextStartedActivityForResult
        assertEquals(4722, launched.requestCode)
        val types = launched.intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES)!!.toSet()
        assertTrue(types.contains("text/vtt"))
        assertFalse(types.contains("audio/*"))
        assertFalse(launched.intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, true))
    }
}
