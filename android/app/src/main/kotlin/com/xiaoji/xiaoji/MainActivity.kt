package com.xiaoji.xiaoji

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 只做一件事：把「长按图标 → 新建小记」这个快捷方式动作交给 Dart 侧。
 *
 * 冷启动时动作在 getIntent() 里，Dart 通过 consumeInitialAction 取一次；
 * 应用已在后台时走 onNewIntent，直接 invoke 给正在运行的引擎。
 */
class MainActivity : FlutterActivity() {

    private var pendingAction: String? = null
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // 必须在 super.onCreate 之前读，super 之后 intent 可能已被引擎消费。
        pendingAction = intent?.getStringExtra(EXTRA_ACTION)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeInitialAction" -> {
                    result.success(pendingAction)
                    pendingAction = null
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val action = intent.getStringExtra(EXTRA_ACTION) ?: return
        val target = channel
        if (target != null) {
            target.invokeMethod("shortcut", action)
        } else {
            pendingAction = action
        }
    }

    companion object {
        private const val CHANNEL = "xiaoji/shortcuts"
        private const val EXTRA_ACTION = "xiaoji.action"
    }
}
