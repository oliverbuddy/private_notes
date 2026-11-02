# 小记 App — 项目规范（所有代码生成必须遵守）

## 一、UI 设计规范（国内主流 + 本项目定稿）

### 设计 Token（禁止字面量散落）
- 颜色/字号/间距/圆角一律走 `lib/theme/app_theme.dart` 的 `AppColors`/`AppText`/`AppSpace`/`AppRadius`，业务代码出现字面量色值即违规。
- 字阶：页面标题 22 / 弹层标题 17 / 正文 16 / 编辑正文 17 / 辅助 13.5-13 / 最小 12；中文标题加 letterSpacing 0.2-0.3。
- 字重只有 400/500/600 三档（`AppWeight`）；标题类必须 600（中文 500 与 400 几乎无差）。
- 间距只用 4 的倍数；页面左右边距统一 20。
- 主色唯一：系统蓝 #0A6CFF（深色 #7DB2FF）；破坏性操作必须用 `danger` 红，不得复用强调色。
- 深色不是反色：底 #161514 非纯黑；**表面三档层级必须分明**：page #161514（页面底）< pageAlt #201F1D（卡片/分组）< surface2 #232220（嵌套表面）。深色下「卡片与底色对调」：浅色米底白卡、深色黑底亮卡，卡片永远比底色亮一档——pageAlt 在深色下是卡片表面，禁止拿来当页面背景。深色下所有「比底色亮一档」的元素（分隔线/命中底/抓手）要专门核对可见度。

### 组件惯例
- 底部弹层统一走 `showXiaojiSheet`：grabber 居中 32×4（text 色 20% 透明度）、弹层恒与屏同宽、行高 52、危险操作红色实心按钮。**禁止自建 AnimationController**（会卡死弹层），动画全交 AnimationStyle。
- 列表分隔线左缩进 20 与文字对齐；触控目标 ≥40dp；FAB 54。
- 列表两档：**舒适档 = 卡片浮在 pageAlt 上（浅色米底白卡 / 深色黑底亮卡）；紧凑档 = 单行正文 + 右侧时间，坐在 page 纯底上**，两档视觉语义必须分开（混用会让紧凑档文字糊进背景）。
- 键盘避让必须用 **Scaffold resizeToAvoidBottomInset: true**（视口真正缩短）：EditableText 的 scrollPadding 语义是「光标距视口底」，视口全高时把它写成键盘高度会把光标推到视口顶（内容页上滚）。工具条浮层 bottom=0（Stack 底边=键盘上沿），ListView bottomPadding=工具条高+16，scrollPadding 恒定 12。
- 中文排版：不用斜体（伪斜难看）；强调用 600；标题前留段前空档（阅读态自动补）。

### 已踩死的坑（改到这些区域先读注释）
- BottomSheet 的 pop Future 在**退场动画开始前**完成：弹层内 TextEditingController 必须归 StatefulWidget 自己 dispose，禁止 pop 后立刻 dispose（debug 包会炸 `_dependents.isEmpty`）。
- 弹层宽度约束是 loose 的：纯 shrink-wrap 内容会缩成一条，统一入口已用 stretch + SizedBox(infinity) 修掉。
- 收键盘：`_hideKeyboard` = `TextInput.hide` + unfocus + `_focusedEntry = null`（单态里点正文会重建连接，不需要再保着 connection）。
- **编辑器的文本监听必须先判断 `text == lastText`**：controller 的 listener 也会因「仅选区变化」触发，不短路就会把「点一下看内容」当成编辑，刷新 `updated` 把笔记顶到列表最前。
- **单态编辑的不变量：任何时刻只有一个 TextField**（聚焦块），其余块是渲染态；测试断言按此写。
- **凡是改动 `_focusedEntry` 所指块的操作用（合并、插入附件、删除块、撤销还原），必须同步 `_focusedEntry` 再 requestFocus** —— 只 requestFocus 不同步的话那块还是渲染态，焦点无处落地：键盘收起、光标消失。
- 撤销/重做用块结构快照（不是拼接的 markdown：相邻文本块会糊成一块）；打字按 800ms 合并，结构改动各占一步，且结构改动后**下一次打字必须另起一步**。
- 输入即转换（`[] ` → `- [ ] `）必须走 `TextInputFormatter`，不能在监听器里改写 controller（会输入法被覆盖）；组词期间样式也不能退回默认实现，自己叠下划线。
- 回车拆块用**字符级前后缀对齐**定位插入的 `\n`（IME 会批量提交），不要用行级 diff 或「+1 字符」判断；右侧以块级记号开头时另起一行，别拼成 `4. 4. xxx`；空列表项回车只去记号、不插新块。
- 有序列表编号由 `OrderedListNumberingCursor` 跨块重排（空行/普通段落/图片块断开一组）；插入或删除一行后必须调用，否则出现 `1.2.3.3.`。删空的记号行要整行移除（`_removeEmptiedMarkerLines`），否则空行打断编号组。
- **块类型互斥**：改块类型 = 剥全部旧记号 + 加新记号（否则 `-> `、`## > ` 堆叠）；同类型再点 = 取消（按类型判断）；「正文」只剥标题不动列表。
- **滚动定位只看光标，不看块**：整篇常是一个大 TextBlock，块顶永远在视口上方，按块判断会把页面滚到顶（`_ensureVisible` 用 `_caretRectInGlobal`）。浮层必须 `Listener(behavior: opaque)` 吞空白点击，否则穿透正文挪光标、命令改错行。
- **性能铁律：正则一律 `static final`**——按键热路径里每行编译正则 = 真机卡顿；`buildTextSpan` 按 text+样式缓存整棵 span 树（光标移动/键盘动画每帧都重建）；行内循环按代理对取字符（emoji 不能切进两个 span）。
- 图片查看器：`InteractiveViewer` 的视口必须是整屏（包一层 SizedBox = 视口尺寸）。视口只有图片那么大的话，双击放大后被小视口裁掉一块；同时 `SingleTickerProviderStateMixin` 撑不住两个 AnimationController（双击必崩），要用 `TickerProviderStateMixin`。
- Android 12+ 启动画面默认把桌面图标放大居中（观感像「闪一下图标」）：`values-v31/styles.xml` 里把 `windowSplashScreenAnimatedIcon` 指向透明 drawable，底色对齐 App 首帧。
- 验证光标类 bug：格式化后立即输入字符看落点，截图不可靠；对齐问题用 BMP 像素扫描实测，别靠几何推导。

## 二、工程纪律
- 每次 Edit 后**立即** `flutter analyze`（历史上两次批量替换插坏括号结构）；大文件多处相似结构时用括号扫描器定位。
- `flutter test` 必须 `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy`（flutter_tester 的本地 WebSocket 被代理拦截会全挂）。
- **交互验证一律装 debug 包**（assert 是活的，能抓 release 剥掉的真 bug）；release 只做最终交付。验证用模拟器做交互实测，不动用户正在用的真机。
- python 批量替换后必须立即 analyze + test——曾把静态字段声明替换成自引用（`static final x = x;`）导致 StackOverflow。
- 构建 JDK：corretto 18（`flutter config --jdk-dir` 已配置）。
- 数据全本地：md 文件唯一数据源、临时文件+rename 原子写、删除进 trash/；无账号无网络（不加任何联网权限）。

## 三、验证流程（每轮改动后）
analyze 零问题 → 全量测试通过 → debug 包模拟器实测（明/暗 × 相关页面截图逐项确认）→ release APK 装真机 → 更新 README（如有行为变化）→ 追加 `.workbuddy/memory/YYYY-MM-DD.md` 日志。
