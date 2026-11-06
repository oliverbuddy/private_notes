package com.xiaoji.xiaoji

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * 桌面小组件：「记一条」。
 *
 * 产品上这是最短路径 —— 解锁手机后点一下，直接落到空白编辑页并弹出键盘，
 * 中间不经过列表、不经过任何菜单。点击复用 `xiaoji.action=new_note`
 * 这条已有通道（与长按图标快捷方式同一套），所以冷启动和热启动都走现成逻辑。
 */
class NewNoteWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val views = RemoteViews(context.packageName, R.layout.widget_new_note)
        val pending = newNoteIntent(context)
        // 整块卡片与卡片外的留白都可点。
        views.setOnClickPendingIntent(R.id.widget_root, pending)
        views.setOnClickPendingIntent(R.id.widget_card, pending)
        appWidgetManager.updateAppWidget(appWidgetIds, views)
    }

    /** 点小组件 → 拉起 MainActivity，带一个「新建小记」动作。 */
    private fun newNoteIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra(MainActivity.EXTRA_ACTION, MainActivity.ACTION_NEW_NOTE)
            // CLEAR_TOP：App 已在后台时复用同一个任务栈，不会再叠一个实例。
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            // 同一个 PendingIntent 反复使用：内容固定，用 UPDATE_CURRENT 覆盖。
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
