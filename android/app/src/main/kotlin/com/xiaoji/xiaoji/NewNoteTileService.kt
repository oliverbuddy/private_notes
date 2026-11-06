package com.xiaoji.xiaoji

import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * 快捷设置磁贴「新建小记」。
 *
 * Android 从 5.0 起移除了第三方锁屏小组件，磁贴是现在最接近
 * 「锁屏/下拉面板一键记录」的入口。点击后等同于桌面快捷方式：
 * 带上 [MainActivity.EXTRA_ACTION] 启动，走同一条新建笔记路径。
 */
class NewNoteTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        tile.state = Tile.STATE_INACTIVE
        tile.label = getString(R.string.shortcut_new_note_long)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.icon = Icon.createWithResource(this, R.drawable.ic_widget_pen)
        }
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra(MainActivity.EXTRA_ACTION, MainActivity.ACTION_NEW_NOTE)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pending = android.app.PendingIntent.getActivity(
                this,
                0,
                intent,
                android.app.PendingIntent.FLAG_IMMUTABLE or
                    android.app.PendingIntent.FLAG_UPDATE_CURRENT,
            )
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
