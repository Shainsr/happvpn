package com.example.happ_vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.example.happ_vpn/quick_controls"
        const val ACTION_QUICK_TOGGLE_VPN = "com.example.happ_vpn.ACTION_QUICK_TOGGLE_VPN"
        const val ACTION_SAFE_DISCONNECT_VPN = "com.example.happ_vpn.ACTION_SAFE_DISCONNECT_VPN"
        const val PREFS_NAME = "FlutterSharedPreferences"
        var activeChannel: MethodChannel? = null
        var pendingAction: String? = null
    }

    private val disconnectReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_SAFE_DISCONNECT_VPN) {
                activeChannel?.invokeMethod("safeDisconnectVpn", null)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val filter = IntentFilter(ACTION_SAFE_DISCONNECT_VPN)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(disconnectReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(disconnectReceiver, filter)
        }
        handleIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    private fun handleIncomingIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.action == ACTION_SAFE_DISCONNECT_VPN ||
            intent.getBooleanExtra("safe_disconnect_vpn", false)
        ) {
            intent.removeExtra("safe_disconnect_vpn")
            activeChannel?.invokeMethod("safeDisconnectVpn", null)
            return
        }
        if (intent.action == ACTION_QUICK_TOGGLE_VPN ||
            intent.getBooleanExtra("quick_toggle_vpn", false)
        ) {
            intent.removeExtra("quick_toggle_vpn")
            val ch = activeChannel
            if (ch != null) {
                ch.invokeMethod("quickToggleVpn", null)
            } else {
                pendingAction = "toggleVpn"
            }
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
                    val status = call.argument<String>("status") ?: if (connected) "CONNECTED" else "DISCONNECTED"
                    saveNativeConnectionState(this, connected, status)
                    VpnHomeWidgetProvider.updateAllWidgets(this)
                    VpnQuickSettingsTileService.requestTileSync(this)
                    result.success(true)
                }
                "consumePendingAction" -> {
                    val act = pendingAction
                    pendingAction = null
                    result.success(act)
                }
                "getLaunchableApps" -> {
                    result.success(getInstalledLaunchableApps())
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("INVALID_PATH", "APK path is empty", null)
                    } else {
                        result.success(installApkFile(path))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(disconnectReceiver)
        } catch (_: Exception) {}
        if (activeChannel != null) {
            activeChannel = null
        }
        super.onDestroy()
    }

    private fun saveNativeConnectionState(context: Context, connected: Boolean, status: String) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .putBoolean("flutter.bg_vpn_connected", connected)
            .putString("flutter.bg_vpn_status", status)
            .apply()
    }

    private fun getInstalledLaunchableApps(): List> {
        val pm = packageManager
        val mainIntent = Intent(Intent.ACTION_MAIN, null).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val resolveInfos = pm.queryIntentActivities(mainIntent, 0)
        val list = mutableListOf>()
        val seen = mutableSetOf<String>()

        for (ri in resolveInfos) {
            val pkg = ri.activityInfo?.packageName ?: continue
            if (pkg == packageName || !seen.add(pkg)) continue
            val label = ri.loadLabel(pm)?.toString() ?: pkg
            list.add(mapOf("name" to label, "package" to pkg))
        }
        return list
    }

    private fun installApkFile(path: String): String {
        val file = File(path)
        if (!file.exists()) return "missing"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (!packageManager.canRequestPackageInstalls()) {
                val permIntent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(permIntent)
                return "permission"
            }
        }

        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file
        )
        val installIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(installIntent)
        return "ok"
    }
}
