
package com.example.happ_vpn

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class VpnQuickSettingsTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        refreshTileState()
    }

    override fun onClick() {
        super.onClick()

        val prepareIntent = VpnService.prepare(this)

        if (prepareIntent != null) {
            val openIntent = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivityAndCollapse(openIntent)
            return
        }

        qsTile?.apply {
            label = "SHIN"
        }

        MainActivity.triggerBackgroundToggle(applicationContext)
    }

    private fun refreshTileState() {
        val prefs = getSharedPreferences(
            MainActivity.PREFS_NAME,
            Context.MODE_PRIVATE
        )

        val isConnected = prefs.getBoolean(
            MainActivity.KEY_CONNECTED,
            false
        )

        qsTile?.apply {
            state = if (isConnected) {
                Tile.STATE_ACTIVE
            } else {
                Tile.STATE_INACTIVE
            }

            label = "SHIN"
            updateTile()
        }
    }
}
