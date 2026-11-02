# 小记

一个本地优先的 Markdown 小记应用。形态对齐语雀小记，砍掉所有依赖服务端的能力。
无账号、无网络、无同步 —— 内容就是一群 `.md` 文件。

## 状态

| 项 | 值 |
|---|---|
| 版本 | 0.1.0 |
| 平台 | Android（已出 APK）；iOS 工程未生成 |
| 测试 | `flutter test` 238 / 238 通过 |
| 静态检查 | `flutter analyze` No issues found |
| APK | `build/app/outputs/flutter-apk/app-release.apk`，51.8MB，包名 `com.xiaoji.xiaoji` |
| 真机验证 | 已在 Android 17（1272×2772）上验过主流程；拍照/选文件的运行时权限未覆盖 |

## 功能

**做了**：无标题快速记录 · 自动保存 · 时间线列表（舒适 / 紧凑两档密度）· 标签与筛选（可删标签）·
**单态块编辑**（浏览即最终效果，点哪块编哪块，收起键盘回到浏览）· **撤销 / 重做** ·
输入即转换（`[] ` → 待办、`* ` → 减号）· 代码围栏内回车不拆块 ·
回车自动续列表（有序递增、待办重置、空项退出）· **有序列表插入/删除后自动重编号** ·
标签候选 · 长按系统选择菜单（中文）· Markdown 实时样式渲染 ·
底栏 图片/待办/列表/引用/Aa + 收起键盘（不横滑）· 图片与附件 ·
全弹窗统一底部弹层（`showXiaojiSheet`：grabber + 320ms 曲线动画）· 列表「到底了」提示 ·
置顶 · 全文搜索（含高亮）· 删除进回收站 · 一键导出 · 明暗双主题 ·
**长按桌面图标「新建小记」**

**明确不做**：分享链接（需服务端）· 知识库 / 生成文档 · 归档 · 版本历史 ·
批量操作 · 账号与同步

## 数据格式

一条小记 = 一个 `.md` 文件：

```
<appDocuments>/Xiaoji/
├── notes/2026/10/20261031-0912-a1b2.md
├── assets/20261031-0912-a1b2/1.jpg
├── trash/                          删除的笔记移到这里，不做恢复界面
├── export-20261031-1300/           导出产物
└── settings.json                   {"theme":"system","density":"comfortable"}
```

正文头是 frontmatter：

```markdown
---
id: 20261031-0912-a1b2
created: 2026-10-31T09:12:33
updated: 2026-10-31T09:15:10
tags: 旅行, 想法
pinned: false
---

大理的院子，早上六点的光刚好落在墙上。

![](assets/20261031-0912-a1b2/1.jpg)
```

要点：

- **没有 archived 字段**，归档功能已砍掉
- 图片和附件存在**按笔记分目录**的 `assets/<id>/` 里，删笔记时整目录一起删，不留孤儿文件
- 正文用**相对路径**引用附件，整个 `Xiaoji/` 目录拷走仍可打开
- 写入一律「先写 `.tmp` 再 rename」，防止进程被杀导致文件截断
- 单条文件解析失败会被跳过，不会让应用起不来

## 编辑器架构

Flutter 的 `TextField` 没有原生附件机制（原生 iOS 有 `NSTextAttachment`），图片无法塞进文本框，
所以编辑器是**块结构**：

| 块类型 | 内容 |
|---|---|
| `TextBlock` | 连续文本行，内部仍是原始 markdown，由自定义 `TextEditingController` 渲染样式 |
| `ImageBlock` | 独占一行的 `![alt](相对路径)` |
| `FileBlock` | 独占一行的 `[文件名](相对路径)`，渲染成文件卡片 |

**只改样式，不改文本** —— 输入框内容永远是原始 markdown，`##`、`**`、`- [ ]` 这些符号
用淡色渲染（浅色 `#D3D1C7` / 深色 `#4F4D47`），被标记的内容直接呈现粗体、放大字号、等宽。
落盘所见即所得，同时手机上不用分屏预览就有排版感。

块解析与序列化保证**往返无损**（`serialize(parse(md)) == md`，末尾换行归一化除外）。
图片/文件块会保留行尾空白与 `\r`（`trailing` 字段），所以被 Windows 编辑器改过的 `.md` 也能正常识别。
缩进的图片语法刻意**不**识别成图片块 —— 那通常是列表/引用里的文本，抽成 widget 会把句子切碎。

### 单态编辑（对齐语雀）

浏览和编辑是**同一个状态**，没有「阅读态 / 编辑态」的切换，也没有「完成」按钮：

| | 表现 |
|---|---|
| 未聚焦的块 | 按最终效果渲染：记号剔除、待办可直接点选、图片可预览 |
| 聚焦的块 | 同一 entry 换成 `TextField`，markdown 源码 + 记号淡显（其余块保持渲染） |
| 进编辑 | 点哪块编哪块，光标落在点击的位置 |
| 退出编辑 | 收起键盘即回到全渲染浏览；自动保存一直在跑，没有要「提交」的状态 |

两套渲染共用同一份语法规则（`markdown_view.dart` 与 `markdown_controller.dart` 要一起改）：
编辑态不能真删记号，因为字符一旦消失，光标偏移就对不上文本了；未聚焦时可以随便删。

**主页摘要走的是同一套渲染**（`excerptSource` + `markdownSpans`），所以列表里看到的标题、
加粗、有序列表已经和点进去后一样 —— 只是不吃空行、最多 6 行。搜索时退回纯文本，因为要按关键字高亮。

### 回车规则

列表续行由 `block.dart` 的 `continuationFor()` 单点决定，有 13 条单测钉着：

| 当前行 | 回车后新块 |
|---|---|
| `1. xxx` | `2. `（保留原来的 `.` / `)` 分隔符） |
| `- xxx` | `- ` |
| `- [ ] xxx` | `- [ ] `（勾过的也重置为未勾选） |
| `> xxx` | `> ` |
| 空的列表项 | 清掉标记，退出列表 |

最后一条是刻意比语雀多做的一步：语雀在空列表项上回车会留下一个空标记，
用户得自己删掉减号才出得来。

**有序列表会自己重编号**（`OrderedListNumberingCursor`）：连续的 `N. ` 行视为同一条列表，
从首个编号起依次 +1。在中间回车插一行、或删掉一行之后，后面的编号自动顺延，
不会出现 `1. 2. 3. 3. 4.`。列表可以跨块（回车拆块后编号仍然接得上），
而空行、普通段落、图片块都会断开一组 —— 宁可少改，也不去改远处无关的内容。

### 字阶与字重

设计稿按 296px 宽的手机画的，直接当 dp 用会整体偏小，实际按约 1.2 倍换算。
但更根本的问题是**字重**：中文只有 Regular / Medium 两个真实字面，全局只给 400/500 时，
标题和正文的粗细差几乎看不出来 —— 这是「字看着没精神」的真正原因。
所以引入三档：

| 档 | 用途 |
|---|---|
| `regular` 400 | 正文、列表摘要 |
| `medium` 500 | 弱强调（chip 选中、分组标签） |
| `semibold` 600 | 页面标题、文档标题、板块标题、动作按钮 |

字阶收在 `AppText`（`pageTitle` 22 / `sheetTitle` 17 / `body` 16 /
`meta` 12.5 / `caption` 12），间距收在 `AppSpace`（4 的倍数，页面边距统一 20），
圆角收在 `AppRadius`（`block` 8 / `card` 10 / `chip` 11）。
中文标题额外加 0.2–0.3 字距，横排才不觉得粘连。

**列表里的标题要降一档**：详情页 H1 是正文的 1.5 倍很合理，但列表里一行 25px 的标题
夹在 16px 正文中间，行高会跳得像排版事故。所以 `markdownSpans` 带一个 `headingBoost`，
摘要传 `0.78` —— 层级还在，节奏不崩。

### 工具条

结构对齐语雀小记：**底栏只放块级插入，行内格式收进 Aa 面板，长按走系统菜单**。

底栏五个格式按钮 + 三个文档级动作，全部一屏可见，**不横滑**（横滑没有任何视觉暗示，
第一屏之外的功能等于不存在）：

| 位置 | 命令 | 图标 |
|---|---|---|
| 1 | 图片与附件 | `image_outlined` |
| 2 | 待办 `- [ ] ` | `check_box_outlined` |
| 3 | 列表（面板：无序 / 有序） | `format_list_bulleted` |
| 4 | 引用 `> ` | `format_quote_rounded` |
| 5 | `Aa` 文字样式（正文 / 标题 1-3 按真实字号预览 + 加粗/斜体/删除线/行内码/链接） | 文字 `Aa`（语雀同款） |
| 6 | **撤销** | `undo`（无历史时置灰，但占位，避免整条工具栏抖动） |
| 7 | **重做** | `redo` |
| 右 | **收起键盘**（无「完成」：收键盘即回到浏览） | `keyboard_hide_outlined` |

选图标的原则：全部用 Material 里「一眼能懂」的主流字形，认不出的（如 `Icons.tag` 价签）
宁可不用 —— 标签走顶栏编辑。

顺带一个布局要点：**工具条是浮层，不参与 Column 布局**。它挂在
`Positioned(bottom: keyboardInset)` 上，键盘弹出时内容区高度不变 ——
否则列表视口被键盘高度挤矮，点一下正文整页就被顶上去一截。

长按文本用**系统选择菜单**（`contextMenuBuilder` 只把「粘贴」换成 markdown 识别粘贴）：
平台外观 + 中文文案由 `flutter_localizations` 提供。之前自绘的气泡在滚动时容易错位。

两个易踩的坑：
- **bottom sheet 会被键盘压住**。弹层要用 `MediaQuery.viewInsetsOf(context).bottom`
  让出键盘高度，否则面板整个藏在键盘后面，看起来像"点了没反应"。
- **打开弹层会让 TextField 失焦**。所以命令目标块不能去问"谁在聚焦"，
  要记一份 `_lastFocused`，否则命令会打到文末那段上。

### 撤销 / 重做

语雀有，我们不能没有 —— 手机上误删一段话，没有撤销就只能认。实现方式：

- 每次改动前把**块结构快照**压进栈（`_EditorSnapshot`：每块的类型 + 文本/路径 + 焦点块下标 + 光标）。
  不存拼接后的 markdown：两个相邻文本块在 markdown 里就是一个换行，拼起来再解析会糊成一块。
- 连续打字按 800ms 窗口**合并成一步**；回车拆块、合并块、格式命令**各占一步**
  （结构改动之后紧接着的打字会另起一步，否则撤销会连回车一起退掉、光标跳到上一段）。
- 撤销回落到「还没点进来」的那一帧时，**不把用户踢回浏览态**，留在当前块继续编。
- 外接键盘支持 ⌘/Ctrl+Z、⇧+Z。

### 输入即转换

语雀的 Markdown 快捷输入（`# ` / `- ` / `1. ` / `> `）我们本来就按 markdown 直接渲染，
真正需要转换的只有等价写法：`[] ` → `- [ ] `、`[x] ` → `- [x] `、`* `/`+ ` → `- `。
这些走 `TextInputFormatter`（`markdown_shortcut_formatter.dart`），而不是「监听文本变化后改写」——
组词期间改写文本会被输入法的下一次提交覆盖回去（真机上 `[] ` 只会变成 `- []`）。

同理，**输入法组词期间不再退回朴素样式**：以前整段交回默认实现，英文单词打到一半时
整个标题会突然变回正文字号；现在自己给组词区加下划线，样式照常生效。

### 桌面图标快捷方式

长按图标 →「新建小记」直接进编辑页，中间不经过列表。
`android/app/src/main/res/xml/shortcuts.xml` 里声明 intent，`MainActivity` 通过
`MethodChannel("xiaoji/shortcuts")` 把 `new_note` 交给 Dart（冷启动读一次、后台态走 `onNewIntent`）。

### 应用图标

一张带折角的便签 + 一支斜置的笔，笔尖压在最后一行蓝色的字上。
内容占图标 72%（自适应前景 52%）—— 图标必须留出呼吸边距，铺满反而廉价。
折角是「纸/文档」最经典的可读符号 —— 哪怕线条都看不清，一个折角也能让人读出这是笔记。

四个刻意的处理：
1. **笔用背景色描一圈**。白色笔压在白色纸上，没有这圈缝，48dp 下两者会糊成一整块。
2. **笔尖是「圆笔身 + 尖三角」两段拼的**，而且笔身只画到三角根部 ——
   画到笔尖会把尖头用圆头裹住，笔就不尖了。
3. **按内容占比缩放，不按 108 画布缩放**。自适应图标会被 mask 裁到中间 72/108，
   内容必须收进安全区；legacy 图标内容占 78%，foreground 占 58%。
4. **纸的圆角矩形要减掉折角三角再画**（距离场里做半平面剔除）。所有坐标必须先转
   像素再进距离场 —— 直接喂设计坐标会让 r 大于矩形半宽，整张纸凭空消失（踩过）。

`res/mipmap-*/ic_launcher.png` 与 `ic_launcher_foreground.png` 由脚本按同一套几何生成
（解析距离场 + 4x 超采样，无第三方依赖），自适应图标声明在
`mipmap-anydpi-v26/ic_launcher.xml`。改图标就改几何参数重新跑，不要手工修图 ——
五个密度和一个前景必须同源。

## 设计 token

三档字重：400 / 500 / 600。无阴影、无渐变、无模糊。
破坏性操作（删除确认、删除菜单项、删除图片）一律用 `danger` 红，
不复用强调色 —— 这是国内规范里最不能省的一条。

| | 浅色 | 深色 |
|---|---|---|
| 页面 | `#FFFFFF` | `#161514` |
| 页面底 / 卡片 | `#F7F5F0` | `#201F1D` |
| 主文字 | `#2C2C2A` | `#E9E7E2` |
| 次文字 | `#8F8C84` | `#8F8C84` |
| 弱文字 | `#A9A69D` | `#7C7972` |

列表时间格式：今天 `15:37` · 昨天 `昨天 15:37`（带时刻，微信同款）· 更早 `10月24日` ·
跨年 `2025年12月31日`。
| 分隔线 | `rgba(0,0,0,.06)` | `rgba(255,255,255,.07)` |
| 强调色 | `#0A6CFF` | `#7DB2FF` |
| 危险色 | `#DD4B4B` | `#FF7076` |

全 App 只有一处彩色（标签、链接、光标、选中态）。FAB 用墨黑，深色下反相为浅底深图标。

深色下有三处必须单独调，直接套浅色值会不可用：强调色要提亮（`#0A6CFF` → `#7DB2FF`），
标签底要抬到 `#1C2637`（否则和 `#161514` 的背景差几乎为零），弱文字要抬到 `#7C7972`
（`#6B6862` 在深底上只有 2.9:1 的对比度，时间戳会"发虚"）。

## 开发

```bash
export PATH="$HOME/development/flutter/bin:$PATH"
export ANDROID_HOME="$HOME/Library/Android/sdk"

flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

环境：Flutter 3.47.9 / Dart 3.13.7 / Android SDK 36 + build-tools 36 / JDK 18。

**跑测试前要清代理**，否则 `flutter_tester` 的 localhost WebSocket 会被拦：

```bash
env -u HTTP_PROXY -u HTTPS_PROXY flutter test
```

目录：

```
lib/main.dart
lib/theme/app_theme.dart                      颜色 token（ThemeExtension）+ 明/暗 ThemeData
lib/models/note.dart                          Note + frontmatter 编解码
lib/models/note_settings.dart                 主题 / 密度枚举 + json
lib/data/note_store.dart                      文件读写、附件、trash、导出、settings.json
lib/data/note_repository.dart                 ChangeNotifier：列表 / 搜索 / 筛选 / 排序
lib/editor/block.dart                         块模型 + parse / serialize + 列表续号 / 编号重排
lib/editor/markdown_controller.dart           记号淡显
lib/editor/markdown_toolbar.dart              工具条（底栏块级插入 + Aa 文字样式面板）
lib/editor/editor_page.dart                   单态块编辑器（浮层工具条 / 光标 / 自动保存）
lib/editor/widgets/image_block_view.dart      图片块 + 全屏查看器（微信式飞行转场）
lib/editor/widgets/file_block_view.dart       附件卡片
lib/home/home_page.dart                       标题栏 / 搜索态 / 标签筛选 / FAB / 空状态
lib/home/note_tile_comfortable.dart           舒适密度
lib/home/note_tile_compact.dart               紧凑密度
lib/settings/settings_page.dart               主题 / 密度 / 导出
lib/util/date_format.dart                     严格时间解析、相对时间、文件大小
lib/util/text_highlight.dart                  搜索命中高亮
```

## 已知限制

1. **真机只覆盖了主流程。** 已在 Android 17（1272×2772 / 560dpi）上逐项截图验证：
   冷启动、单态编辑（浏览 ↔ 聚焦）、标题与列表面板、长按系统菜单、工具条贴键盘、
   明暗主题、两档密度、桌面图标观感、删除二次确认（红色按钮）、
   各弹层 grabber。**未覆盖**：
   拍照与选文件的运行时权限（会弹系统界面）、导出后的分享、长时间打字的重排、iOS。
2. **Android 上导出拿不走。** `exportAll()` 写的是 app 私有目录，第三方文件管理器看不到，
   也没有接 share sheet 或 SAF。要兑现「本地优先、随时拷走」，需要补 `share_plus`。
   iOS 侧加 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` 后可解。
3. **release 用 debug 签名**（Flutter 模板默认）。上架前必须换正式 keystore。
4. **撤销栈只在当前这次编辑会话里有效**（页面关掉就清空），也没有「编辑历史」这种长期记录。
5. **iOS 工程未生成**，`Info.plist` 的相机/相册权限与文件共享开关都还没配。
6. 时间解析不接受毫秒和时区后缀（读者从不产生这两种格式），遇到会回退到从 id 反推的时间。

## 路线图

- [ ] 真机冒烟：首启、新增改删、插图、杀进程重启
- [ ] Android 导出接 `share_plus` / SAF
- [ ] 锁屏小组件 + 分享扩展（手机端真正的捕获入口）
- [ ] 笔记超过 3000 条时迁到 SQLite + FTS5（中文需逐字拆词，`trigram` 对两字词无效）
- [ ] iOS 平台工程与 Info.plist 配置
