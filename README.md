# 小记

**本地优先的 Markdown 小记。无账号、无网络、无同步，所有内容都是你自己设备上的一群 `.md` 文件。**

[下载最新版](https://github.com/oliverbuddy/private_notes/releases/latest) ·
[官网](https://oliverbuddy.github.io/private_notes/) ·
[问题反馈](https://github.com/oliverbuddy/private_notes/issues)

Android 7.0+ · macOS 12+ · Windows 10+ · 非商业授权（商用需授权）

---

## 为什么是小记

- **打开就写**：没有标题、分类和层级，点开即编辑，输入自动保存。
- **数据是文件**：一篇笔记就是一个 Markdown 文件，按年月归档；卸载、换机、迁移都不被格式绑架。
- **安全是默认**：应用锁、单篇 AES-256-GCM 加密、截屏保护、备份口令，全部内置而不是插件。
- **三端同一套体验**：Android、macOS、Windows 共用同一份 Flutter 界面与同一套键盘/鼠标适配，笔记与备份跨端互通。

## 功能

### 记录与整理

时间线列表（舒适 / 紧凑两档）· 标签筛选（可删标签）· 置顶 · 全文搜索（SQLite FTS5，中文单字 + 二字切词）·
回收站（30 天可恢复）· 长文目录（标题 ≥ 2 个时出现，可跳转）· 存储分类统计与无引用附件清理。

### Markdown 编辑

- 单态块编辑：浏览即最终效果，点哪块编哪块，收起键盘回到阅读。
- 标题、列表、待办、引用、代码块、表格、图片、分隔线、链接完整支持，保存后重新打开不丢信息。
- 输入即转换：`# ` / `- ` / `1. ` / `> ` 直接成型；桌面端额外兼容全角空格与 `[] ` 待办前缀。
- 粘贴识别：网页 HTML、Markdown、Excel 表格、嵌套列表、代码语言自动转成对应块。
- 有序列表自动续号与重排；代码块内回车不拆块；无序列表子级用 • / ◦ / ▪ 区分。
- 撤销 / 重做按「块结构快照」记录，连续打字合并为一步，结构改动各占一步。

### 隐私与安全

| 能力 | 说明 |
|---|---|
| 应用锁 | 系统 PIN / 图案 / 密码或指纹；退后台按「立即 / 1 / 5 分钟」自动锁定，锁屏覆盖所有路由 |
| 单篇锁定 | 正文 AES-256-GCM 加密，密钥存 Android Keystore / macOS Keychain / Windows DPAPI，不出设备 |
| 截屏保护 | 锁定内容禁止截屏与多任务预览；桌面端在窗口层屏蔽（`sharingType` / `WDA_EXCLUDEFROMCAPTURE`） |
| 无网络 | Release 包不声明 `INTERNET` 权限，代码中没有任何网络请求 |
| 系统备份关闭 | `allowBackup=false`，避免锁定前的明文被系统云备份带走 |

### 备份与迁移

- 「备份与恢复」单入口：自动备份开关、立即备份、导出、恢复。
- 备份包内含 `manifest.json`（schema 版本、应用版本、创建时间、笔记数、附件数、加密状态），恢复前先展示摘要。
- 可选口令加密：PBKDF2 + AES-256-GCM，扩展名 `.xiaoji`；口令错误明确拒绝，不破坏现有数据。
- 恢复采用快照语义：只替换备份内的笔记，恢复前自动留一份快照，失败不触碰现有数据。
- 自动备份到文件夹：每 24 小时一份，保留最近 3 份；桌面端可直接写本机目录。
- 锁定笔记默认排除；跨设备迁移请选择「导出（含锁定笔记，明文）」后重新锁定。

## 桌面端（macOS / Windows）

桌面端不是把手机界面拉宽，而是按桌面习惯重做了一层：

- **双栏布局**：宽屏（≥ 900 × 520）左侧列表常驻、右侧正文，切笔记不打断阅读；空态直接给出「新建小记」。手机横屏仍保持单栏。
- **正文即编辑**：点进正文出现排版工具条（Aa / 插入 / 标签 / 撤销），Esc 或「完成」退出编辑；粘贴 Markdown 立即按块渲染；空列表项回车退出列表。
- **手打 Markdown 即时成型**：`**加粗**`、`*斜体*`、`` `行内码` ``、`~~删除~~`、`==高亮==`、`[文字](链接)` 敲完闭合标记就生效（标记字符自动消失）；行首输入 ` ``` ` / ` ```dart ` 回车直接生成代码块。工具条与手打两条路径结果一致。
- **键鼠交互**：双击选词、右键复制/剪切/粘贴/全选、`⌘F` / `Ctrl+F` 搜索、F11 与 `⌃⌘F` 全屏、`⌘N` / `Ctrl+N` 新建、悬停反馈与手型指针；当前打开的笔记在列表中高亮。
- **键盘浏览**：双栏下在列表里按 `↑` / `↓` 直接切上一条 / 下一条，选中项自动滚入视野。
- **表格**：整块选中可见；双击单元格就地编辑（`Tab` / `Shift+Tab` 连续切格、Esc 取消、回车提交）；`⌘C` 或右键「复制表格（Markdown）」；右键「编辑表格」还能改整表源码。
- **正文缩放**：`⌘=` / `⌘-` / `⌘0`（Windows 为 `Ctrl`）在 0.85×–1.4× 之间缩放正文，只影响详情页排版，侧边栏密度不变。
- **桌面弹层**：标签筛选、详情「⋯」、笔记右键等菜单**贴住触发位置弹出**（主流桌面菜单形态）；确认框、输入框与历史版本面板用居中对话框。
- **图片查看**：桌面端点开图片是**独立窗口**（系统预览式，可缩放/可关闭），不把图片放大铺在应用里。
- **拖拽文件**：图片拖进正文直接插入、其他文件作为附件；反过来把列表里的笔记**拖出**到 Finder / 资源管理器，即得到一份 `.md` 副本（macOS + Windows）。
- **窗口自适应**：拖动窗口尺寸跨过断点自动在单栏 / 双栏之间切换；macOS 记住窗口位置与大小。
- **桌面排版**：正文 760 宽居中，标题按桌面尺度放大一档，表格单列上限放宽到 320。
- **原生能力**：系统保存/打开对话框、Keychain / DPAPI、窗口级截屏屏蔽；窗口标题、应用名、图标与移动端统一为「小记」。

## 下载与安装

| 平台 | 产物 | 说明 |
|---|---|---|
| Android | `xiaoji-<版本>-android-arm64-v8a.apk` | 绝大多数设备；2016 年前老设备选 `armeabi-v7a` |
| macOS | `xiaoji-<版本>-macos-universal.dmg` | Intel + Apple 芯片通用；拖进「应用程序」 |
| Windows | `xiaoji-<版本>-windows-x64-setup.exe` | 按用户安装，不需要管理员权限 |
| 校验 | 同名 `.sha256` | `shasum -a 256 -c` / `Get-FileHash` 核对 |

**Android**：允许「安装未知来源应用」，覆盖安装即可升级；自动更新可在
[Obtainium](https://github.com/ImranR98/Obtainium) 添加仓库 `oliverbuddy/private_notes`。

**macOS**：首次打开会被 Gatekeeper 拦住（ad-hoc 签名、未公证）——macOS 14 及更早右键 →「打开」，
macOS 15 及更新到「系统设置 → 隐私与安全性」点「仍要打开」。仍提示「已损坏」时执行
`xattr -dr com.apple.quarantine /Applications/小记.app`。

**Windows**：首次运行 SmartScreen 提示「未知发布者」，点「更多信息 → 仍要运行」；安装器未做代码签名。

> 桌面包没有购买商业代码签名证书，系统会提示一次；要彻底消除需 Apple Developer（$99/年 + 公证）
> 或 Windows OV/EV 代码签名证书。签名材料只放 GitHub Secrets，仓库内不含任何证书。

## 数据格式

```
<应用文档目录>/Xiaoji/
├── notes/
│   └── 2026-11/
│       └── 20261106-0830-a1f2/
│           ├── note.md          # 正文（YAML frontmatter + Markdown）
│           ├── meta.json        # 标签 / 置顶 / 锁定状态等
│           └── assets/          # 该笔记的图片与附件
├── backups/                     # 自动 / 手动备份（zip，可选 .xiaoji 加密）
├── versions/                    # 单篇版本历史（20 版 + 30 天）
├── trash/                       # 回收站（30 天）
└── xiaoji.db                    # 搜索索引（派生数据，可删、自动重建）
```

一篇笔记的 `note.md`：

```markdown
---
id: 20261106-0830-a1f2
created: 2026-11-06T08:30:00
updated: 2026-11-06T12:10:00
tags: 想法, 工作
pinned: true
---

# 周五回顾

这周把备份链路理顺了：

- 自动备份改成 **距上次 ≥ 24 小时**
- 恢复前先留一份快照

> 宁可多留一份，也不要让任何一篇笔记消失
```

搜索索引、版本历史与回收站都属于派生数据，不进入导出；备份包内同样排除索引。

## 技术架构

- **UI**：Flutter 单代码库，三端共用；断点 600 / 1024，双栏阈值 900 × 520。
- **编辑内核**：`super_editor` + 小记自有 Markdown 方言（解析 / 序列化 / 摘要四端一致）。
- **原生通道**：`xiaoji/native`，Android Kotlin、macOS Swift、Windows C++ 三份实现同语义：
  AES-256-GCM（CryptoKit / BCrypt）、PBKDF2、Keychain / Keystore / DPAPI、系统身份验证、截屏保护。
- **跨平台回退**：原生通道不可用时，导出 / 备份走 Dart 层 `archive` + `file_picker`，不因平台缺失直接失败。
- **设计 token**：圆角 block 8 / card 10 / chip 11 / thumb 6 / pill 999；字号统一 `AppFontSize`，不散落魔法值。

## 开发

```bash
flutter pub get
flutter analyze          # 静态检查
flutter test             # 全量测试（当前 485 条）
flutter run -d macos     # 或 windows / 连接的 Android 设备
```

构建：

```bash
flutter build apk --release --split-per-abi \
  --target-platform android-arm,android-arm64
flutter build macos --release
flutter build windows --release
```

发布流程（全部在 GitHub Actions 完成，本地不需要 Xcode / Visual Studio）：

| 工作流 | 触发 | 产物 |
|---|---|---|
| `release.yml` | 推 `v*` 标签 / 手动 | 签名 APK（按 ABI 拆包） |
| `release-desktop.yml` | 推 `v*` 标签 / 手动 | macOS DMG、Windows Inno Setup 安装器 |
| `pages.yml` | 推 `main`（docs 变更） | GitHub Pages 落地页 |

签名材料（Android keystore）只从 GitHub Secrets 还原；桌面端目前为 ad-hoc / 未签名，
接入证书后同样走 Secrets，不提交任何密钥。

## 已知限制

1. **桌面端未做商业签名**：macOS 仅 ad-hoc、Windows 未签名，首次打开需按上文放行一次。
2. **iOS 未提供**：需要付费 Apple 开发者账号，工程尚未生成。
3. **数据不联网**：没有账号与同步；换机依靠导出 / 备份文件手动迁移。
4. **锁定笔记密钥绑定本机**：Keystore / Keychain / DPAPI 不随文件迁移，跨设备需明文导出后重新锁定。
5. **桌面端关闭 macOS App Sandbox**：外置备份目录需要跨启动访问权限；隐私边界由应用代码保证。
6. **Windows 暂未接入 Windows Hello**：设备安全校验回退为应用内 PIN。
7. **桌面端没有系统分享面板**：「分享为图片」退化为另存为；没有桌面小组件。
8. **导入 Markdown 只导正文与元信息**：本地相对路径图片不会自动搬运。
9. **小组件标题颜色跟随壁纸**：更换壁纸后系统最快 30 分钟刷新，重新添加组件可立即生效。
10. **版本历史按编辑会话归档**：保留最近 20 版 + 30 天，不保留每一次击键。

## 路线图

- [x] Android / macOS / Windows 三端发布与 CI 打包
- [x] 平板适配、桌面与平板双栏、桌面键鼠与拖拽
- [x] 单篇锁定、口令加密备份、版本历史、全文搜索
- [ ] iOS 工程与签名
- [ ] 锁定笔记附件加密（整篇保护）
- [ ] 锁定笔记「验证后 5 分钟内免重复验证」

## 许可

[PolyForm Noncommercial 1.0.0](LICENSE)。**允许个人使用、学习、修改与分发，禁止商业使用。**

商业授权：[qiwei0727@gmail.com](mailto:qiwei0727@gmail.com?subject=%E5%B0%8F%E8%AE%B0%E5%95%86%E4%B8%9A%E6%8E%88%E6%9D%83)。
