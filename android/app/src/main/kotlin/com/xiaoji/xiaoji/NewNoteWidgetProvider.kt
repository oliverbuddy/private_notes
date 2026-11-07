package com.xiaoji.xiaoji

import android.app.PendingIntent
import android.app.WallpaperManager
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
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
        updateWidgets(context, appWidgetManager, appWidgetIds)
    }

    /**
     * 启动器调整/重新布局后重新计算标题是否显示。
     *
     * 1 行单元格在不同启动器上是 40–72dp：内容（卡片 40 + 间距 4 + 标题）
     * 在矮宿主里会超出并被裁切。这里按宿主给的最小高度决定是否显示标题，
     * 保证任何启动器都不会出现「标题只剩一半」。
     */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        updateWidgets(context, appWidgetManager, intArrayOf(appWidgetId))
    }

    private fun updateWidgets(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (widgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_new_note)
            val pending = newNoteIntent(context)
            // 整块卡片与卡片外的留白都可点。
            views.setOnClickPendingIntent(R.id.widget_root, pending)
            views.setOnClickPendingIntent(R.id.widget_card, pending)
            // 卡片下方的标题直接画在壁纸上，颜色必须跟着壁纸深浅走，
            // 否则浅色壁纸配白字会「看起来没有标题」（真机上出现过）。
            views.setTextColor(R.id.widget_title, titleColor(context))
            views.setViewVisibility(
                R.id.widget_title,
                if (shouldShowTitle(appWidgetManager, widgetId)) View.VISIBLE else View.GONE,
            )
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    /// 宿主高度未知（0）时按「能显示」处理；内容本身约 54dp，
    /// 留 2dp 余量，低于 56dp 的宿主直接隐藏标题。
    private fun shouldShowTitle(appWidgetManager: AppWidgetManager, widgetId: Int): Boolean {
        val minHeight = appWidgetManager.getAppWidgetOptions(widgetId)
            .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
        return minHeight <= 0 || minHeight >= 56
    }

    /**
     * 标题颜色：浅色壁纸用深色字，深色壁纸用白字（与桌面给图标名称自动反色的做法一致）。
     * 读不到壁纸颜色时退回白色——深色壁纸是默认壁纸最常见的形态。
     */
    private fun titleColor(context: Context): Int {
        val lightText = Color.WHITE
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) return lightText
        return try {
            val colors = WallpaperManager.getInstance(context)
                .getWallpaperColors(WallpaperManager.FLAG_SYSTEM)
            val primary = colors?.primaryColor?.toArgb() ?: return lightText
            // 感知亮度：绿色权重最高，符合人眼对明暗的判断。
            val luminance = (299 * Color.red(primary) +
                587 * Color.green(primary) +
                114 * Color.blue(primary)) / 1000
            if (luminance > 150) Color.parseColor("#2C2C2A") else lightText
        } catch (error: Exception) {
            Log.w(TAG, "读取壁纸颜色失败，标题使用白色", error)
            lightText
        }
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

    private companion object {
        const val TAG = "NewNoteWidget"
    }
}
