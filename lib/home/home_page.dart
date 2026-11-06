import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../app/shortcuts.dart';
import '../data/note_repository.dart';
import '../editor/block.dart';
import '../editor/lab/image_display_size.dart';
import '../editor/lab/new_editor_page.dart';
import '../security/unlock.dart';
import '../models/note.dart';
import '../models/note_settings.dart';
import '../settings/settings_page.dart';
import '../theme/app_theme.dart';
import '../ui/action_sheet.dart';
import '../ui/show_sheet.dart';
import '../ui/snack.dart';
import '../util/share.dart';
import 'note_tile_comfortable.dart';
import 'note_tile_compact.dart';

/// 主页：时间流式的笔记列表。
///
/// 信息层级刻意只有三层：标题栏 / 标签筛选 / 列表。
/// 这类工具一旦出现「今日统计」「使用时长」之类的装饰，就会从「随手记」变成「要维护的东西」。
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.repository,
    this.startWithNewNote = false,
  });

  final NoteRepository repository;

  /// 由桌面图标长按快捷方式冷启动时为 true。
  final bool startWithNewNote;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  bool _searchMode = false;

  /// 防止「冷启动 + 回到前台」两次消费到同一份分享内容。
  bool _importingShare = false;

  NoteRepository get _repo => widget.repository;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    newNoteRequests.addListener(_onShortcutNewNote);
    if (widget.startWithNewNote) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openEditor(null));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeShared());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 应用在后台时从别的 App 分享进来，系统会走 onNewIntent，
    // 原生存下内容；回到前台时再取一次。
    if (state == AppLifecycleState.resumed) {
      _consumeShared();
    }
  }

  /// 冷启动 / 回到前台时把「分享到小记」的内容落成一条笔记。
  Future<void> _consumeShared() async {
    if (_importingShare) {
      return;
    }
    _importingShare = true;
    try {
      final SharedContent? content = await consumeSharedContent();
      if (content == null || !mounted) {
        return;
      }
      final DateTime now = DateTime.now();
      final String id = Note.generateId(now);
      String body = (content.text ?? '').trim();
      if (content.imagePath != null) {
        final String relative = await _repo.store.importAttachment(
          noteId: id,
          sourcePath: content.imagePath!,
        );
        body = body.isEmpty ? '![]($relative)' : '$body\n\n![]($relative)';
      }
      final Note note =
          Note(id: id, created: now, updated: now, body: body);
      await _repo.upsert(note);
      if (!mounted) {
        return;
      }
      await _openEditor(note);
      if (mounted) {
        showSnack(context, message: '已从其他 App 导入');
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, message: '导入失败：$error');
      }
    } finally {
      _importingShare = false;
    }
  }

  void _onShortcutNewNote() {
    if (!mounted) {
      return;
    }
    _openEditor(null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    newNoteRequests.removeListener(_onShortcutNewNote);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _enterSearch() {
    setState(() {
      _searchMode = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocus.requestFocus();
    });
  }

  void _exitSearch() {
    _searchController.clear();
    _repo.setQuery('');
    _searchFocus.unfocus();
    setState(() {
      _searchMode = false;
    });
  }

  Future<void> _openEditor(Note? note) async {
    // 内核迁移收尾：全量切换到新内核编辑页（点卡片/新建/桌面快捷方式
    // 都汇聚在这里）。新建时先造好笔记对象，没有任何编辑就不会落盘，
    // 不会堆出空白笔记。
    Note? unlocked = note;
    if (note != null && note.locked) {
      // 锁定笔记：每次打开都要验证身份，解密后的正文只留在当前页面内存。
      final bool ok = await verifyIdentity(
        context,
        settings: _repo.settings,
        reason: '解锁这条笔记',
      );
      if (!ok || !mounted) {
        return;
      }
      try {
        unlocked = note.copyWith(body: await _repo.store.readNoteBody(note));
      } catch (error) {
        if (mounted) {
          showSnack(context, message: '解锁失败：$error');
        }
        return;
      }
    }
    if (!mounted) {
      return;
    }
    // 离开列表页时收起提示条，避免「已移到回收站」跟着进入编辑页。
    hideSnack(context);
    final effective = unlocked ??
        Note(
          id: Note.generateId(DateTime.now()),
          created: DateTime.now(),
          updated: DateTime.now(),
        );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => NewEditorPage(
          repository: _repo,
          note: effective,
          // 新建时自动聚焦并拉起输入法；点开已有小记保持浏览态。
          autoFocus: note == null,
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    hideSnack(context);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SettingsPage(repository: _repo),
      ),
    );
  }

  Future<void> _showNoteActions(Note note) async {
    // 长按是「重」手势，给一次轻震反馈，用户能确认按到了（与系统列表一致）。
    HapticFeedback.mediumImpact();
    // 列表长按只放高频动作：置顶 / 锁定 / 删除。
    // 复制文本、编辑标签需要先看内容再决定，留在详情页「更多」里；
    // 两处共用的动作保持同一图标、同一顺序，删除永远是最后一项。
    final String firstLine =
        note.locked ? '' : plainSummary(note.body).split('\n').first.trim();
    final String menuTitle =
        note.locked ? '已锁定' : (firstLine.isEmpty ? '（无正文）' : firstLine);
    final action = await showXiaojiActionSheet<String>(
      context: context,
      title: menuTitle,
      actions: <SheetAction<String>>[
        SheetAction<String>(
          value: 'pin',
          label: note.pinned ? '取消置顶' : '置顶',
          icon: note.pinned ? Icons.push_pin : Icons.push_pin_outlined,
        ),
        // 锁定笔记的正文不在内存里，这里只做加密状态切换。
        if (note.locked)
          const SheetAction<String>(
            value: 'unlock',
            label: '取消锁定',
            icon: Icons.lock_open_outlined,
          )
        else
          const SheetAction<String>(
            value: 'lock',
            label: '锁定笔记',
            icon: Icons.lock_outline,
          ),
        const SheetAction<String>(
          value: 'delete',
          label: '删除',
          icon: Icons.delete_outline,
          destructive: true,
        ),
      ],
    );
    if (action == null || !mounted) {
      return;
    }
    switch (action) {
      case 'pin':
        await _repo.togglePin(note);
      case 'lock':
        await _lockNote(note);
      case 'unlock':
        await _unlockNote(note);
      case 'delete':
        await _confirmDelete(note);
    }
  }

  /// 从列表直接锁定：与编辑页「锁定」同一套语义（正文加密，附件不加密）。
  Future<void> _lockNote(Note note) async {
    final bool? confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '锁定这条笔记？',
      message: '锁定后正文加密保存，每次打开都要验证身份。图片和附件不加密。',
      confirmLabel: '锁定',
    );
    if (confirmed != true || !mounted) {
      return;
    }
    // 没有系统锁屏、也没有备用 PIN 时先设一个，否则锁定后无从验证。
    if (!await _ensureVerificationAvailable()) {
      return;
    }
    try {
      await _repo.upsert(note.copyWith(locked: true, updated: DateTime.now()));
      if (mounted) {
        showSnack(context, message: '已锁定，正文已加密保存');
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, message: '锁定失败：$error');
      }
    }
  }

  /// 取消锁定：先验证身份，再把解密后的正文明文写回。
  Future<void> _unlockNote(Note note) async {
    final bool ok = await verifyIdentity(
      context,
      settings: _repo.settings,
      reason: '取消锁定这条笔记',
    );
    if (!ok || !mounted) {
      return;
    }
    try {
      final String plain = await _repo.store.readNoteBody(note);
      await _repo.upsert(
        note.copyWith(body: plain, locked: false, updated: DateTime.now()),
      );
      if (mounted) {
        showSnack(context, message: '已取消锁定');
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, message: '取消锁定失败：$error');
      }
    }
  }

  /// 确保至少有一种可用的身份验证方式（系统凭证或应用 PIN）。
  Future<bool> _ensureVerificationAvailable() async {
    final NoteSettings settings = _repo.settings;
    try {
      if (await kSecurity.isDeviceSecure() || settings.pinHash != null) {
        return true;
      }
      if (!mounted) {
        return false;
      }
      final String? pin = await promptPinSheet(context, title: '设置解锁 PIN');
      if (pin == null || !mounted) {
        return false;
      }
      final String salt = await kSecurity.randomSalt();
      final String hash = await kSecurity.hashPin(pin: pin, salt: salt);
      await _repo.updateSettings(
        settings.copyWith(pinHash: hash, pinSalt: salt),
      );
      return true;
    } catch (error) {
      if (mounted) {
        showSnack(context, message: '无法启用锁定：$error');
      }
      return false;
    }
  }

  /// 标题栏标签按钮 → 「按标签筛选」弹层。
  ///
  /// 点选即生效并收起弹层：筛选是个轻动作，不值得再多按一次「确定」。
  /// 标签的改名 / 合并 / 删除统一收在「设置 → 标签管理」，这里只负责筛选。
  Future<void> _showTagFilterSheet() async {
    await showXiaojiSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        final colors = AppColors.of(sheetContext);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
            child: ListenableBuilder(
              listenable: _repo,
              builder: (BuildContext context, Widget? _) {
                final tags = _repo.tags;
                final active = _repo.activeTag;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '按标签筛选',
                      style: AppText.caption.copyWith(color: colors.tertiary),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        _FilterChip(
                          label: '全部',
                          selected: active == null,
                          onTap: () {
                            _repo.setActiveTag(null);
                            Navigator.of(sheetContext).pop();
                          },
                        ),
                        for (final tag in tags)
                          _FilterChip(
                            label: '#$tag',
                            selected: active == tag,
                            onTap: () {
                              _repo.setActiveTag(tag);
                              Navigator.of(sheetContext).pop();
                            },
                          ),
                      ],
                    ),
                    if (tags.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 14),
                      Text(
                        '标签的改名、合并、删除在「设置 → 标签管理」里。',
                        style: TextStyle(
                          fontSize: AppFontSize.caption,
                          height: 1.5,
                          color: colors.tertiary,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmDelete(Note note) async {
    final confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '删除这条小记？',
      message: '正文和附件会一起移到「回收站」，30 天后自动清理。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    // 锁定笔记删除前必须验证身份：旁人拿到解锁中的手机，不能直接把
    // 锁定内容丢进回收站（虽然可恢复，但也是一次擦除行为）。
    if (note.locked) {
      final bool ok = await verifyIdentity(
        context,
        settings: _repo.settings,
        reason: '删除这条锁定笔记',
      );
      if (!ok || !mounted) {
        return;
      }
    }
    await _repo.remove(note);
    if (!mounted) {
      return;
    }
    // 删除不再「不可逆」：正文和附件整体进了回收站，这里给一次即时撤销。
    showSnack(
      context,
      message: '已移到「回收站」',
      action: SnackBarAction(
        label: '撤销',
        onPressed: () => _repo.undoDelete(note.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final density = _repo.settings.density;
    // 舒适档「卡片与底色对调」：浅色米底白卡、深色黑底亮卡，
    // 卡片永远比底色亮一档（与设置页同一逻辑）。
    // 之前无脑用 pageAlt 当底色，深色下卡片(pageAlt)和底色同色，
    // 卡片轮廓完全消失。
    final comfortableBg = Theme.of(context).brightness == Brightness.dark
        ? colors.page
        : colors.pageAlt;

    return Scaffold(
      // 两档密度两种底色语义：紧凑 = 纯色列表（文字对比优先），
      // 舒适 = 卡片浮在次级底色上。
      backgroundColor:
          density == ListDensity.compact ? colors.page : comfortableBg,
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: _repo,
          builder: (BuildContext context, Widget? child) {
            final notes = _repo.visibleNotes;

            return Column(
              children: <Widget>[
                _searchMode ? _buildSearchBar(colors) : _buildTitleBar(colors),
                if (!_searchMode)
                  Container(height: 0.5, color: colors.dividerStrong),
                if (_repo.isSearching && !_repo.isLoading)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.page,
                      AppSpace.xs,
                      AppSpace.page,
                      AppSpace.sm,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '共 ${notes.length} 条',
                        style: TextStyle(
                          fontSize: AppFontSize.caption,
                          letterSpacing: 0.2,
                          color: colors.tertiary,
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: _repo.isLoading
                      ? const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 1.6),
                          ),
                        )
                      : (notes.isEmpty
                          ? _EmptyState(searching: _repo.isSearching)
                          // 宽屏（平板/折叠屏）时限宽居中，长列表拉满全宽没法看
                          : Center(
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 560),
                                child: _buildList(colors, notes, density),
                              ),
                            )),
                ),
              ],
            );
          },
        ),
      ),
      // 右下角悬浮球：与 Keep / 备忘录一致，只有一个新建入口，
      // 不占用列表高度；搜索态隐藏，避免和键盘抢位置。
      floatingActionButton: _searchMode
          ? null
          : FloatingActionButton(
              onPressed: () => _openEditor(null),
              tooltip: '新建小记',
              backgroundColor: colors.fabBackground,
              foregroundColor: colors.fabForeground,
              elevation: 0,
              highlightElevation: 0,
              shape: const CircleBorder(),
              child: const Icon(Icons.edit_outlined, size: 22),
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Widget _buildTitleBar(AppColors colors) {
    final activeTag = _repo.activeTag;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.sm,
        8,
        AppSpace.sm,
      ),
      child: Row(
        children: <Widget>[
          Text(
            '小记',
            style: AppText.pageTitle.copyWith(color: colors.text),
          ),
          const Spacer(),
          // 标签入口（语雀式）：未选中时是描边图标；选中后整个入口变成
          // 「图标 + 标签名 + 清除」的胶囊，原位替换图标 —— 筛选状态
          // 一眼可见，也不再用一整行筛选条占掉列表高度。
          if (activeTag == null)
            _IconAction(
              icon: Icons.label_outline,
              onTap: _showTagFilterSheet,
            )
          else
            _buildTagPill(colors, activeTag),
          _IconAction(
            icon: Icons.search,
            onTap: _enterSearch,
          ),
          _IconAction(icon: Icons.settings_outlined, onTap: _openSettings),
        ],
      ),
    );
  }

  /// 标题栏里的激活标签胶囊：点主体重新打开筛选弹层（可换标签或选
  /// 「全部」清除），点 × 直接清除筛选。
  Widget _buildTagPill(AppColors colors, String tag) {
    return InkWell(
      onTap: _showTagFilterSheet,
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: colors.accentBg,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(
            color: colors.chipBorderSelected,
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.label, size: 14, color: colors.accent),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 96),
              child: Text(
                '#$tag',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppFontSize.label,
                  height: 1,
                  letterSpacing: 0.1,
                  fontWeight: AppWeight.medium,
                  color: colors.accent,
                ),
              ),
            ),
            const SizedBox(width: 4),
            // × 独立命中区（热区放大到整格）：清除是个高频轻动作，
            // 不该强迫用户再进弹层绕一圈。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _repo.setActiveTag(null),
              child: SizedBox(
                width: 18,
                height: 28,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Icon(Icons.close, size: 14, color: colors.accent),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(AppColors colors) {
    return Padding(
      // 左边距与标题、列表卡片统一（AppSpace.page），否则搜索框会比其他
      // 内容往左凸出 4dp，进入搜索态时整页像被挪了一下。
      padding: const EdgeInsets.fromLTRB(AppSpace.page, 6, 10, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                // 主页底色和 surface2 太接近（浅色 #F5F3EC vs #F7F5F0），
                // 搜索框直接「隐身」。改成 page 底 + 描边：浅色 = 白胶囊浮
                // 米底（微信搜索框同款），深色 = 深底 + 清晰描边。
                color: colors.page,
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: colors.chipBorder, width: 0.5),
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.search, size: 16, color: colors.tertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocus,
                      onChanged: _repo.setQuery,
                      style: TextStyle(fontSize: AppFontSize.body, color: colors.text),
                      cursorColor: colors.accent,
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        hintText: '搜索',
                        hintStyle:
                            TextStyle(fontSize: AppFontSize.body, color: colors.tertiary),
                      ),
                    ),
                  ),
                  if (_searchController.text.isNotEmpty)
                    InkWell(
                      onTap: () {
                        _searchController.clear();
                        _repo.setQuery('');
                        setState(() {});
                      },
                      child:
                          Icon(Icons.close, size: 16, color: colors.tertiary),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: _exitSearch,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Text(
                '取消',
                style: TextStyle(fontSize: AppFontSize.summary, color: colors.accent),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(AppColors colors, List<Note> notes, ListDensity density) {
    // 紧凑档铺在 page 底上，分隔线用 dividerStrong 才压得住；
    // 舒适档卡片之间的间隙不需要分隔线，保留淡档。
    final separator = density == ListDensity.compact
        ? colors.dividerStrong
        : colors.separator;
    final query = _repo.query;

    return ListView.builder(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      // 底部留 88dp：56dp 悬浮球 + 上下呼吸，保证最后一条不被遮住。
      padding: EdgeInsets.only(
        top: density == ListDensity.compact ? 4 : 8,
        bottom: 88,
      ),
      itemCount: notes.length + 1,
      itemBuilder: (BuildContext context, int index) {
        // 最后一项是「到底了」提示行，不是笔记。
        // 笔记为空时走的是上面的 _EmptyState，不会进到这里。
        if (index == notes.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 28, bottom: 24),
            child: Center(
              child: Text(
                '· 到底了 ·',
                style: AppText.caption.copyWith(color: colors.tertiary),
              ),
            ),
          );
        }
        final note = notes[index];
        // 锁定笔记：正文不在内存里，也不展示缩略图（附件未加密，
        // 但列表里露出图片等于绕过正文锁定）。
        final images = note.locked ? const <ImageBlock>[] : imageBlocksOf(note.body);
        // URL 末尾可能带「小图」标记（`#xiaoji-small`）：缩略图必须按
        // 去标记后的真实文件路径取图，否则 Image.file 找不到文件，
        // 列表里只剩一个「破图」图标（详情页正常、首页全坏）。
        final paths = images
            .take(3)
            .map((block) =>
                _repo.store.absoluteAssetPath(imageFilePath(block.path)))
            .toList(growable: false);

        Widget tile;
        if (density == ListDensity.compact) {
          tile = NoteTileCompact(
            note: note,
            query: query,
            // 紧凑档同样带图：右侧 36dp 小图 + 计数，有附件时退回回形针。
            thumbnailPaths: paths,
            imageCount: images.length,
            hasAttachment:
                !note.locked && hasLocalAttachment(note.body),
            onTap: () => _openEditor(note),
            onLongPress: () => _showNoteActions(note),
          );
        } else {
          tile = NoteTileComfortable(
            note: note,
            query: query,
            // 纯文字给 5 行；有图时压到 3 行，把高度让给缩略图行，
            // 避免「5 行字 + 一排图」把一张卡撑得半屏高。
            maxSummaryLines: _repo.isSearching ? 2 : (paths.isEmpty ? 5 : 3),
            thumbnailPaths: paths,
            hiddenThumbnailCount: images.length > 3 ? images.length - 3 : 0,
            onTap: () => _openEditor(note),
            onLongPress: () => _showNoteActions(note),
          );
        }

        // 舒适档卡片化：白卡浮在微灰底上（与设置页同语言），卡与卡留 10 间距。
        // 紧凑档保持通栏分隔线列表 —— 「密度」档位的语义就是更高信息密度。
        if (density == ListDensity.compact) {
          return Column(
            children: <Widget>[
              tile,
              if (index != notes.length - 1)
                Padding(
                  padding: const EdgeInsets.only(left: AppSpace.page),
                  child: Container(height: 0.5, color: separator),
                ),
            ],
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
          child: Column(
            children: <Widget>[
              tile,
              // 卡片间距 12：比 10 更有呼吸感，长列表滚动时卡片边界更清楚。
              const SizedBox(height: AppSpace.md),
            ],
          ),
        );
      },
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        // 44dp 是移动端最小可点面积；图标 21dp，三个入口并排也不会挤在一起。
        width: 44,
        height: 44,
        child: Icon(icon, size: 21, color: colors.text),
      ),
    );
  }
}

/// 标签筛选弹层里的 chip：「全部」和各标签共用。
///
/// 选中 = accentBg 实底 + accent 文字；未选中 = 描边 + 次要文字。
/// 这里只做筛选，标签的改名 / 合并 / 删除统一收在「设置 → 标签管理」。
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final foreground = selected ? colors.accent : colors.secondary;
    return Container(
      height: 30,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: selected ? colors.accentBg : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(
          color: selected ? colors.chipBorderSelected : colors.chipBorder,
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InkWell(
            onTap: onTap,
            child: Padding(
              // 固定高度 + widthFactor: 1：靠 padding 撑出来的高度会让文字
              // 看起来偏上（字形盒子自带 leading），Container 的 alignment
              // 又会撑满父级约束，所以两者都不用。
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: AppFontSize.labelLg,
                    height: 1,
                    letterSpacing: 0.1,
                    color: foreground,
                    fontWeight: selected ? AppWeight.medium : AppWeight.regular,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 空状态。
///
/// 画一个「空白卡片 + 一根光标」而不是插画：一是没有图片资源，
/// 二是这个意象本身就在说「这里等你写第一句」。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    if (searching) {
      return Center(
        child: Text(
          '没有匹配的小记',
          style: TextStyle(fontSize: AppFontSize.label, color: colors.tertiary),
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 52,
            height: 66,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: colors.chipBorder, width: 1.2),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 26,
                  height: 1.5,
                  color: colors.dividerStrong,
                ),
                const SizedBox(height: 6),
                Container(
                  width: 26,
                  height: 1.5,
                  color: colors.dividerStrong,
                ),
                const SizedBox(height: 8),
                Container(
                  width: 1.5,
                  height: 12,
                  color: colors.accent,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '还没有小记',
            style: TextStyle(
              fontSize: AppFontSize.subtitle,
              fontWeight: AppWeight.semibold,
              letterSpacing: 0.2,
              color: colors.text,
            ),
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            '点右下角的笔开始',
            style: TextStyle(
              fontSize: AppFontSize.labelLg,
              height: 1.75,
              color: colors.secondary,
            ),
          ),
          Text(
            '或从桌面小组件直接记录',
            style: TextStyle(
              fontSize: AppFontSize.labelLg,
              height: 1.75,
              color: colors.secondary,
            ),
          ),
        ],
      ),
    );
  }
}
