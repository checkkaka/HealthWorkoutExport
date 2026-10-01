package com.checkkaka.health_workout_export

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebSettings
import android.webkit.RenderProcessGoneDetail
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
import java.util.concurrent.Executors
import java.util.concurrent.Future
import org.json.JSONObject
import org.json.JSONTokener
import java.nio.charset.CodingErrorAction
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

    override fun onResume() {
        super.onResume()
        channels.setForeground(true)
    }

    override fun onPause() {
        channels.setForeground(false)
        super.onPause()
    }

    override fun onDestroy() {
        channels.detach()
        super.onDestroy()
    }

}

class NativeChannels {
    private var activity: Activity? = null
    private var healthConnect: HealthConnectPlugin? = null
    private var oauthResult: MethodChannel.Result? = null
    private var filesResult: MethodChannel.Result? = null
    private var expectedOAuthState: String? = null

    private enum class WebOperation { IDLE, LOGIN, PROBING, UPLOADING, DELETING, LISTING, CLEARING }
    private var webOperation = WebOperation.IDLE
    private var webOperationId = 0L
    private var webResult: MethodChannel.Result? = null
    private var webDialog: AlertDialog? = null
    private var loginWebView: WebView? = null
    private var webClient: StravaWebClient? = null
    private var webTask: Future<*>? = null
    private var webTimeout: Runnable? = null
    private val webHandler = Handler(Looper.getMainLooper())
    private val webExecutor = Executors.newSingleThreadExecutor()

    fun setForeground(value: Boolean) { healthConnect?.setForeground(value) }

    fun detach() {
        healthConnect?.detach()
        healthConnect = null
        val uploading = webOperation == WebOperation.UPLOADING
        val deleting = webOperation == WebOperation.DELETING
        finishWeb(webOperationId) {
            it.error(
                if (deleting) "web_delete_failed" else if (uploading) "web_upload_interrupted" else "web_login_interrupted",
                if (deleting) "网页删除未确认，活动可能已删除，请检查后重试" else if (uploading) "上传已中断，Strava 可能已收到文件，请检查后重试" else "Strava 网页操作已中断，请重试",
                mapOf("retryable" to !(uploading || deleting), "mayHaveUploaded" to uploading, "mayHaveDeleted" to deleting),
            )
        }
        oauthResult?.error("oauth_cancelled", "Strava 授权已中断", null)
        oauthResult = null
        expectedOAuthState = null
        filesResult?.success(emptyList<String>())
        filesResult = null
        activity = null
        webExecutor.shutdownNow()
    }

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        this.activity = activity
        healthConnect = HealthConnectPlugin(activity)
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
            healthConnect?.handle(call, result)
                ?: result.error("healthkit_unavailable", "健康数据适配器未连接", null)
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
        if (!uri.scheme.equals("healthworkoutexport", ignoreCase = true)) return
        val state = expectedOAuthState
        oauthResult = null
        expectedOAuthState = null
        try {
            result.success(StravaOAuthSecurity.callbackCode(uri.toString(), state))
        } catch (error: StravaOAuthSecurity.OAuthFailure) {
            result.error(error.code, if (error.code == "oauth_cancelled") "已取消 Strava 授权" else "Strava 回调校验失败", null)
        }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (healthConnect?.handleActivityResult(requestCode, resultCode, data) == true) return
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
        fun fileFor(kind: String): File {
            if (kind == "state") return File(root, "sync_state.json")
            if (kind == "batch") return File(root, "auto-sync-batch.json")
            val fingerprint = call.argument<String>("fingerprint")
            require(fingerprint != null && fingerprint.matches(Regex("^[a-f0-9]{64}$")))
            if (kind == "health") return NativeSyncFiles.healthPreparedFile(root, fingerprint)
            return if (kind == "fit") File(root, "synced_fits/$fingerprint.fit")
                else File(root, "pending_resync/$fingerprint.json")
        }
        fun requireJsonObject(bytes: ByteArray) {
            val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
            val parser = JSONTokener(text)
            require(parser.nextValue() is JSONObject && parser.nextClean() == 0.toChar())
        }
        val operations = mapOf(
            "readBatchSession" to ("read" to "batch"), "writeBatchSession" to ("write" to "batch"), "deleteBatchSession" to ("delete" to "batch"),
            "readState" to ("read" to "state"), "writeState" to ("write" to "state"), "deleteState" to ("delete" to "state"),
            "readHealthPreparedFit" to ("read" to "health"), "writeHealthPreparedFit" to ("write" to "health"), "deleteHealthPreparedFit" to ("delete" to "health"),
            "readSyncedFit" to ("read" to "fit"), "writeSyncedFit" to ("write" to "fit"), "deleteSyncedFit" to ("delete" to "fit"),
            "readRecovery" to ("read" to "recovery"), "writeRecovery" to ("write" to "recovery"), "deleteRecovery" to ("delete" to "recovery"),
        )
        val operation = operations[call.method] ?: run { result.notImplemented(); return }
        try {
            val (verb, kind) = operation
            val file = fileFor(kind)
            val maximum = when (kind) {
                "fit", "health" -> NativeSyncFiles.MAX_FIT_BYTES
                "state" -> NativeSyncFiles.MAX_STATE_BYTES
                "recovery" -> NativeSyncFiles.MAX_RECOVERY_BYTES
                else -> NativeSyncFiles.MAX_JSON_BYTES
            }
            when (verb) {
                "read" -> {
                    val bytes = NativeSyncFiles.read(file, maximum)
                    if (kind != "fit" && kind != "health") {
                        try { requireJsonObject(bytes) }
                        catch (_: Exception) { result.error("sync_file_corrupt", "同步文件不是有效的 JSON 对象", null); return }
                    }
                    result.success(bytes)
                }
                "write" -> {
                    val bytes = call.bytes()
                    if (bytes.size > maximum) { result.error("sync_file_too_large", "同步文件超过大小限制", null); return }
                    if (kind != "fit" && kind != "health") {
                        try { requireJsonObject(bytes) }
                        catch (_: Exception) { result.error("invalid_json", "写入的同步文件不是 JSON 对象", null); return }
                    }
                    NativeSyncFiles.write(file, bytes, maximum)
                    result.success(null)
                }
                "delete" -> { NativeSyncFiles.delete(file); result.success(null) }
            }
        } catch (_: java.io.FileNotFoundException) {
            result.error("sync_file_missing", "同步文件不存在", null)
        } catch (_: NativeSyncFiles.TooLargeException) {
            result.error("sync_file_too_large", "同步文件超过大小限制", null)
        } catch (_: IllegalArgumentException) {
            result.error("invalid_arguments", "同步文件参数无效", null)
        } catch (_: Exception) {
            result.error("sync_file_io", "同步文件读写失败", null)
        }
    }

    private fun handleOAuth(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "cancelAuthorization") {
            val pending = oauthResult
            oauthResult = null
            expectedOAuthState = null
            pending?.error("oauth_cancelled", "已取消 Strava 授权", null)
            // Custom Tabs belongs to the browser. Clearing the pending state makes late callbacks inert.
            result.success(null)
            return
        }
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
        val state = StravaOAuthSecurity.makeState()
        val url = try { StravaOAuthSecurity.authorizationUrl(rawUrl, state) }
        catch (_: IllegalArgumentException) {
            result.error("oauth_configuration_error", "Strava 授权地址或随机状态无效", null)
            return
        }
        expectedOAuthState = state
        oauthResult = result
        try {
            CustomTabsIntent.Builder().build().launchUrl(activity, Uri.parse(url))
        } catch (_: Exception) {
            oauthResult = null
            expectedOAuthState = null
            result.error("oauth_failed", "无法打开 Strava 授权页面", null)
        }
    }

    private fun handleWeb(
        activity: Activity,
        store: SecretStore,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        try {
            when (call.method) {
                "openActivity" -> {
                    val url = StravaWebClient.activityUrl(call.argument<String>("remoteId"))
                    if (url == null) {
                        result.error("invalid_arguments", "远端活动 ID 必须为数字", null)
                    } else {
                        try {
                            activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            result.success(null)
                        } catch (_: Exception) {
                            result.error("web_activity_open_failed", "无法打开 Strava 活动", null)
                        }
                    }
                }
                "hasCookie" -> result.success(StravaWebClient.normalizeCookieHeader(store.get(COOKIE_ACCOUNT)) != null)
                "clearCookies" -> {
                    val operationId = beginWeb(WebOperation.CLEARING, result) ?: return
                    try {
                        store.delete(COOKIE_ACCOUNT)
                        CookieManager.getInstance().removeAllCookies {
                            webHandler.post {
                                try {
                                    CookieManager.getInstance().flush()
                                    val remaining = CookieManager.getInstance().hasCookies()
                                    finishWeb(operationId) { callback ->
                                        if (remaining) callback.error("web_cookie_clear_partial", "网页 Cookie 未完全清除，请重试", null)
                                        else callback.success(null)
                                    }
                                } catch (_: Exception) {
                                    finishWeb(operationId) { it.error("web_cookie_clear_failed", "无法确认网页登录已清除", null) }
                                }
                            }
                        }
                    } catch (_: Exception) {
                        finishWeb(operationId) { it.error("web_cookie_clear_failed", "无法清除网页登录，请重试", null) }
                    }
                }
                "deleteActivity" -> deleteWebActivity(store, call, result)
                "listActivityPage" -> listWebActivityPage(store, call, result)
                "readActivitySpeedData" -> readWebActivitySpeedData(store, call, result)
                "login" -> presentWebLogin(activity, store, result)
                "uploadFit" -> uploadWebFit(store, call, result)
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            if (webResult === result) {
                finishWeb(webOperationId) { it.error("web_storage_error", "无法读取 Strava 网页凭证，请重新登录", null) }
            } else {
                result.error("web_storage_error", "无法读取 Strava 网页凭证，请重新登录", null)
            }
        }
    }

    private fun beginWeb(operation: WebOperation, result: MethodChannel.Result): Long? {
        if (webResult != null || webOperation != WebOperation.IDLE) {
            result.error("web_operation_in_progress", "Strava 网页操作正在进行，请稍后重试", null)
            return null
        }
        webOperation = operation
        webOperationId += 1
        webResult = result
        val operationId = webOperationId
        // Interactive login has no clock limit. The network and clearing phases do.
        if (operation != WebOperation.LOGIN) scheduleWebTimeout(operationId)
        return operationId
    }

    private fun scheduleWebTimeout(operationId: Long) {
        webTimeout?.let(webHandler::removeCallbacks)
        val timeout = Runnable {
            val uploading = webOperation == WebOperation.UPLOADING
            val deleting = webOperation == WebOperation.DELETING
            finishWeb(operationId) {
                it.error(
                    if (deleting) "web_delete_failed" else if (uploading) "web_upload_failed" else "web_operation_timeout",
                    if (deleting) "网页删除超时，活动可能已删除，请检查后重试" else if (uploading) "网页上传超时，Strava 可能已收到文件，请检查后重试" else "Strava 网页操作超时，请重试",
                    mapOf("retryable" to !(uploading || deleting), "mayHaveUploaded" to uploading, "mayHaveDeleted" to deleting),
                )
            }
        }
        webTimeout = timeout
        webHandler.postDelayed(timeout, 120_000)
    }

    private fun isCurrentWeb(operationId: Long): Boolean =
        operationId == webOperationId && webResult != null

    private fun finishWeb(operationId: Long, complete: (MethodChannel.Result) -> Unit) {
        if (!isCurrentWeb(operationId)) return
        val result = webResult ?: return
        // Clear state before dismissing: Back, Cancel and onDismiss may all fire.
        webResult = null
        webOperation = WebOperation.IDLE
        webTimeout?.let(webHandler::removeCallbacks)
        webTimeout = null
        runCatching { webTask?.cancel(true) }
        webTask = null
        runCatching { webClient?.cancel() }
        webClient = null
        val dialog = webDialog
        webDialog = null
        runCatching {
            dialog?.setOnDismissListener(null)
            dialog?.setOnCancelListener(null)
            dialog?.dismiss()
        }
        val view = loginWebView
        loginWebView = null
        runCatching {
            view?.stopLoading()
            view?.webViewClient = WebViewClient()
            view?.destroy()
        }
        complete(result)
    }

    private fun presentWebLogin(activity: Activity, store: SecretStore, result: MethodChannel.Result) {
        if (activity.isFinishing || activity.isDestroyed) {
            result.error("web_login_unavailable", "无法显示 Strava 网页登录", null)
            return
        }
        val operationId = beginWeb(WebOperation.LOGIN, result) ?: return
        try {
            val webView = WebView(activity)
            loginWebView = webView
            webView.settings.javaScriptEnabled = true
            webView.settings.domStorageEnabled = true
            webView.settings.allowFileAccess = false
            webView.settings.allowContentAccess = false
            webView.settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            webView.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                    !StravaWebClient.isAllowedLoginUrl(request.url.toString())

                @Deprecated("Required for WebView navigation compatibility")
                override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean =
                    !StravaWebClient.isAllowedLoginUrl(url)

                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                    finishWeb(operationId) { it.error("web_login_interrupted", "登录页面已中断，请重试", null) }
                    return true
                }
            }
            val container = FrameLayout(activity)
            container.addView(webView)
            val dialog = AlertDialog.Builder(activity)
                .setTitle("Strava 登录")
                .setView(container)
                .setPositiveButton("完成登录", null)
                .setNegativeButton("取消") { _, _ -> finishWeb(operationId) { it.success(false) } }
                .create()
            webDialog = dialog
            dialog.setOnCancelListener { finishWeb(operationId) { it.success(false) } }
            dialog.setOnDismissListener { finishWeb(operationId) { it.success(false) } }
            dialog.show()
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                try {
                    if (!isCurrentWeb(operationId) || webOperation != WebOperation.LOGIN) return@setOnClickListener
                    // Root-path cookies can safely be reused at /about and /upload/files.
                    val cookie = StravaWebClient.normalizeCookieHeader(
                        CookieManager.getInstance().getCookie("https://www.strava.com/"),
                    )
                    if (cookie == null) {
                        finishWeb(operationId) { it.error("web_login_failed", "未找到可用的 Strava 登录 Cookie", null) }
                        return@setOnClickListener
                    }
                    webOperation = WebOperation.PROBING
                    dialog.getButton(AlertDialog.BUTTON_POSITIVE).isEnabled = false
                    webView.stopLoading()
                    val client = StravaWebClient()
                    webClient = client
                    scheduleWebTimeout(operationId)
                    webTask = webExecutor.submit {
                        val verified = try {
                            val response = client.probe(cookie)
                            val body = JSONObject(response.text())
                            response.statusCode == 200 &&
                                (body.optJSONArray("models") != null || body.optJSONArray("activities") != null)
                        } catch (_: Exception) { false }
                        webHandler.post {
                            if (!isCurrentWeb(operationId)) return@post
                            if (!verified) {
                                finishWeb(operationId) {
                                    it.error("web_login_not_ready", "无法验证 Strava 登录，请重新登录", mapOf("retryable" to true))
                                }
                            } else {
                                try {
                                    store.set(COOKIE_ACCOUNT, cookie)
                                    finishWeb(operationId) { it.success(true) }
                                } catch (_: Exception) {
                                    finishWeb(operationId) { it.error("web_storage_error", "无法保存 Strava 网页凭证", null) }
                                }
                            }
                        }
                    }
                } catch (_: Exception) {
                    finishWeb(operationId) { it.error("web_login_failed", "无法验证 Strava 网页登录，请重试", null) }
                }
            }
            webView.loadUrl("https://www.strava.com/login")
        } catch (_: Exception) {
            finishWeb(operationId) { it.error("web_login_unavailable", "无法显示 Strava 网页登录", null) }
        }
    }

    private fun deleteWebActivity(store: SecretStore, call: MethodCall, result: MethodChannel.Result) {
        val remoteId = call.argument<String>("remoteId")
        if (StravaWebClient.activityUrl(remoteId) == null) {
            result.error("invalid_arguments", "远端活动 ID 必须为数字", null)
            return
        }
        val cookie = StravaWebClient.normalizeCookieHeader(store.get(COOKIE_ACCOUNT))
        if (cookie == null) {
            result.error("web_not_ready", "Strava 网页登录已失效，请重新登录", null)
            return
        }
        val operationId = beginWeb(WebOperation.DELETING, result) ?: return
        val client = StravaWebClient()
        webClient = client
        webTask = webExecutor.submit {
            try {
                client.deleteActivity(remoteId, cookie)
                webHandler.post { finishWeb(operationId) { it.success(null) } }
            } catch (_: Exception) {
                webHandler.post {
                    finishWeb(operationId) {
                        it.error("web_delete_failed", "网页删除未确认，活动可能已删除，请检查后重试",
                            mapOf("retryable" to false, "mayHaveDeleted" to true))
                    }
                }
            }
        }
    }

    private fun readWebActivitySpeedData(store: SecretStore, call: MethodCall, result: MethodChannel.Result) {
        val remoteId = call.argument<String>("remoteId")
        if (StravaWebClient.activityUrl(remoteId) == null) {
            result.error("invalid_arguments", "远端活动 ID 必须为数字", null)
            return
        }
        val cookie = StravaWebClient.normalizeCookieHeader(store.get(COOKIE_ACCOUNT))
        if (cookie == null) {
            result.error("web_not_ready", "Strava 网页登录已失效，请重新登录", null)
            return
        }
        val operationId = beginWeb(WebOperation.LISTING, result) ?: return
        val client = StravaWebClient()
        webClient = client
        webTask = webExecutor.submit {
            try {
                val payload = client.readActivitySpeedData(remoteId, cookie)
                webHandler.post { finishWeb(operationId) { it.success(payload) } }
            } catch (_: Exception) {
                webHandler.post {
                    finishWeb(operationId) { it.error("web_list_failed", "无法读取 Strava 活动详情，请重试", null) }
                }
            }
        }
    }

    private fun listWebActivityPage(store: SecretStore, call: MethodCall, result: MethodChannel.Result) {
        fun integer(name: String): Long? = when (val value = call.argument<Any>(name)) {
            is Int -> value.toLong()
            is Long -> value
            else -> null
        }
        val page = integer("page")
        val afterMs = integer("afterMs")
        val beforeMs = integer("beforeMs")
        if (page == null || page !in 1L..200L || afterMs == null || beforeMs == null ||
            StravaWebClient.activityPageUrl(page.toInt(), afterMs, beforeMs) == null
        ) {
            result.error("invalid_arguments", "网页列表需要有效页码和日期区间", null)
            return
        }
        val cookie = StravaWebClient.normalizeCookieHeader(store.get(COOKIE_ACCOUNT))
        if (cookie == null) {
            result.error("web_not_ready", "Strava 网页登录已失效，请重新登录", null)
            return
        }
        val operationId = beginWeb(WebOperation.LISTING, result) ?: return
        val client = StravaWebClient()
        webClient = client
        webTask = webExecutor.submit {
            try {
                val response = client.listActivityPage(page.toInt(), afterMs, beforeMs, cookie)
                val json = response.text()
                val root = JSONObject(json)
                check(response.statusCode == 200 && (root.optJSONArray("models") != null || root.optJSONArray("activities") != null))
                webHandler.post { finishWeb(operationId) { it.success(json) } }
            } catch (_: Exception) {
                webHandler.post {
                    finishWeb(operationId) {
                        it.error("web_list_failed", "无法读取 Strava 网页活动列表，请重新登录后重试", mapOf("retryable" to true))
                    }
                }
            }
        }
    }

    private fun uploadWebFit(store: SecretStore, call: MethodCall, result: MethodChannel.Result) {
        val filename = call.argument<String>("filename")
        val data = call.argument<ByteArray>("data")
        if (!StravaWebClient.isSafeUploadFilename(filename) || data == null ||
            data.isEmpty() || data.size > StravaWebClient.MAX_FIT_BYTES
        ) {
            result.error("invalid_arguments", "网页上传需要 FIT 字节和安全文件名", null)
            return
        }
        val cookie = StravaWebClient.normalizeCookieHeader(store.get(COOKIE_ACCOUNT))
        if (cookie == null) {
            result.error("web_not_ready", "Strava 网页登录已失效，请重新登录", null)
            return
        }
        val operationId = beginWeb(WebOperation.UPLOADING, result) ?: return
        val client = StravaWebClient()
        webClient = client
        webTask = webExecutor.submit {
            try {
                val payload = client.upload(data, filename, cookie)
                webHandler.post { finishWeb(operationId) { it.success(payload) } }
            } catch (_: Exception) {
                webHandler.post {
                    finishWeb(operationId) {
                        it.error(
                            "web_upload_failed", "网页上传失败，Strava 可能已收到文件，请检查后重试",
                            mapOf("retryable" to false, "mayHaveUploaded" to true),
                        )
                    }
                }
            }
        }
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
                    "refreshToken" to store.get("onelap.refresh"),
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
                val refreshToken = call.argument<String>("refreshToken")
                if (refreshToken.isNullOrBlank()) store.delete("onelap.refresh")
                else store.set("onelap.refresh", refreshToken)
                result.success(null)
            }
            "clearXingzheAuthorization" -> {
                listOf("xingzhe.account", "xingzhe.password", "xingzhe.session").forEach(store::delete)
                result.success(null)
            }
            "clearOnelapAuthorization" -> {
                listOf("onelap.account", "onelap.password", "onelap.token", "onelap.uid", "onelap.refresh").forEach(store::delete)
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
            "sync_preview_policy",
            "write_to_apple_health",
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
