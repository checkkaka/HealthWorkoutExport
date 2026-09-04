package com.checkkaka.health_workout_export

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.browser.customtabs.CustomTabsIntent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private val channels = NativeChannels()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channels.attach(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        channels.handleIntent(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        channels.handleActivityResult(requestCode, resultCode, data)
    }
}

class NativeChannels {
    private var activity: Activity? = null
    private var oauthResult: MethodChannel.Result? = null
    private var filesResult: MethodChannel.Result? = null
    private var expectedOAuthState: String? = null

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        this.activity = activity
        val store = SecretStore(activity)
        MethodChannel(messenger, "health_workout_export/keychain").setMethodCallHandler { call, result ->
            handleVault(call, result, store, strava = true)
        }
        MethodChannel(messenger, "health_workout_export/third_party_vault").setMethodCallHandler { call, result ->
            handleVault(call, result, store, strava = false)
        }
        MethodChannel(messenger, "health_workout_export/preferences").setMethodCallHandler { call, result ->
            handlePreferences(activity, call, result)
        }
        MethodChannel(messenger, "health_workout_export/sync_files").setMethodCallHandler { call, result ->
            handleSyncFiles(activity, call, result)
        }
        MethodChannel(messenger, "health_workout_export/healthkit").setMethodCallHandler { call, result ->
            handleHealth(activity, call, result)
        }
        MethodChannel(messenger, "health_workout_export/strava_oauth").setMethodCallHandler { call, result ->
            handleOAuth(activity, call, result)
        }
        MethodChannel(messenger, "health_workout_export/strava_web").setMethodCallHandler { call, result ->
            handleWeb(activity, store, call, result)
        }
        MethodChannel(messenger, "health_workout_export/files").setMethodCallHandler { call, result ->
            handleFiles(activity, call, result)
        }
    }

    fun handleIntent(intent: Intent) {
        val uri = intent.data ?: return
        val result = oauthResult ?: return
        oauthResult = null
        val state = expectedOAuthState
        expectedOAuthState = null
        if (uri.scheme != "healthworkoutexport" || uri.host != "localhost" || uri.path != "/callback") {
            result.error("oauth_invalid_callback", "Strava 回调 scheme 或 state 校验失败", null)
            return
        }
        if (uri.getQueryParameter("state") != state) {
            result.error("oauth_invalid_callback", "Strava 回调 scheme 或 state 校验失败", null)
            return
        }
        val code = uri.getQueryParameter("code")
        if (code.isNullOrEmpty()) {
            result.error("oauth_cancelled", "已取消 Strava 授权", null)
        } else {
            result.success(code)
        }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != FILE_PICK_REQUEST) return
        val result = filesResult ?: return
        filesResult = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(emptyList<String>())
            return
        }
        val activity = activity ?: return
        val uris = mutableListOf<Uri>()
        data?.data?.let(uris::add)
        data?.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                uris.add(clip.getItemAt(index).uri)
            }
        }
        val directory = File(activity.cacheDir, "picked-fits-${UUID.randomUUID()}")
        directory.mkdirs()
        val paths = uris.mapNotNull { uri ->
            if (uri.lastPathSegment?.endsWith(".fit", ignoreCase = true) != true &&
                activity.contentResolver.getType(uri)?.contains("fit") != true
            ) {
                return@mapNotNull null
            }
            val name = uri.lastPathSegment?.substringAfterLast('/') ?: "activity.fit"
            val dest = File(directory, name.ifEmpty { "activity.fit" })
            activity.contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            }
            dest.absolutePath
        }
        result.success(paths)
    }

    private fun handlePreferences(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        if (key == null || key !in ALLOWED_PREFERENCE_KEYS) {
            result.error("invalid_arguments", "A non-empty key and a supported value are expected", null)
            return
        }
        val prefs = context.getSharedPreferences("health_workout_export_prefs", Context.MODE_PRIVATE)
        when (call.method) {
            "read" -> {
                if (!prefs.contains(key)) {
                    result.success(null)
                } else {
                    val all = prefs.all[key]
                    result.success(all)
                }
            }
            "write" -> {
                val value = call.argument<Any>("value")
                val editor = prefs.edit()
                when (value) {
                    is String -> editor.putString(key, value)
                    is Boolean -> editor.putBoolean(key, value)
                    is Int -> editor.putInt(key, value)
                    is Double -> editor.putFloat(key, value.toFloat())
                    else -> {
                        result.error("invalid_arguments", "A non-empty key and a supported value are expected", null)
                        return
                    }
                }
                editor.apply()
                result.success(null)
            }
            "delete" -> {
                prefs.edit().remove(key).apply()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleSyncFiles(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val root = File(context.filesDir, "Application Support")
        fun fingerprint(): String? {
            val value = call.argument<String>("fingerprint") ?: return null
            return value.takeIf { it.matches(Regex("^[a-f0-9]{64}$")) }
        }
        fun fileFor(kind: String): File? = when (kind) {
            "state" -> File(root, "sync_state.json")
            "fit" -> fingerprint()?.let { File(root, "synced_fits/$it.fit") }
            "recovery" -> fingerprint()?.let { File(root, "pending_resync/$it.json") }
            else -> null
        }
        try {
            when (call.method) {
                "readState" -> result.success(readBytes(fileFor("state")!!))
                "writeState" -> {
                    writeBytes(fileFor("state")!!, call.bytes())
                    result.success(null)
                }
                "deleteState" -> {
                    fileFor("state")?.delete()
                    result.success(null)
                }
                "readSyncedFit" -> {
                    val file = fileFor("fit")
                    if (file == null) missing(result) else result.success(readBytes(file))
                }
                "writeSyncedFit" -> {
                    val file = fileFor("fit")
                    if (file == null) missing(result) else {
                        writeBytes(file, call.bytes())
                        result.success(null)
                    }
                }
                "deleteSyncedFit" -> {
                    fileFor("fit")?.delete()
                    result.success(null)
                }
                "readRecovery" -> {
                    val file = fileFor("recovery")
                    if (file == null) missing(result) else result.success(readBytes(file))
                }
                "writeRecovery" -> {
                    val file = fileFor("recovery")
                    if (file == null) missing(result) else {
                        writeBytes(file, call.bytes())
                        result.success(null)
                    }
                }
                "deleteRecovery" -> {
                    fileFor("recovery")?.delete()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: java.io.FileNotFoundException) {
            result.error("sync_file_missing", error.message, null)
        } catch (error: Exception) {
            result.error("sync_file_io", error.message, null)
        }
    }

    private fun handleHealth(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(healthConnectInstalled(context))
            "requestAuthorization" -> {
                if (!healthConnectInstalled(context)) {
                    result.error("healthkit_unavailable", "此设备未安装 Health Connect", null)
                } else {
                    // ponytail: 真机授权走系统 Health Connect 设置，避免伪造 HealthKit 序列。
                    val intent = context.packageManager.getLaunchIntentForPackage(HEALTH_CONNECT_PACKAGE)
                    if (intent != null) context.startActivity(intent)
                    result.success(null)
                }
            }
            "openSettings" -> {
                val intent = context.packageManager.getLaunchIntentForPackage(HEALTH_CONNECT_PACKAGE)
                    ?: Intent(android.provider.Settings.ACTION_SETTINGS)
                context.startActivity(intent)
                result.success(null)
            }
            "currentTimeZoneIdentifier" -> result.success(java.util.TimeZone.getDefault().id)
            "listWorkouts", "fetchWorkoutBundles" ->
                result.error(
                    "healthkit_unavailable",
                    "Health Connect 仅映射可对应字段；当前构建未读取训练明细，避免伪造 HealthKit 序列",
                    mapOf("missing" to true),
                )
            else -> result.notImplemented()
        }
    }

    private fun handleOAuth(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "authorize") {
            result.notImplemented()
            return
        }
        if (oauthResult != null) {
            result.error("oauth_in_progress", "已有 Strava 授权正在进行", null)
            return
        }
        val rawUrl = call.argument<String>("authorizationUrl")
        val scheme = call.argument<String>("callbackScheme")
        if (rawUrl.isNullOrEmpty() || scheme != "healthworkoutexport") {
            result.error("invalid_arguments", "authorizationUrl 和合法 callbackScheme 均不能为空", null)
            return
        }
        val uri = Uri.parse(rawUrl)
        if (uri.scheme != "https" || uri.host != "www.strava.com" || uri.path != "/oauth/mobile/authorize") {
            result.error("oauth_configuration_error", "Strava 授权地址或随机状态无效", null)
            return
        }
        val state = UUID.randomUUID().toString().replace("-", "")
        expectedOAuthState = state
        oauthResult = result
        val url = uri.buildUpon().appendQueryParameter("state", state).build()
        CustomTabsIntent.Builder().build().launchUrl(activity, url)
    }

    private fun handleWeb(
        activity: Activity,
        store: SecretStore,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "hasCookie" -> result.success(!store.get(COOKIE_ACCOUNT).isNullOrEmpty())
            "clearCookies" -> {
                store.delete(COOKIE_ACCOUNT)
                CookieManager.getInstance().removeAllCookies { result.success(null) }
            }
            "login" -> presentWebLogin(activity, store, result)
            "uploadFit" -> result.error("web_upload_failed", "请在 iOS/macOS 使用网页 CSRF 上传", null)
            else -> result.notImplemented()
        }
    }

    private fun presentWebLogin(activity: Activity, store: SecretStore, result: MethodChannel.Result) {
        val webView = WebView(activity)
        webView.settings.javaScriptEnabled = true
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val host = request.url.host?.lowercase() ?: return true
                val allowed = host == "strava.com" || host.endsWith(".strava.com") ||
                    host == "accounts.google.com" || host == "appleid.apple.com" ||
                    host.contains("facebook.com")
                return !allowed || request.url.scheme != "https"
            }
        }
        val container = FrameLayout(activity)
        container.addView(webView)
        val dialog = android.app.AlertDialog.Builder(activity)
            .setTitle("Strava 登录")
            .setView(container)
            .setPositiveButton("完成登录") { _, _ ->
                val cookie = CookieManager.getInstance().getCookie("https://www.strava.com")
                if (cookie.isNullOrBlank()) {
                    result.error("web_login_failed", "未找到可用的 Strava 登录 Cookie", null)
                } else {
                    store.set(COOKIE_ACCOUNT, cookie)
                    result.success(true)
                }
            }
            .setNegativeButton("取消") { _, _ -> result.success(false) }
            .create()
        dialog.show()
        webView.loadUrl("https://www.strava.com/login")
    }

    private fun handleFiles(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "pickFits") {
            result.notImplemented()
            return
        }
        if (filesResult != null) {
            result.error("files_in_progress", "已有文件选择正在进行", null)
            return
        }
        filesResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        activity.startActivityForResult(intent, FILE_PICK_REQUEST)
    }

    private fun handleVault(
        call: MethodCall,
        result: MethodChannel.Result,
        store: SecretStore,
        strava: Boolean,
    ) {
        if (strava) {
            when (call.method) {
                "stravaStatus" -> result.success(
                    mapOf(
                        "clientId" to (store.get("strava.clientId") ?: ""),
                        "hasClientSecret" to !store.get("strava.clientSecret").isNullOrEmpty(),
                        "hasAccessToken" to !store.get("strava.accessToken").isNullOrEmpty(),
                        "hasRefreshToken" to !store.get("strava.refreshToken").isNullOrEmpty(),
                        "expiresAtSeconds" to (store.get("strava.expiresAt")?.toDoubleOrNull() ?: 0.0),
                    ),
                )
                "stravaLease" -> {
                    when (call.argument<String>("purpose")) {
                        "refresh" -> result.success(
                            mapOf(
                                "clientId" to store.require("strava.clientId"),
                                "clientSecret" to store.require("strava.clientSecret"),
                                "refreshToken" to store.require("strava.refreshToken"),
                                "expiresAtSeconds" to store.require("strava.expiresAt").toDouble(),
                            ),
                        )
                        "upload" -> result.success(
                            mapOf(
                                "accessToken" to store.require("strava.accessToken"),
                                "expiresAtSeconds" to store.require("strava.expiresAt").toDouble(),
                            ),
                        )
                        else -> result.error("invalid_arguments", "purpose 无效", null)
                    }
                }
                "writeStravaAuthorization" -> {
                    store.set("strava.clientId", call.argument<String>("clientId")!!)
                    store.set("strava.clientSecret", call.argument<String>("clientSecret")!!)
                    store.set("strava.accessToken", call.argument<String>("accessToken")!!)
                    store.set("strava.refreshToken", call.argument<String>("refreshToken")!!)
                    store.set("strava.expiresAt", call.argument<Number>("expiresAtSeconds")!!.toString())
                    result.success(null)
                }
                "clearStravaAuthorization" -> {
                    listOf(
                        "strava.clientId",
                        "strava.clientSecret",
                        "strava.accessToken",
                        "strava.refreshToken",
                        "strava.expiresAt",
                    ).forEach(store::delete)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
            return
        }
        when (call.method) {
            "xingzheStatus" -> result.success(
                mapOf(
                    "hasAccount" to !store.get("xingzhe.account").isNullOrEmpty(),
                    "hasPassword" to !store.get("xingzhe.password").isNullOrEmpty(),
                    "hasSessionId" to !store.get("xingzhe.session").isNullOrEmpty(),
                ),
            )
            "onelapStatus" -> result.success(
                mapOf(
                    "hasAccount" to !store.get("onelap.account").isNullOrEmpty(),
                    "hasPassword" to !store.get("onelap.password").isNullOrEmpty(),
                    "hasToken" to !store.get("onelap.token").isNullOrEmpty(),
                    "hasUid" to !store.get("onelap.uid").isNullOrEmpty(),
                ),
            )
            "xingzheLease" -> result.success(
                mapOf(
                    "account" to store.require("xingzhe.account"),
                    "password" to store.require("xingzhe.password"),
                    "sessionId" to (store.get("xingzhe.session") ?: ""),
                ),
            )
            "onelapLease" -> result.success(
                mapOf(
                    "account" to store.require("onelap.account"),
                    "password" to store.require("onelap.password"),
                    "token" to (store.get("onelap.token") ?: ""),
                    "uid" to (store.get("onelap.uid") ?: ""),
                ),
            )
            "writeXingzheAuthorization" -> {
                store.set("xingzhe.account", call.argument<String>("account")!!)
                store.set("xingzhe.password", call.argument<String>("password")!!)
                store.set("xingzhe.session", call.argument<String>("sessionId")!!)
                result.success(null)
            }
            "writeOnelapAuthorization" -> {
                store.set("onelap.account", call.argument<String>("account")!!)
                store.set("onelap.password", call.argument<String>("password")!!)
                store.set("onelap.token", call.argument<String>("token")!!)
                store.set("onelap.uid", call.argument<String>("uid")!!)
                result.success(null)
            }
            "clearXingzheAuthorization" -> {
                listOf("xingzhe.account", "xingzhe.password", "xingzhe.session").forEach(store::delete)
                result.success(null)
            }
            "clearOnelapAuthorization" -> {
                listOf("onelap.account", "onelap.password", "onelap.token", "onelap.uid").forEach(store::delete)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun missing(result: MethodChannel.Result) {
        result.error("sync_file_missing", "missing", null)
    }

    companion object {
        const val FILE_PICK_REQUEST = 42
        const val COOKIE_ACCOUNT = "strava.webCookie"
        const val HEALTH_CONNECT_PACKAGE = "com.google.android.apps.healthdata"
        val ALLOWED_PREFERENCE_KEYS = setOf(
            "strava.uploadMode",
            "strava.gcjCorrectionEnabled",
            "virtualPower.enabled",
            "virtualPower.includeInertia",
            "virtualPower.riderMassKg",
            "virtualPower.bikeMassKg",
            "virtualPower.cda",
        )

        fun healthConnectInstalled(context: Context): Boolean =
            context.packageManager.getLaunchIntentForPackage(HEALTH_CONNECT_PACKAGE) != null

        fun stableUuid(id: String): String = UUID.nameUUIDFromBytes(id.toByteArray()).toString()
    }
}

private fun MethodCall.bytes(): ByteArray {
    val value = argument<Any>("bytes") ?: error("missing bytes")
    return when (value) {
        is ByteArray -> value
        is ByteBuffer -> ByteArray(value.remaining()).also { value.get(it) }
        else -> error("invalid bytes")
    }
}

private fun readBytes(file: File): ByteArray {
    if (!file.exists()) {
        throw java.io.FileNotFoundException(file.path)
    }
    return file.readBytes()
}

private fun writeBytes(file: File, bytes: ByteArray) {
    file.parentFile?.mkdirs()
    val temp = File(file.parentFile, "${file.name}.tmp")
    temp.writeBytes(bytes)
    if (!temp.renameTo(file)) {
        file.writeBytes(bytes)
        temp.delete()
    }
}

class SecretStore(context: Context) {
    private val prefs = context.getSharedPreferences("health_workout_export_vault", Context.MODE_PRIVATE)

    fun get(account: String): String? {
        val packed = prefs.getString(account, null) ?: return null
        return decrypt(packed)
    }

    fun require(account: String): String = get(account) ?: error("missing $account")

    fun set(account: String, value: String) {
        prefs.edit().putString(account, encrypt(value)).apply()
    }

    fun delete(account: String) {
        prefs.edit().remove(account).apply()
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        keyStore.getKey(KEY_ALIAS, null)?.let { return it as SecretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(value.toByteArray())
        return android.util.Base64.encodeToString(cipher.iv + encrypted, android.util.Base64.NO_WRAP)
    }

    private fun decrypt(packed: String): String {
        val all = android.util.Base64.decode(packed, android.util.Base64.NO_WRAP)
        val iv = all.copyOfRange(0, 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(all.copyOfRange(12, all.size)))
    }

    companion object {
        private const val KEY_ALIAS = "health_workout_export_vault"
    }
}
