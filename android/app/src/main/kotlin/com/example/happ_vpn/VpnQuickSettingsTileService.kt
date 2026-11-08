package com.example.happ_vpn

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class VpnQuickSettingsTileService : TileService() {

    companion object {
        fun requestTileSync(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                try {
                    requestListeningState(
                        context,
                        ComponentName(context, VpnQuickSettingsTileService::class.java)
                    )
                } catch (_: Exception) {}
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        syncTileState()
    }

    override fun onClick() {
        super.onClick()
        val ch = MainActivity.activeChannel
        if (ch != null) {
            ch.invokeMethod("quickToggleVpn", null)
            return
        }

        val launchIntent = Intent(this, MainActivity::class.java).apply {
            action = MainActivity.ACTION_QUICK_TOGGLE_VPN
            putExtra("quick_toggle_vpn", true)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pendingIntent = PendingIntent.getActivity(
                this,
                2001,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            startActivityAndCollapse(pendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(launchIntent)
        }
    }

    private fun syncTileState() {
        val tile = qsTile ?: return
        val prefs = getSharedPreferences(MainActivity.PREFS_NAME, Context.MODE_PRIVATE)
        val connected = prefs.getBoolean("flutter.bg_vpn_connected", false)
        val remark = prefs.getString("flutter.native_ready_remark", "SHIN") ?: "SHIN"

        tile.state = if (connected) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "SHIN"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (connected) remark else "Disconnected"
        }
        tile.updateTile()
    }
}
