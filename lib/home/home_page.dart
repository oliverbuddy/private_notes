import 'package:flutter/material.dart';

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
import '../ui/show_sheet.dart';
import '../ui/snack.dart';
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

class _HomePageState extends State<HomePage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  bool _searchMode = false;

  NoteRepository get _repo => widget.repository;

  @override
  void initState() {
    super.initState();
    newNoteRequests.addListener(_onShortcutNewNote);
    if (widget.startWithNewNote) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openEditor(null));
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
    // 离开列表页时收起提示条，避免「已移到最近删除」跟着进入编辑页。
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
    final action = await showXiaojiSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _sheetTile(
                sheetContext,
                note.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                note.pinned ? '取消置顶' : '置顶',
                'pin',
              ),
              _sheetTile(sheetContext, Icons.delete_outline, '删除', 'delete'),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (action == null || !mounted) {
      return;
    }
    if (action == 'pin') {
      await _repo.togglePin(note);
      return;
    }
    if (action == 'delete') {
      await _confirmDelete(note);
    }
  }

  /// 标题栏标签按钮 → 「按标签筛选」弹层。
  ///
  /// 点选即生效并收起弹层：筛选是个轻动作，不值得再多按一次「确定」。
  /// 每个标签右侧带 ×，可以直接删除标签（只从所有小记里摘掉这个标签，
  /// 正文一个字都不动）—— 标签是用户自己攒出来的，攒乱了得能自己收拾。
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
                            label: tag,
                            selected: active == tag,
                            onTap: () {
                              _repo.setActiveTag(tag);
                              Navigator.of(sheetContext).pop();
                            },
                            onDelete: () => _deleteTag(tag),
                          ),
                      ],
                    ),
                    if (tags.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 14),
                      Text(
                        '点标签右侧的 × 可以删除标签，小记内容不受影响。',
                        style: TextStyle(
                          fontSize: 12,
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

  /// 删除一个标签（需要二次确认：一次点错就可能抹掉攒了很久的分类）。
  Future<void> _deleteTag(String tag) async {
    final count =
        _repo.notes.where((Note note) => note.tags.contains(tag)).length;
    final confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '删除标签 #$tag？',
      message: count > 0 ? '会从 $count 条小记里移除这个标签，小记本身不会被删除。' : '目前没有小记使用这个标签。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _repo.deleteTag(tag);
  }

  Widget _sheetTile(
    BuildContext sheetContext,
    IconData icon,
    String label,
    String value,
  ) {
    final colors = AppColors.of(sheetContext);
    return InkWell(
      onTap: () => Navigator.of(sheetContext).pop(value),
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        alignment: Alignment.centerLeft,
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20, color: colors.text),
            const SizedBox(width: 14),
            Text(label, style: TextStyle(fontSize: 16, color: colors.text)),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(Note note) async {
    final confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '删除这条小记？',
      message: '正文和附件会一起移到「最近删除」，30 天后自动清理。',
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
      message: '已移到「最近删除」',
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
                          fontSize: 12,
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
      floatingActionButton: _buildFab(colors),
    );
  }

  Widget _buildTitleBar(AppColors colors) {
    final activeTag = _repo.activeTag;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.sm,
        10,
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
          _IconAction(icon: Icons.more_horiz, onTap: _openSettings),
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
                  fontSize: 13,
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
      padding: const EdgeInsets.fromLTRB(16, 6, 10, 8),
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
                borderRadius: BorderRadius.circular(9),
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
                      style: TextStyle(fontSize: 16, color: colors.text),
                      cursorColor: colors.accent,
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        hintText: '搜索',
                        hintStyle:
                            TextStyle(fontSize: 16, color: colors.tertiary),
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
                style: TextStyle(fontSize: 15.5, color: colors.accent),
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
      padding: EdgeInsets.only(top: density == ListDensity.compact ? 4 : 8),
      itemCount: notes.length + 1,
      itemBuilder: (BuildContext context, int index) {
        // 最后一项是「到底了」提示行，不是笔记。
        // 笔记为空时走的是上面的 _EmptyState，不会进到这里。
        if (index == notes.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 28, bottom: 120),
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

        Widget tile;
        if (density == ListDensity.compact) {
          tile = NoteTileCompact(
            note: note,
            query: query,
            onTap: () => _openEditor(note),
            onLongPress: () => _showNoteActions(note),
          );
        } else {
          final visible = images.take(3).toList();
          // URL 末尾可能带「小图」标记（`#xiaoji-small`）：缩略图必须按
          // 去标记后的真实文件路径取图，否则 Image.file 找不到文件，
          // 列表里只剩一个「破图」图标（详情页正常、首页全坏）。
          final paths = visible
              .map((block) => _repo.store
                  .absoluteAssetPath(imageFilePath(block.path)))
              .toList();
          tile = NoteTileComfortable(
            note: note,
            query: query,
            maxSummaryLines: _repo.isSearching ? 2 : 5,
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
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFab(AppColors colors) {
    // Scaffold 默认给 16 边距，这里只补 4 的底部 → 实际 16 / 20，
    // 比正右方略高一点，是单手更容易够到的位置。
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: colors.fabBackground,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openEditor(null),
          child: SizedBox(
            width: 54,
            height: 54,
            child: Icon(
              Icons.edit_outlined,
              size: 23,
              color: colors.fabForeground,
            ),
          ),
        ),
      ),
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
        width: 40,
        height: 40,
        child: Icon(icon, size: 22, color: colors.text),
      ),
    );
  }
}

/// 标签筛选弹层里的 chip：「全部」和各标签共用。
///
/// 选中 = accentBg 实底 + accent 文字；未选中 = 描边 + 次要文字。
/// 传了 [onDelete] 时右侧多一个 × 删除键（只用于真实标签，「全部」没有）。
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.onDelete,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

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
              padding: EdgeInsets.only(
                left: 12,
                right: onDelete == null ? 12 : 4,
              ),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1,
                    letterSpacing: 0.1,
                    color: foreground,
                    fontWeight: selected ? AppWeight.medium : AppWeight.regular,
                  ),
                ),
              ),
            ),
          ),
          if (onDelete != null)
            InkWell(
              onTap: onDelete,
              child: SizedBox(
                width: 24,
                height: 30,
                child: Icon(Icons.close, size: 12, color: foreground),
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
          style: TextStyle(fontSize: 13, color: colors.tertiary),
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
              fontSize: 17,
              fontWeight: AppWeight.semibold,
              letterSpacing: 0.2,
              color: colors.text,
            ),
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            '点右下角的笔开始',
            style: TextStyle(
              fontSize: 13.5,
              height: 1.75,
              color: colors.secondary,
            ),
          ),
          Text(
            '或在锁屏小组件、分享菜单里直接记',
            style: TextStyle(
              fontSize: 13.5,
              height: 1.75,
              color: colors.secondary,
            ),
          ),
        ],
      ),
    );
  }
}
