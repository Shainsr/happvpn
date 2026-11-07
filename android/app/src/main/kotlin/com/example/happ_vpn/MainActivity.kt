package com.example.happ_vpn

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.TileService
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider

class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "com.example.happ_vpn/quick_controls"
        const val PREFS_NAME = "FlutterSharedPreferences"
        const val KEY_CONNECTED = "flutter.bg_vpn_connected"
        const val ACTION_SILENT_TOGGLE = "com.example.happ_vpn.ACTION_SILENT_TOGGLE"

        var activeChannel: MethodChannel? = null
        private var headlessEngine: FlutterEngine? = null

        fun triggerBackgroundToggle(context: Context) {
            val appContext = context.applicationContext
            // ۱. اگر برنامه در پس‌زمینه باز است، مستقیماً از طریق کانال فعال قطع/وصل شود (بدون باز شدن صفحه)
            if (activeChannel != null) {
                activeChannel?.invokeMethod("quickToggleVpn", null)
                return
            }

            // ۲. اگر برنامه کاملاً بسته شده است، موتور Headless بدون هیچ صفحه‌ای در پس‌زمینه اجرا شود
            try {
                // هر کلیک باید یک اجرای تازه از entrypoint داشته باشد؛ اجرای دوبارهٔ
                // Dart entrypoint روی همان engine ممکن است نادیده گرفته شود.
                headlessEngine?.destroy()
                headlessEngine = null

                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(appContext)
                loader.ensureInitializationComplete(appContext, null)

                headlessEngine = FlutterEngine(appContext).apply {
                    MethodChannel(dartExecutor.binaryMessenger, CHANNEL)
                        .setMethodCallHandler { call, result ->
                            if (call.method == "setConnectionState") {
                                val connected = call.argument<Boolean>("connected") ?: false
                                updateNativeState(appContext, connected)
                                result.success(true)
                            } else {
                                result.notImplemented()
                            }
                        }
                }

                val appBundlePath = FlutterInjector.instance().flutterLoader().findAppBundlePath()
                val entrypoint = DartExecutor.DartEntrypoint(appBundlePath, "vpnBackgroundMain")
                headlessEngine?.dartExecutor?.executeDartEntrypoint(entrypoint)
            } catch (_: Exception) {
            }
        }

        fun updateNativeState(context: Context, connected: Boolean) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().putBoolean(KEY_CONNECTED, connected).apply()

            // بروزرسانی آنی ویجت صفحه اصلی
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, VpnHomeWidgetProvider::class.java))
            if (ids.isNotEmpty()) {
                val intent = Intent(context, VpnHomeWidgetProvider::class.java).apply {
                    action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                }
                context.sendBroadcast(intent)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                TileService.requestListeningState(
                    context,
                    ComponentName(context, VpnQuickSettingsTileService::class.java)
                )
            }
        }
    }

    private val silentReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_SILENT_TOGGLE && context != null) {
                triggerBackgroundToggle(context)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val filter = IntentFilter(ACTION_SILENT_TOGGLE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(silentReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(silentReceiver, filter)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        activeChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setConnectionState" -> {
                    val connected = call.argument<Boolean>("connected") ?: false
                    updateNativeState(applicationContext, connected)
                    result.success(true)
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("ARG", "path missing", null)
                    } else {
                        result.success(installApk(path))
                    }
                }
                "consumePendingAction" -> {
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun installApk(path: String): String {
        val file = java.io.File(path)
        if (!file.exists()) return "missing"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()) {
            val settings = Intent(
                android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                android.net.Uri.parse("package:$packageName")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(settings)
            return "permission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        return "ok"
    }

    override fun onDestroy() {
        if (activeChannel != null) {
            activeChannel = null
        }
        try {
            unregisterReceiver(silentReceiver)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }
}