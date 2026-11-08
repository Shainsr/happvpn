package com.example.happ_vpn

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.RemoteViews

class VpnHomeWidgetProvider : AppWidgetProvider() {

    companion object {
        const val ACTION_WIDGET_TOGGLE_VPN = "com.example.happ_vpn.ACTION_WIDGET_TOGGLE_VPN"

        fun updateAllWidgets(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, VpnHomeWidgetProvider::class.java))
            if (ids.isNotEmpty()) {
                val intent = Intent(context, VpnHomeWidgetProvider::class.java).apply {
                    action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                }
                context.sendBroadcast(intent)
            }
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (widgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, widgetId)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_WIDGET_TOGGLE_VPN) {
            val ch = MainActivity.activeChannel
            if (ch != null) {
                ch.invokeMethod("quickToggleVpn", null)
            } else {
                val launchIntent = Intent(context, MainActivity::class.java).apply {
                    action = MainActivity.ACTION_QUICK_TOGGLE_VPN
                    putExtra("quick_toggle_vpn", true)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                }
                context.startActivity(launchIntent)
            }
        }
    }

    private fun updateWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        val prefs = context.getSharedPreferences(MainActivity.PREFS_NAME, Context.MODE_PRIVATE)
        val connected = prefs.getBoolean("flutter.bg_vpn_connected", false)
        val remark = prefs.getString("flutter.native_ready_remark", "SHIN VPN") ?: "SHIN VPN"

        val views = RemoteViews(context.packageName, R.layout.widget_vpn)
        views.setInt(
            R.id.widget_root,
            "setBackgroundResource",
            if (connected) R.drawable.widget_vpn_background_on else R.drawable.widget_vpn_background
        )
        views.setTextViewText(R.id.widget_status_text, if (connected) "متصل" else "قطع")
        views.setTextViewText(R.id.widget_server_text, remark)
        views.setTextViewText(R.id.widget_action_button, if (connected) "قطع اتصال" else "اتصال")

        val toggleIntent = Intent(context, VpnHomeWidgetProvider::class.java).apply {
            action = ACTION_WIDGET_TOGGLE_VPN
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingToggle = PendingIntent.getBroadcast(context, 1001, toggleIntent, flags)
        views.setOnClickPendingIntent(R.id.widget_action_button, pendingToggle)

        val openAppIntent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pendingOpen = PendingIntent.getActivity(context, 1002, openAppIntent, flags)
        views.setOnClickPendingIntent(R.id.widget_root, pendingOpen)

        appWidgetManager.updateAppWidget(appWidgetId, views)
    }
}
