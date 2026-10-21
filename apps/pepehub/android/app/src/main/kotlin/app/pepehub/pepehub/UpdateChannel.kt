package app.pepehub.pepehub

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class UpdateChannel(
    context: Context,
    messenger: BinaryMessenger,
    private val apkUri: ((File) -> Uri)? = null,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val SETTINGS_REQUEST = 4281
        private const val INSTALL_REQUEST = 4282
    }
    private val context = context.applicationContext
    private var activity = WeakReference<Activity>(null)
    private val channel = MethodChannel(messenger, "pepehub/updates")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var settingsResult: MethodChannel.Result? = null
    private var settingsDeparted = false
    private var resumed = false
    init { channel.setMethodCallHandler(this) }
    fun attach(value: Activity) { activity = WeakReference(value) }
    fun detach(value: Activity) {
        if (activity.get() === value) { activity.clear(); resumed = false }
    }
    private fun canInstall() = Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls()
    fun onPause() {
        resumed = false
        if (settingsResult != null) settingsDeparted = true
    }
    fun onResume() {
        resumed = true
        // Some manufacturers do not return an activity result for this settings
        // screen. The permission itself is authoritative, not RESULT_OK.
        main.post { if (resumed && settingsDeparted) finishSettings() }
    }
    private fun finishSettings() {
        val pending = settingsResult ?: return
        settingsResult = null
        settingsDeparted = false
        try { pending.success(canInstall()) }
        catch (error: Exception) { pending.error("permission", error.message, null) }
    }
    fun onActivityResult(requestCode: Int): Boolean {
        if (requestCode == SETTINGS_REQUEST) {
            // onResume completes it once the host can launch the installer.
            settingsDeparted = true
            if (resumed) finishSettings()
            return true
        }
        return requestCode == INSTALL_REQUEST
    }
    private fun host(): Activity {
        val value = activity.get() ?: error("Откройте PepeHub и повторите установку")
        check(resumed && !value.isFinishing && !value.isDestroyed) { "Вернитесь в PepeHub и повторите установку" }
        return value
    }
    @Suppress("DEPRECATION")
    private fun launchInstaller(file: File) {
        val host = host()
        val uri = apkUri?.invoke(file)
            ?: FileProvider.getUriForFile(context, "${context.packageName}.updates", file)
        // Explicitly use the package installation action, with caller identity
        // and a read grant. Generic ACTION_VIEW can be routed through OEM apps.
        fun intent(action: String) = Intent(action).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = ClipData.newRawUri("PepeHub update", uri)
            putExtra(Intent.EXTRA_RETURN_RESULT, true)
        }
        try {
            host.startActivityForResult(intent(Intent.ACTION_INSTALL_PACKAGE), INSTALL_REQUEST)
        } catch (_: ActivityNotFoundException) {
            try { host.startActivityForResult(intent(Intent.ACTION_VIEW), INSTALL_REQUEST) }
            catch (_: ActivityNotFoundException) {
                error("Установщик APK недоступен. Скачайте APK через браузер и откройте его в загрузках")
            }
        }
    }
    @Suppress("DEPRECATION")
    private fun signatureFlags(): Int = PackageManager.GET_SIGNATURES or
        (if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else 0)
    @Suppress("DEPRECATION")
    private fun installed(): PackageInfo = context.packageManager.getPackageInfo(context.packageName,
        signatureFlags())
    @Suppress("DEPRECATION")
    private fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val modern = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else null
        val signatures = modern?.takeIf { it.isNotEmpty() } ?: info.signatures
        return signatures?.map { MessageDigest.getInstance("SHA-256").digest(it.toByteArray()).joinToString("") { b -> "%02x".format(b) } }?.toSet() ?: emptySet()
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getInfo" -> {
                    val current = installed()
                    result.success(mapOf("version" to current.versionName, "versionCode" to code(current),
                        "platform" to if (Build.SUPPORTED_ABIS.contains("arm64-v8a")) "android-arm64" else "android-universal"))
                }
                "openInstallSettings" -> {
                    val host = host()
                    if (canInstall()) { result.success(true); return }
                    check(settingsResult == null) { "Настройки разрешения уже открыты" }
                    settingsResult = result
                    settingsDeparted = false
                    try {
                        @Suppress("DEPRECATION")
                        host.startActivityForResult(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${context.packageName}")), SETTINGS_REQUEST)
                    } catch (error: Exception) {
                        settingsResult = null
                        throw error
                    }
                }
                "openDownload" -> {
                    val url = Uri.parse(call.argument<String>("url") ?: error("Не указан адрес APK"))
                    require(url.scheme == "https" && !url.host.isNullOrEmpty() && url.userInfo == null) { "Неверный адрес APK" }
                    host().startActivity(Intent(Intent.ACTION_VIEW, url).addCategory(Intent.CATEGORY_BROWSABLE))
                    result.success(null)
                }
                "installApk" -> {
                    val path = call.argument<String>("path") ?: error("Не указан APK")
                    val expectedVersion = call.argument<String>("version") ?: error("Не указана версия")
                    val expectedCode = call.argument<Number>("versionCode")?.toLong() ?: error("Не указана сборка")
                    val expectedHash = call.argument<String>("sha256") ?: error("Не указана контрольная сумма")
                    host()
                    val finished = AtomicBoolean(false)
                    val timeout = Runnable {
                        if (finished.compareAndSet(false, true)) result.error("install_timeout",
                            "Проверка APK не завершилась за 30 секунд. Повторите попытку или скачайте APK через браузер", null)
                    }
                    main.postDelayed(timeout, 30_000)
                    worker.execute {
                        try {
                            val root = File(context.cacheDir, "pepehub-updates").canonicalFile
                            val file = File(path).canonicalFile
                            require(file.path.startsWith(root.path + File.separator) && file.isFile && file.extension == "apk") { "APK вне каталога обновлений" }
                            val digest = MessageDigest.getInstance("SHA-256")
                            file.inputStream().use { input ->
                                val buffer = ByteArray(128 * 1024)
                                while (true) {
                                    if (finished.get()) return@execute
                                    val n = input.read(buffer)
                                    if (n < 0) break
                                    digest.update(buffer, 0, n)
                                }
                            }
                            require(digest.digest().joinToString("") { b -> "%02x".format(b) } == expectedHash) { "APK изменился после загрузки" }
                            @Suppress("DEPRECATION")
                            // Android 9/10 only collect archive certificates if GET_SIGNATURES
                            // is set, even when GET_SIGNING_CERTIFICATES was requested.
                            val candidate = context.packageManager.getPackageArchiveInfo(file.path,
                                signatureFlags())
                                ?: error("Повреждённый APK")
                            val current = installed()
                            require(candidate.packageName == context.packageName) { "APK другого приложения" }
                            require(code(candidate) == expectedCode && expectedCode > code(current) && candidate.versionName == expectedVersion) { "Неверная или устаревшая версия APK" }
                            val oldSigners = signers(current)
                            val newSigners = signers(candidate)
                            require(oldSigners.isNotEmpty()) { "Не удалось прочитать подпись установленного PepeHub. Откройте APK через браузер" }
                            require(newSigners.isNotEmpty()) { "Не удалось прочитать подпись APK. Откройте APK через браузер" }
                            require(newSigners == oldSigners) { "Подпись APK отличается от установленного приложения" }
                            main.post {
                                if (!finished.compareAndSet(false, true)) return@post
                                main.removeCallbacks(timeout)
                                try {
                                    host()
                                    if (!canInstall()) {
                                        result.success("permissionRequired")
                                    } else {
                                        launchInstaller(file)
                                        result.success("installerOpened")
                                    }
                                } catch (error: Exception) { result.error("install", error.message, null) }
                            }
                        } catch (error: Exception) {
                            main.post {
                                if (finished.compareAndSet(false, true)) {
                                    main.removeCallbacks(timeout)
                                    result.error("verify", error.message, null)
                                }
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { result.error("update", error.message, null) }
    }
    fun dispose() {
        settingsResult?.error("closed", "Приложение закрыто. Повторите установку", null)
        settingsResult = null
        channel.setMethodCallHandler(null)
        activity.clear()
        worker.shutdown()
    }
}
