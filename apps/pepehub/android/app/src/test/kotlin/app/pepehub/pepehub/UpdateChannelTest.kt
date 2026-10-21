package app.pepehub.pepehub

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.content.pm.SigningInfo
import android.net.Uri
import android.os.Build
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.reflect.Proxy
import java.security.MessageDigest
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.ShadowApplicationPackageManager

/** Android 9/10's archive parser only collects certificates with GET_SIGNATURES. */
@Implements(className = "android.app.ApplicationPackageManager")
class LegacyArchiveCertificateShadow : ShadowApplicationPackageManager() {
    @Suppress("DEPRECATION")
    @Implementation
    override fun getPackageArchiveInfo(path: String, flags: Int): PackageInfo? {
        val parsed = super.getPackageArchiveInfo(path, flags) ?: return null
        if (flags and PackageManager.GET_SIGNATURES == 0) {
            parsed.signatures = null
            parsed.signingInfo = null
        }
        return parsed
    }
}

/** Exercises the native bridge, manifest and activity lifecycle on a host JVM. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 35])
class UpdateChannelTest {
    private lateinit var activity: Activity
    private lateinit var channel: UpdateChannel
    private lateinit var apk: File
    private lateinit var arguments: Map<String, Any>

    private class Reply : MethodChannel.Result {
        var calls = 0
        var value: Any? = null
        var error: String? = null
        var message: String? = null
        override fun success(result: Any?) { calls++; value = result }
        override fun error(code: String, message: String?, details: Any?) { calls++; error = code; this.message = message }
        override fun notImplemented() { calls++; error = "notImplemented" }
    }
    @Suppress("DEPRECATION")
    @Before fun setup() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val messenger = Proxy.newProxyInstance(BinaryMessenger::class.java.classLoader,
            arrayOf(BinaryMessenger::class.java)) { _, _, _ -> null } as BinaryMessenger
        // AndroidX FileProvider uses '/' when checking canonical paths, which
        // cannot operate on the Windows host filesystem. Only URI construction
        // is substituted; the bridge, validation and intent are production code.
        channel = UpdateChannel(activity, messenger) {
            Uri.parse("content://${activity.packageName}.updates/updates/verified.apk")
        }
        channel.attach(activity)
        channel.onResume()
        shadowOf(Looper.getMainLooper()).idle()
        shadowOf(activity.packageManager).setCanRequestPackageInstalls(true)
        fun info(code: Int) = PackageInfo().apply {
            packageName = activity.packageName
            versionName = if (code == 2053) "0.21.1" else "0.21.2"
            versionCode = code
            signatures = arrayOf(Signature(byteArrayOf(1, 2, 3)))
            if (Build.VERSION.SDK_INT >= 28) {
                signingInfo = Shadow.newInstanceOf(SigningInfo::class.java).also {
                    shadowOf(it).setSignatures(signatures)
                }
            }
        }
        // Keep the merged manifest's providers and their path metadata.
        val current = activity.packageManager.getPackageInfo(activity.packageName,
            PackageManager.GET_PROVIDERS or PackageManager.GET_META_DATA)
        current.versionName = "0.21.1"
        current.versionCode = 2053
        current.signatures = info(2053).signatures
        if (Build.VERSION.SDK_INT >= 28) current.signingInfo = info(2053).signingInfo
        shadowOf(activity.packageManager).installPackage(current)
        apk = File(activity.cacheDir, "pepehub-updates/verified.apk")
        apk.parentFile!!.mkdirs()
        apk.writeText("APK bytes; PackageManager supplies the parsed archive in this test")
        shadowOf(activity.packageManager).setPackageArchiveInfo(apk.canonicalPath, info(2054))
        arguments = mapOf("path" to apk.path, "version" to "0.21.2", "versionCode" to 2054,
            "sha256" to MessageDigest.getInstance("SHA-256").digest(apk.readBytes()).joinToString("") { "%02x".format(it) })
    }
    @After fun close() { channel.dispose() }
    private fun call(method: String, args: Any? = null): Reply = Reply().also {
        channel.onMethodCall(MethodCall(method, args), it)
    }
    private fun await(reply: Reply) {
        val deadline = System.nanoTime() + 5_000_000_000L
        while (reply.calls == 0 && System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(5)
        }
        assertEquals("The method channel must receive exactly one reply", 1, reply.calls)
    }
    @Suppress("DEPRECATION")
    @Test fun verifiedApkReachesInstallerWithReadGrant() {
        val reply = call("installApk", arguments)
        await(reply)
        assertNull(reply.message, reply.error)
        assertEquals("installerOpened", reply.value)
        val launched = shadowOf(activity).nextStartedActivityForResult
        assertEquals(Intent.ACTION_INSTALL_PACKAGE, launched.intent.action)
        assertEquals("application/vnd.android.package-archive", launched.intent.type)
        assertEquals("content", launched.intent.data!!.scheme)
        assertEquals("${activity.packageName}.updates", launched.intent.data!!.authority)
        assertTrue(launched.intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        assertEquals(launched.intent.data, launched.intent.clipData!!.getItemAt(0).uri)
        assertTrue(launched.intent.getBooleanExtra(Intent.EXTRA_RETURN_RESULT, false))
    }
    @Test fun mergedManifestProvidesOnlyTheUpdateCacheDirectory() {
        val provider = activity.packageManager.resolveContentProvider(
            "${activity.packageName}.updates", PackageManager.GET_META_DATA)!!
        assertEquals(UpdateFileProvider::class.java.name, provider.name)
        assertFalse(provider.exported)
        assertTrue(provider.grantUriPermissions)
        val resource = provider.metaData.getInt("android.support.FILE_PROVIDER_PATHS")
        assertTrue(resource != 0)
        val paths = mutableListOf<Pair<String, String?>>()
        activity.resources.getXml(resource).use { xml ->
            while (xml.next() != org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
                if (xml.eventType == org.xmlpull.v1.XmlPullParser.START_TAG && xml.name != "paths") {
                    paths.add(xml.name to xml.getAttributeValue(null, "path"))
                }
            }
        }
        assertEquals(listOf("cache-path" to "pepehub-updates/"), paths)
    }
    @Test fun settingsReturnReportsActualPermissionOnce() {
        shadowOf(activity.packageManager).setCanRequestPackageInstalls(false)
        val install = call("installApk", arguments)
        await(install)
        assertEquals("permissionRequired", install.value)
        val reply = call("openInstallSettings")
        assertEquals(0, reply.calls)
        assertEquals(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            shadowOf(activity).nextStartedActivityForResult.intent.action)
        channel.onPause()
        shadowOf(activity.packageManager).setCanRequestPackageInstalls(true)
        channel.onActivityResult(4281)
        assertEquals(0, reply.calls) // Installer may only launch after onResume.
        channel.onResume()
        shadowOf(Looper.getMainLooper()).idle()
        channel.onActivityResult(4281) // Duplicate OEM callback is harmless.
        assertEquals(1, reply.calls)
        assertEquals(true, reply.value)
    }
    @Test fun settingsDeniedWithoutActivityResultUsesResumeFallback() {
        shadowOf(activity.packageManager).setCanRequestPackageInstalls(false)
        val reply = call("openInstallSettings")
        channel.onPause()
        channel.onResume()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(1, reply.calls)
        assertEquals(false, reply.value)
    }
    @Test fun tamperedApkCannotLaunchInstaller() {
        apk.appendText("changed")
        val reply = call("installApk", arguments)
        await(reply)
        assertEquals("verify", reply.error)
        assertNull(shadowOf(activity).nextStartedActivity)
    }
    @Test
    @Config(sdk = [28, 29], shadows = [LegacyArchiveCertificateShadow::class])
    fun androidNineAndTenCollectArchiveCertificatesBeforeComparing() {
        val reply = call("installApk", arguments)
        await(reply)
        assertNull(reply.message, reply.error)
        assertEquals("installerOpened", reply.value)
        assertNotNull(shadowOf(activity).nextStartedActivity)
    }
    @Suppress("DEPRECATION")
    @Test
    @Config(sdk = [28, 35])
    fun missingModernArchiveInfoUsesTheVerifiedLegacyCertificates() {
        val parsed = activity.packageManager.getPackageArchiveInfo(apk.canonicalPath,
            PackageManager.GET_SIGNATURES or PackageManager.GET_SIGNING_CERTIFICATES)!!
        parsed.signingInfo = null
        shadowOf(activity.packageManager).setPackageArchiveInfo(apk.canonicalPath, parsed)
        val reply = call("installApk", arguments)
        await(reply)
        assertNull(reply.message, reply.error)
        assertEquals("installerOpened", reply.value)
    }
    @Suppress("DEPRECATION")
    @Test fun differentCertificateCannotLaunchInstaller() {
        val parsed = activity.packageManager.getPackageArchiveInfo(apk.canonicalPath,
            PackageManager.GET_SIGNATURES)!!
        parsed.signatures = arrayOf(Signature(byteArrayOf(9, 8, 7)))
        if (Build.VERSION.SDK_INT >= 28) {
            parsed.signingInfo = Shadow.newInstanceOf(SigningInfo::class.java).also {
                shadowOf(it).setSignatures(parsed.signatures)
            }
        }
        shadowOf(activity.packageManager).setPackageArchiveInfo(apk.canonicalPath, parsed)
        val reply = call("installApk", arguments)
        await(reply)
        assertEquals("verify", reply.error)
        assertTrue(reply.message!!.contains("Подпись APK отличается"))
        assertNull(shadowOf(activity).nextStartedActivity)
    }
    @Suppress("DEPRECATION")
    @Test fun missingCertificatesAreNotReportedAsADifferentSignature() {
        val parsed = activity.packageManager.getPackageArchiveInfo(apk.canonicalPath,
            PackageManager.GET_SIGNATURES)!!
        parsed.signatures = null
        if (Build.VERSION.SDK_INT >= 28) parsed.signingInfo = null
        shadowOf(activity.packageManager).setPackageArchiveInfo(apk.canonicalPath, parsed)
        val reply = call("installApk", arguments)
        await(reply)
        assertEquals("verify", reply.error)
        assertTrue(reply.message!!, reply.message!!.contains("Не удалось прочитать подпись APK"))
        assertNull(shadowOf(activity).nextStartedActivity)
    }
    @Suppress("DEPRECATION")
    @Test
    @Config(sdk = [35])
    fun aModernMismatchCannotBeBypassedByMatchingLegacyMetadata() {
        val parsed = activity.packageManager.getPackageArchiveInfo(apk.canonicalPath,
            PackageManager.GET_SIGNATURES or PackageManager.GET_SIGNING_CERTIFICATES)!!
        parsed.signatures = arrayOf(Signature(byteArrayOf(1, 2, 3)))
        parsed.signingInfo = Shadow.newInstanceOf(SigningInfo::class.java).also {
            shadowOf(it).setSignatures(arrayOf(Signature(byteArrayOf(9, 8, 7))))
        }
        shadowOf(activity.packageManager).setPackageArchiveInfo(apk.canonicalPath, parsed)
        val reply = call("installApk", arguments)
        await(reply)
        assertEquals("verify", reply.error)
        assertTrue(reply.message!!.contains("Подпись APK отличается"))
        assertNull(shadowOf(activity).nextStartedActivity)
    }
    @Test fun timeoutRepliesOnceAndLateWorkerCannotOpenInstaller() {
        val field = UpdateChannel::class.java.getDeclaredField("worker").apply { isAccessible = true }
        val worker = field.get(channel) as ExecutorService
        val gate = CountDownLatch(1)
        worker.execute { gate.await() }
        try {
            val reply = call("installApk", arguments)
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(31))
            assertEquals("install_timeout", reply.error)
            gate.countDown()
            worker.submit {}.get()
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(1, reply.calls)
            assertNull(shadowOf(activity).nextStartedActivity)
        } finally { gate.countDown() }
    }
    @Test fun browserFallbackOpensHttpsAndAlwaysReplies() {
        val reply = call("openDownload", mapOf("url" to "https://example.org/PepeHub.apk"))
        assertEquals(1, reply.calls)
        assertNull(reply.error)
        assertEquals(Intent.ACTION_VIEW, shadowOf(activity).nextStartedActivity.action)
        assertEquals("update", call("openDownload", mapOf("url" to "file:///private.apk")).error)
    }
}
