import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:file_picker/file_picker.dart';
import 'package:follow_the_leader/follow_the_leader.dart' show LeaderLink;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:super_editor/super_editor.dart';

import '../../models/note.dart';
import '../../data/note_repository.dart';
import '../../data/note_store.dart';
import '../../security/unlock.dart';
import '../../theme/app_theme.dart';
import '../../ui/action_sheet.dart';
import '../../ui/adaptive_image.dart';
import '../../ui/app_icon_button.dart';
import '../../ui/quote_block.dart';
import '../../ui/show_sheet.dart';
import '../../ui/snack.dart';
import '../../ui/tag_chip.dart';
import '../../util/media_saver.dart';
import '../markdown_toolbar.dart';
import '../markdown_view.dart';
import '../note_image_share.dart';
import '../link_editor_sheet.dart';
import '../tag_editor_sheet.dart';
import 'kernel_commands.dart';
import '../../util/date_format.dart' show formatEditorTime, formatFileSize;
import 'selection_toolbar.dart';
import '../widgets/image_block_view.dart';
import 'attachment_component.dart';
import 'caret_overlay.dart';
import 'editor_request_handlers.dart';
import 'image_display_size.dart';
import 'link_tap_handler.dart';
import 'list_style.dart';
import 'markdown_paste.dart';
import 'paste_ime_decorator.dart';
import 'task_component.dart';
import 'xiaoji_markdown.dart';

/// 编辑态的行内样式：内核默认（粗体/斜体/删除线）+ 行内码 + 高亮 + 链接。
///
/// 抽成纯函数是为了可单测。两处内核不认的扩展都在这里补：
///  - `codeAttribution`：内核的 `defaultStyleBuilder` 没有这个分支，
///    不补的话「行内码」只有模型属性、编辑态毫无视觉变化；
///  - `highlightAttribution`：`==高亮==` 是本项目扩展。
/// 链接则把内核默认的 lightBlue 换成应用主色，和阅读态保持一致。
TextStyle xiaojiInlineTextStyler(
  Set<Attribution> attributions,
  TextStyle baseStyle, {
  required Color textColor,
  required Color accentColor,
  required Color mutedColor,
  required Color codeBackground,
  required Color highlightBackground,
}) {
  TextStyle style = defaultInlineTextStyler(attributions, baseStyle);
  // 加粗对齐阅读态的 600：中文的 700 与 600 观感差别很小，但同一篇笔记
  // 在列表摘要里是 600、详情里是 700 时，来回切换会觉得「字重变了」。
  if (attributions.contains(boldAttribution)) {
    style = style.copyWith(fontWeight: AppWeight.semibold);
  }
  // 删除线：与阅读态（列表摘要）一致，整段文字淡成三级色。
  // 默认只加 lineThrough、颜色仍是正文色，两处看起来不是同一篇文档。
  if (attributions.contains(strikethroughAttribution)) {
    style = style.copyWith(color: mutedColor);
  }
  // 行内码：等宽 + 微缩 + 浅底，与阅读态（markdown_view 的 code 分支）一致。
  if (attributions.contains(codeAttribution)) {
    // 代码块会把 blockType 也当作一条 attribution 传进来，而它的基础样式
    // 已经是等宽 + 微缩过的；再乘 0.9 会变成 12.96。只有「正文里的行内码」
    // （基础样式还不是等宽）才需要缩一档。
    final bool alreadyCodeBlock = baseStyle.fontFamily == 'monospace';
    style = style.copyWith(
      fontFamily: 'monospace',
      fontSize: alreadyCodeBlock
          ? baseStyle.fontSize
          : (baseStyle.fontSize ?? AppFontSize.summary) * 0.9,
      color: textColor.withValues(alpha: 0.9),
      backgroundColor: alreadyCodeBlock ? null : codeBackground,
    );
  }
  // `==高亮==`：内核不认识这个属性，只在这里给它上底色。
  if (attributions.contains(highlightAttribution)) {
    style = style.copyWith(backgroundColor: highlightBackground);
  }
  // 链接：内核默认是 lightBlue，与应用的强调色不一致（阅读态用主色）。
  if (attributions.whereType<LinkAttribution>().isNotEmpty) {
    style = style.copyWith(
      color: accentColor,
      decoration: TextDecoration.underline,
      decorationColor: accentColor,
    );
  }
  return style;
}

/// M1：跑在 super_editor 内核上的并行编辑页。
///
/// 编辑页的踩坑记录（来自 17 轮迭代）：
///  - 键盘避让：Scaffold resizeToAvoidBottomInset + 常量底部 padding
///    （旧版 180↔68 跳变导致布局期 clamp、内容被顶动——见 2026-11-01 日志）。
///  - 自动保存：只在真实变更时触发（super_editor 的 EditListener 本身就
///    只在文档变化时回调），800ms 防抖，退出时同步落盘。
///  - 光标/滚动：内核自管（结构化模型，无「记号占位」问题）。
///  - 主题：全部走 AppColors/字阶，禁止散落字面量。
class NewEditorPage extends StatefulWidget {
  const NewEditorPage({
    super.key,
    required this.repository,
    required this.note,
    this.autoFocus = false,
  });

  final NoteRepository repository;
  final Note note;

  /// 新建小记时自动聚焦并拉起输入法；从列表点开查看时保持浏览态
  /// （不主动弹键盘）。
  final bool autoFocus;

  @override
  State<NewEditorPage> createState() => _NewEditorPageState();
}

class _NewEditorPageState extends State<NewEditorPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// 当前笔记对象：菜单操作（置顶/标签）会更新它，落盘时基于它构造
  /// Note——否则编辑保存会把 pinned/tags 重置回默认（迁移期间实测踩过）。
  late Note _currentNote = widget.note;

  late final MutableDocument _document;
  late final MutableDocumentComposer _composer;
  late final Editor _editor;
  late final CommonEditorOperations _ops;
  late final KernelCommands _commands;

  /// 工具条激活态。用 ValueNotifier 单独驱动工具条，选区每次移动只重建
  /// MarkdownToolbar 那一小块，不重建整个页面（对齐早期版本的做法）。
  final ValueNotifier<Set<MarkdownCommand>> _activeCommands =
      ValueNotifier<Set<MarkdownCommand>>(const <MarkdownCommand>{});

  /// 是否处于编辑态（有光标/选区）。浏览态隐藏底部工具条：
  /// 没有光标时按钮点下去只会 no-op，露出来反而像「坏了」。
  final ValueNotifier<bool> _editing = ValueNotifier<bool>(false);

  /// 撤销 / 重做是否可用。顶栏图标据此置灰（无历史时也保留占位，
  /// 避免整条右上角在可用/不可用时左右抖动）。
  final ValueNotifier<bool> _canUndo = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _canRedo = ValueNotifier<bool>(false);

  /// 文档是否为空（只有空段落）。空文档时显示占位提示文字。
  /// 单独用 ValueNotifier：每敲一个字都要判断，但不该重建整页。
  final ValueNotifier<bool> _documentEmpty = ValueNotifier<bool>(true);

  /// 最近一次有效选区。打开 Aa/插入面板会让编辑器失焦、选区被清空，
  /// 面板里的命令随后就找不到操作对象（实测点 H2 只有面板关闭、标题没变）。
  /// 这里留一份快照，面板关闭后先恢复选区再执行命令。
  DocumentSelection? _lastSelection;

  /// 是否有底部面板正在打开。
  ///
  /// 面板打开期间 composer 选区会被折叠成光标，如果让
  /// [_refreshActiveCommands] 继续刷新快照，就会把「用户选中的一段文字」
  /// 覆盖成「一个光标」（实测：标题全选后加粗，只有最后一个字变粗）。
  /// 打开面板的那一帧冻结快照，关闭时再恢复。
  bool _panelOpen = false;

  /// 行内样式「输入态」作用的节点。
  ///
  /// 折叠光标点加粗/斜体等，样式写入 composer 的输入态，只对接下来输入的
  /// 文字生效。这个作用范围应该只留在当前块：光标移到别的块或变成展开
  /// 选区时清空，避免「在 A 段点了加粗，去 B 段打字还是加粗」的残留
  /// （主流编辑器 Word / Notion 同语义）。
  String? _typingStyleNodeId;

  /// SuperEditor 自己的焦点节点。面板关闭后（选区可能被清空）用
  /// requestFocus 把 IME 和光标一起接回来，避免「键盘在、光标没了」。
  final FocusNode _editorFocus = FocusNode(debugLabel: 'xiaoji-editor');

  /// 文档布局的渲染入口：分享长图直接复用它，保证与详情页同一份排版。
  final GlobalKey _documentLayoutKey = GlobalKey();

  /// 输入法层粘贴拦截器：覆盖 Gboard 剪贴板建议这条路径。
  late final PasteImeDecorator _pasteImeDecorator;

  /// 当前剪贴板快照：用于识别「这次 IME 插入其实就是粘贴」。
  String? _clipboardText;
  String? _clipboardHtml;

  /// 防止一次粘贴触发多轮解析。
  bool _handlingImePaste = false;

  /// 底部工具条高度（与 MarkdownToolbar 的 SizedBox 一致）。
  ///
  /// 编辑态要从正文视口里扣掉这一条：工具条是浮层，不参与 Column 布局，
  /// 不预留的话它会盖住正文最后一条（用户反馈「工具栏和输入法遮挡内容」）。
  static const double _toolbarHeight = AppSize.navBar;

  /// Android 选择控件接管：内建选择条文案写死英文，这里通过 controller
  /// 的 toolbarBuilder 注入中文胶囊工具条（OverlayManager 优先取它，
  /// 定位/边界避让仍走内核 Follower 体系）。
  late final SuperEditorAndroidControlsController _androidControls =
      _XiaojiAndroidControlsController(
    toolbarBuilder:
        (BuildContext context, Key mobileToolbarKey, LeaderLink focalPoint) =>
            XiaojiSelectionToolbar(
      floatingToolbarKey: mobileToolbarKey,
      focalPoint: focalPoint,
      editorOps: _ops,
      controls: _androidControls,
      onPaste: _pasteFromClipboard,
    ),
  );

  final ImagePicker _imagePicker = ImagePicker();

  /// 当前展开的工具条子菜单（none = 未展开）。
  ///
  /// 严格对齐语雀：子菜单在**工具条下方**展开；展开时先收起输入法，
  /// 面板铺在原键盘区域，工具条本身位置不动。
  MarkdownToolbarPanel _panel = MarkdownToolbarPanel.none;

  /// 面板/键盘交替期间钉住工具条的「键盘高度」。
  ///
  /// 收起键盘后 `viewInsets` 是逐帧回落的；如果工具条只按 0 定位，会先
  /// 掉到屏幕底部、键盘回来时再被顶上去（用户反馈「下移一下再顶上来」）。
  /// 用这个锚点让工具条在键盘升降的整段过程中保持同一个屏幕 Y：
  /// `bottom = 锚点 - 当前 ime`；键盘回到原高度时自然变成 0。
  double? _toolbarAnchorIme;

  /// 面板已收起、正在等键盘回来（期间不清理锚点、不做光标校正）。
  bool _panelClosing = false;

  /// 面板刚展开、正在等键盘收下去。
  ///
  /// 键盘回落需要几帧，这期间 ime 仍 > 0；没有这个标记会把「键盘还在
  /// 回落」误判成「键盘回来了」而立刻关掉刚打开的面板。
  bool _panelOpeningUntilHidden = false;

  bool get _panelExpanded => _panel != MarkdownToolbarPanel.none;

  /// 是否处在「面板 ↔ 键盘」的交替过程中。
  ///
  /// 这段时间视口在变，但光标位置不该被纠正（否则切面板/回键盘就会
  /// 莫名滚动），所有自动落位都让位。
  bool get _panelTransitioning =>
      _toolbarAnchorIme != null || _panelExpanded || _panelClosing;

  /// 正文滚动控制器。
  ///
  /// 交给 SuperEditor 后，光标被输入法/工具条挡住时可以精确滚动到它；
  /// 不传的话框架自建一个内部控制器，外部就拿不到滚动位置。
  /// 用 [_CaretAwareScrollController] 把框架发起的「瞬时跳转」改成
  /// 逐帧平滑滚动（见 [_onExternalCaretJump]）。
  final _CaretAwareScrollController _editorScroll =
      _CaretAwareScrollController();

  Timer? _saveDebounce;
  bool _disposed = false;

  /// 正在销毁：dispose 里会同步落盘，此时元素已 defunct，不能再 setState。
  bool _disposing = false;
  DateTime _updated;

  /// 最近一次真正落盘的正文。
  ///
  /// 保存去重必须和它比，不能和 [NewEditorPage.note] 的初始 body 比：
  /// 用户改了一处又改回原样时，body 会和「打开时」一致，于是跳过保存，
  /// 磁盘上反而留着中间那次改动（实测：输入后退格删掉，列表卡片仍是脏的）。
  late String _lastSavedBody;

  /// 用户是否真的改过文档。
  ///
  /// 只打开不编辑时，序列化器可能对存量笔记做一次格式规范化（多行引用
  /// 补 `>` 前缀等），内容与原文不同。没有这个标记，「打开看一眼就退」
  /// 也会落盘并刷新 updated，列表顺序被无端打乱（老 bug 的另一种形态）。
  bool _dirty = false;

  /// 当前是否已开启 FLAG_SECURE（锁定笔记打开期间）。
  ///
  /// 单独记一份：dispose 时只有真的开过才需要恢复，避免影响普通笔记。
  bool _secureScreenApplied = false;

  /// 本页在截屏保护持有者里的 key（按笔记 id 区分）。
  late final String _secureKey = 'note:${widget.note.id}';

  _NewEditorPageState() : _updated = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    // 逐帧滚动驱动器：见 [_requestCaretScroll] / [_onCaretScrollTick]。
    _caretScrollTicker = createTicker(_onCaretScrollTick);
    _editorScroll.onExternalJump = _onExternalCaretJump;
    _updated = widget.note.updated;
    _lastSavedBody = widget.note.body;
    _document = deserializeXiaojiMarkdown(widget.note.body);
    _composer = MutableDocumentComposer();
    _editor = createXiaojiEditor(document: _document, composer: _composer);
    _ops = CommonEditorOperations(
      document: _document,
      editor: _editor,
      composer: _composer,
      documentLayoutResolver: () => throw UnimplementedError('M1 不依赖布局解析器'),
    );
    // 键盘剪贴板粘贴拦截：Gboard 的粘贴走 IME，不经过工具条。
    _pasteImeDecorator = PasteImeDecorator(
      shouldIntercept: _shouldInterceptImePaste,
      onPaste: _handleImePaste,
    );
    _editorFocus.addListener(_onEditorFocusChanged);
    _refreshClipboardSnapshot();
    _commands = KernelCommands(
      editor: _editor,
      document: _document,
      composer: _composer,
      ops: _ops,
    );
    // 文档变化：除了存盘，还要刷新工具条激活态（比如点了「待办」后
    // 按钮要立刻点亮）。集合没变时 computeActive 不触发重建，不会死循环。
    _editor.addListener(
      FunctionalEditListener((List<EditEvent> _) {
        _dirty = true;
        _scheduleSave();
        _refreshActiveCommands();
        _syncHistoryButtons();
        _syncDocumentEmpty();
      }),
    );
    // 选区变化：块级激活态跟着光标所在行走，只需要监听 composer。
    _composer.addListener(_refreshActiveCommands);
    _syncDocumentEmpty();
    // 输入法弹出/收起会改变可用视口：等布局结算后再校正一次光标可见性。
    WidgetsBinding.instance.addObserver(this);
    // 锁定笔记：编辑期间禁止截屏 / 多任务预览（设置里可关）。
    _applySecureScreen();
    // 新建小记：等首帧布局完成后聚焦编辑器并拉起输入法。
    // 打开已有笔记（autoFocus=false）保持浏览态，不主动弹键盘。
    if (widget.autoFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) {
          return;
        }
        _placeInitialCaret();
        _editorFocus.requestFocus();
        _retryInitialFocusIfNeeded();
      });
    }
  }

  /// 把光标落到第一个文本块。
  ///
  /// super_editor 的 IME 输入依赖选区，只 requestFocus 会出现「键盘弹了、
  /// 打字没反应」。必须走 editor 命令而不是 composer.setSelection：后者
  /// 只改 selectionNotifier，不触发 EditListener，工具条不会亮起来。
  void _placeInitialCaret() {
    if (_composer.selection != null) {
      return;
    }
    final TextNode? first = _firstTextNode();
    if (first == null) {
      return;
    }
    _editor.execute(<EditRequest>[
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: first.id,
            nodePosition: const TextNodePosition(offset: 0),
          ),
        ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    ]);
  }

  /// 冷启动（桌面图标长按「新建小记」）时补一次聚焦。
  ///
  /// 走快捷方式冷启动时，首帧执行 requestFocus 的那一刻系统还没把窗口
  /// 焦点交给 App，IME 连接建立但不会被「显示」，表现就是「页面进来了、
  /// 键盘没弹」。等窗口稳定后再走一次焦点 gain（openConnection 会带
  /// showKeyboard: true）。已经在弹键盘的场景（App 内新建）直接跳过，
  /// 不做无谓的失焦/再聚焦。
  void _retryInitialFocusIfNeeded() {
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (_disposed || !mounted) {
        return;
      }
      if (MediaQuery.viewInsetsOf(context).bottom > 0) {
        return;
      }
      _editorFocus.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) {
          return;
        }
        // unfocus 会清掉选区（官方 policy），重新落一次光标再聚焦。
        _placeInitialCaret();
        _editorFocus.requestFocus();
      });
    });
  }

  /// 文档里第一个文本块（新建时用来落初始光标）。
  TextNode? _firstTextNode() {
    for (final DocumentNode node in _document) {
      if (node is TextNode) {
        return node;
      }
    }
    return null;
  }

  /// 文档是否「空」且需要显示占位提示。
  ///
  /// 只有空段落才算空；图片/附件/分隔线等非文本块也算有内容。
  /// 另外要求**首个块是普通段落**：首块被切成 H1/引用/列表时，它们的
  /// 行盒高度、缩进、段前距都和 15.5 正文不同，占位提示会与光标错位
  /// （用户反馈「设成 H1 后提示语和光标偏移」）。
  void _syncDocumentEmpty() {
    bool empty = true;
    DocumentNode? first;
    for (final DocumentNode node in _document) {
      first ??= node;
      if (node is! TextNode || node.text.length > 0) {
        empty = false;
        break;
      }
    }
    if (empty) {
      final blockType = first?.getMetadataValue(NodeMetadata.blockType);
      empty = blockType == null || blockType == paragraphAttribution;
    }
    if (_documentEmpty.value != empty) {
      _documentEmpty.value = empty;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 立即落盘，不留给防抖计时器（页面可能在计时器到期前销毁）。
    _saveDebounce?.cancel();
    _caretFollowTimer?.cancel();
    _anchorReleaseTimer?.cancel();
    _imeCollapseTimer?.cancel();
    _detachImeScrollListener();
    _caretFollowing = false;
    _caretScrollTarget = null;
    _caretScrollTicker.dispose();
    _disposing = true;
    _flushSave();
    // 锁定笔记关闭 / 取消锁定后注销截屏保护。
    if (_secureScreenApplied) {
      _secureScreenApplied = false;
      kSecurity.setSecureHolder(_secureKey, false).catchError((Object _) {});
    }
    _activeCommands.dispose();
    _editing.dispose();
    _canUndo.dispose();
    _canRedo.dispose();
    _documentEmpty.dispose();
    _editorFocus.removeListener(_onEditorFocusChanged);
    _editorFocus.dispose();
    _editorScroll.dispose();
    _editor.dispose();
    _composer.dispose();
    _document.dispose();
    _disposed = true;
    super.dispose();
  }

  /// 最近一次参与「键盘升降」判定的输入法高度。
  ///
  /// 判定放在 [build] 里做：`didChangeMetrics` 回调时 MediaQuery 还没重建，
  /// 读到的可能是旧值（实测「键盘收起」分支经常进不来）。build 每一帧都
  /// 拿到最新 `viewInsets`，这个判断才可靠。
  double _lastSyncedIme = 0;

  /// 键盘正在收起 / 刚收起的窗口。
  ///
  /// 收起时视口变大，光标本来就可见，但框架/内核在布局结算后仍会调用
  /// `ensureOffsetIsVisible` 或重算布局，把滚动位置往回带（用户反馈：
  /// 带图片的笔记收起键盘后整页往下移动）。这段时间内：
  ///  - 吞掉所有自动落位（[_ensureCaretVisible] / [_onExternalCaretJump]）；
  ///  - 监听滚动位置，一旦被程序性改动就还原到收起前的 offset。
  bool _imeCollapsing = false;
  Timer? _imeCollapseTimer;

  /// 键盘开始收起那一刻的滚动位置。
  double? _imeCollapseAnchorPixels;

  /// 滚动监听是否已挂上（避免重复 addListener）。
  bool _imeScrollListenerAttached = false;

  /// 防止「还原滚动」自身触发监听造成递归。
  bool _restoringImeScroll = false;

  /// 已排队的还原（同一个帧里的多次滚动通知只还原一次）。
  bool _imeRestorePending = false;

  /// 用户是否正用手指拖动滚动（区别于内核的 ballistic/自动滚动）。
  ///
  /// 判定来自 [ScrollStartNotification.dragDetails]：只有手指拖动才有
  /// dragDetails，`goBallistic` 之类的程序性滚动没有。
  bool _userDraggingScroll = false;

  /// 键盘收起后为「保住视觉位置」而临时补的底部留白。
  ///
  /// 关键场景：笔记内容不足一屏（如三段文字 + 两张图）。键盘弹起时视口
  /// 变矮、内容可滚动，光标被抬到 offset≈313；键盘收起后视口变高，内容
  /// 全部塞得下，`maxScrollExtent` 直接变成 0 —— 滚动位置被物理性地
  /// 夹回 0，正文整块往下移。此时任何 jumpTo 都无效（没有可滚动范围），
  /// 只能在底部补一段留白把「可滚动范围」补回来，视觉位置才真的不动。
  double _imeCollapseBottomPad = 0;

  /// 按当前输入法高度结算「键盘弹起 / 收起」。
  ///
  /// 只在高度真的变化时干活，键盘升降动画的每一帧都会走到这里：
  ///  - 变高：取消收起保护，等停稳后把光标抬到舒适位；
  ///  - 变矮：进入收起保护，记录 offset 并在停稳后核对/还原。
  void _syncImeState(double ime) {
    if (_disposed) {
      return;
    }
    final double previous = _lastSyncedIme;
    if (ime == previous) {
      return;
    }
    _lastSyncedIme = ime;
    if (ime > previous) {
      _endImeCollapse();
      _scheduleCaretFollow();
      // 键盘弹出说明用户要输入了：快照还空着就再读一次（切应用复制后
      // 立刻回来粘贴时，resumed 那次读可能还没拿到焦点）。
      if (_clipboardText == null || _clipboardText!.isEmpty) {
        _refreshClipboardSnapshot();
      }
      return;
    }
    _beginImeCollapse(previousIme: previous);
  }

  void _beginImeCollapse({required double previousIme}) {
    if (!_imeCollapsing) {
      _imeCollapsing = true;
      _cancelCaretFollow();
    }
    final ScrollPosition? position =
        _editorScroll.hasClients ? _editorScroll.position : null;
    _imeCollapseAnchorPixels ??= position?.pixels;
    // 关键：在「键盘开始收起的那一帧」就把底部留白算好并写进样式表。
    // 之前是等布局按新视口结算完、下一帧才 setState 补留白 —— 那一帧
    // 滚动位置已经被 maxScrollExtent clamp，页面先掉下去再补回来，
    // 看起来就是「闪一下 / 抖一下」（用户反馈）。
    _pinContentDuringImeCollapse(previousIme);
    if (!_imeScrollListenerAttached) {
      // 挂在 controller 上而不是某个 ScrollPosition：视口尺寸变化时
      // Scrollable 可能重建并换掉 position，挂在旧 position 上会漏掉
      // 新的滚动通知（实测：日志里 offset 没变，页面却回到了顶部）。
      _editorScroll.addListener(_onScrollDuringImeCollapse);
      _imeScrollListenerAttached = true;
    }
    // 键盘收起动画 + 布局结算大约 300ms；留到 600ms 覆盖慢速输入法，
    // 期间用户主动滑动优先（见监听里的 isScrollingNotifier 判断）。
    // 等布局按新视口结算完，算出「还差多少可滚动范围」再补留白。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_imeCollapsing || !mounted || !_editorScroll.hasClients) {
        return;
      }
      final double? anchor = _imeCollapseAnchorPixels;
      if (anchor == null) {
        return;
      }
      final ScrollPosition position = _editorScroll.position;
      final double deficit = anchor - position.maxScrollExtent;
      if (deficit > 1 && deficit > _imeCollapseBottomPad) {
        setState(() => _imeCollapseBottomPad = deficit);
      }
    });
    _imeCollapseTimer?.cancel();
    _imeCollapseTimer = Timer(const Duration(milliseconds: 600), () {
      _imeCollapseTimer = null;
      _imeCollapsing = false;
      _restoreScrollAfterImeCollapse();
      _detachImeScrollListener();
      _imeCollapseAnchorPixels = null;
    });
  }

  /// 键盘开始收起时，一次性把「最终需要的底部留白」算出来。
  ///
  /// 收起动画里视口高度单调变大，最终高度是确定的：
  ///   最终视口 = 当前视口 + 本次收起的键盘总高度 + 工具条预留（会一起撤掉）
  /// 内容高度不变，于是：
  ///   最终 maxScrollExtent = 内容高度 - 最终视口
  ///   需要的留白 = 锚点 offset - 最终 maxScrollExtent（小于 0 则不需要）
  /// 留白从第一帧就生效，之后每一帧 `maxScrollExtent` 都 ≥ 锚点，
  /// 滚动位置永远不会被 clamp —— 视觉上完全不动，也不会有补丁式闪烁。
  void _pinContentDuringImeCollapse(double previousIme) {
    if (!mounted || previousIme <= 0 || !_editorScroll.hasClients) {
      return;
    }
    // 面板/键盘交替由 [_reconcilePanelWithKeyboard] 的锚点补偿负责，
    // 这里再补留白会双重计算。
    if (_panelTransitioning) {
      return;
    }
    final ScrollPosition position = _editorScroll.position;
    final double anchor = _imeCollapseAnchorPixels ?? position.pixels;
    // 停在顶部时视口变高不会让内容移动，不需要留白。
    if (anchor <= 0) {
      return;
    }
    // 键盘归零后工具条预留会一起撤掉，视口还要再高出一条工具栏。
    final double reserveDrop =
        (_panelOpen || _panelTransitioning) ? 0 : _toolbarHeight;
    final double contentExtent =
        position.maxScrollExtent + position.viewportDimension;
    final double viewportFinal =
        position.viewportDimension + previousIme + reserveDrop;
    final double needed =
        math.max(0.0, anchor - (contentExtent - viewportFinal));
    if (needed > _imeCollapseBottomPad) {
      // 在 build 里同步赋值（不 setState）：同一次 build 稍后构造
      // stylesheet 时会读到新值，留白和视口在同一帧生效。
      _imeCollapseBottomPad = needed;
    }
  }

  void _endImeCollapse() {
    _imeCollapsing = false;
    _imeCollapseTimer?.cancel();
    _imeCollapseTimer = null;
    _imeCollapseAnchorPixels = null;
    _detachImeScrollListener();
    // 键盘重新弹起：视口变矮、内容重新可滚动，临时留白必须撤掉，
    // 否则底部会多出一截空白。此时光标落位会接管滚动，撤留白不跳。
    if (_imeCollapseBottomPad > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_imeCollapsing && _imeCollapseBottomPad > 0) {
          setState(() => _imeCollapseBottomPad = 0);
        }
      });
    }
  }

  void _detachImeScrollListener() {
    if (!_imeScrollListenerAttached) {
      return;
    }
    _imeScrollListenerAttached = false;
    _editorScroll.removeListener(_onScrollDuringImeCollapse);
  }

  /// 收起窗口内滚动位置被改动：排一帧后还原。
  ///
  /// 不能在滚动通知里直接 `jumpTo`（可能发生在布局阶段），
  /// 用 post-frame 延迟一帧最稳。
  void _onScrollDuringImeCollapse() {
    if (!_imeCollapsing || _restoringImeScroll || _imeRestorePending) {
      return;
    }
    final double? anchor = _imeCollapseAnchorPixels;
    if (anchor == null || !_editorScroll.hasClients) {
      return;
    }
    final ScrollPosition position = _editorScroll.position;
    if ((position.pixels - anchor).abs() < 1) {
      return;
    }
    // 内核在键盘收起后会启动一个 ballistic 活动把正文缓动回顶部
    // （日志实测 velocity 约 -1200px/s）。它全程 `scrolling=true`，
    // 但不是用户拖动 —— 用 dragDetails 判定，只有手指拖动才让位。
    if (_userDraggingScroll) {
      return;
    }
    _imeRestorePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _imeRestorePending = false;
      if (!_imeCollapsing) {
        return;
      }
      _restoreScrollAfterImeCollapse();
    });
  }

  /// 把滚动位置还原到键盘收起前。
  ///
  /// 目标会按当前可滚动范围夹一下（内容变短时避免还原到越界值）。
  void _restoreScrollAfterImeCollapse() {
    final double? anchor = _imeCollapseAnchorPixels;
    if (_disposed || !mounted || anchor == null) {
      return;
    }
    if (!_editorScroll.hasClients) {
      return;
    }
    final ScrollPosition position = _editorScroll.position;
    // 注意：这里**不能**因为 `isScrollingNotifier` 为 true 就放弃还原。
    // 内核的 ballistic 动画全程都是 scrolling=true，正是它把页面带回顶部。
    // 还原用 jumpTo，它会顺带停掉当前滚动活动。
    final double target = anchor.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((position.pixels - target).abs() < 1) {
      return;
    }
    _restoringImeScroll = true;
    _tickerJumping = true;
    try {
      position.jumpTo(target);
    } finally {
      _tickerJumping = false;
      _restoringImeScroll = false;
    }
  }

  @override
  void didChangeMetrics() {
    // 仅作为兜底：真正的判定在 build 里（didChangeMetrics 触发时
    // MediaQuery 可能还没更新，读到的是旧高度）。
    _syncImeState(MediaQuery.viewInsetsOf(context).bottom);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退到后台 / 切走 / 被系统回收前，立即落盘。
    //
    // 之前只有 800ms 防抖 + dispose：用户打完字马上按 Home，进程被
    // 系统杀掉时最后一段内容就丢了。这里跳过防抖直接写，原子 rename
    // 保证不会写出半截文件。
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _saveDebounce?.cancel();
      _flushSave();
    } else if (state == AppLifecycleState.resumed) {
      // 从浏览器/微信切回来，剪贴板已经变了：刷新快照，键盘粘贴才能识别。
      _refreshClipboardSnapshot();
    }
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 800), _flushSave);
  }

  /// 这条笔记已经被删除：dispose 时绝不能再回写。
  ///
  /// 删除后页面 pop，`dispose` 里的 [_flushSave] 若还带着未落盘的正文，
  /// 会把刚删掉的笔记重新写回 notes/ 并重新插进列表 —— 用户看到的就是
  /// 「删了又回来」。
  bool _discarded = false;

  Future<void> _flushSave() async {
    if (_disposed || _discarded) {
      return;
    }
    // 用小记方言序列化器（自带的不保真，见 xiaoji_markdown.dart 头注释）。
    final md = serializeDocumentToXiaojiMarkdown(_document);
    // 内容没变就绝不落盘：dispose 里是无条件调用这里，「打开看一眼就退」
    // 也会走到——没有这个短路，updated 会被无端刷新（老 bug，M1 修过一次，
    // M2 重写保存逻辑时丢了，用户再次抓到。内容一致就一个字都不动）。
    // 比较对象是「最近一次落盘内容」而不是打开时的 body：改回原样也必须
    // 落盘，否则磁盘上留着上一次改动（见 _lastSavedBody 注释）。
    // 没编辑过就直接返回：序列化器的格式规范化不该顶掉 updated。
    if (!_dirty || md == _lastSavedBody) {
      return;
    }
    final String previousSavedBody = _lastSavedBody;
    _dirty = false;
    _lastSavedBody = md;
    _updated = DateTime.now();
    if (mounted && !_disposing) {
      setState(() {});
    }
    _currentNote = Note(
      id: _currentNote.id,
      created: _currentNote.created,
      updated: _updated,
      tags: _currentNote.tags,
      pinned: _currentNote.pinned,
      locked: _currentNote.locked,
      body: md,
    );
    try {
      await widget.repository.upsert(_currentNote);
    } catch (error) {
      // 写盘失败（磁盘满、权限等）时不能装作已保存：恢复 dirty 与
      // 「上次落盘内容」，下一次防抖 / 退出会重试，并明确告诉用户。
      _dirty = true;
      _lastSavedBody = previousSavedBody;
      if (mounted && !_disposing) {
        _showHint('保存失败：$error');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 工具条命令 / 附件
  // ---------------------------------------------------------------------------

  /// 刷新工具条激活态。只在集合真的变化时才通知监听者：
  /// 每敲一个字 composer/editor 都会回调，集合没变就重建工具条纯属浪费。
  void _refreshActiveCommands() {
    final selection = _composer.selection;
    // 有效选区才更新快照：面板打开时选区会被清空，这一帧不能覆盖掉
    // 「打开前用户正在编辑的位置」。面板打开期间整体冻结（见 _panelOpen）。
    if (selection != null && !_panelOpen) {
      _lastSelection = selection;
    }
    final bool nowEditing = selection != null;
    if (_editing.value != nowEditing) {
      _editing.value = nowEditing;
      if (nowEditing) {
        // 进入编辑态 = 键盘与工具条即将出现：工具条是浮层，正文视口会被
        // 压矮一截，跟随键盘一起把光标抬到舒适位。
        _scheduleCaretFollow();
      } else {
        // 离开编辑态（收起工具栏 / 回到浏览）：子菜单必须一并收起，
        // 否则下次调起工具栏还带着上次展开的面板（用户反馈）；
        // 工具条锚点也一并释放，否则下次会出现「钉在半空」。
        if (_panelExpanded) {
          _closePanel(showKeyboard: false);
        }
        _toolbarAnchorIme = null;
        _panelClosing = false;
        _panelOpeningUntilHidden = false;
      }
    }
    // 输入态只留在点击样式时的那个块：光标跨块移动或变成展开选区时清空，
    // 避免样式残留到下一段的输入（对齐 Word / Notion 的 typing style）。
    if (_typingStyleNodeId != null && selection != null) {
      bool clear = !selection.isCollapsed ||
          selection.extent.nodeId != _typingStyleNodeId;
      // 同一块内换行也要结束输入态：代码块里回车是插入字面 `\n`
      // （节点不变），旧逻辑会让行内码/加粗延续到下一行。Notion、语雀
      // 的行内样式遇到换行即失效，不会带过行。
      if (!clear && selection.isCollapsed) {
        final node = _editor.document.getNodeById(selection.extent.nodeId);
        final position = selection.extent.nodePosition;
        if (node is TextNode &&
            position is TextNodePosition &&
            position.offset > 0 &&
            node.text.toPlainText().codeUnitAt(position.offset - 1) == 0x0A) {
          clear = true;
        }
      }
      if (clear) {
        _typingStyleNodeId = null;
        _composer.preferences.clearStyles();
      }
    }
    // 光标/换行位置可能被输入法挡住：布局结算后校正一次可见性。
    _scheduleCaretVisibilityCheck();
    final next = _commands.computeActiveCommands();
    if (setEquals(_activeCommands.value, next)) {
      return;
    }
    _activeCommands.value = next;
  }

  /// 光标可见性检查是否已排队（同一帧内的多次选区通知只查一次）。
  bool _caretVisibilityPending = false;

  void _scheduleCaretVisibilityCheck() {
    if (_caretVisibilityPending || _disposed) {
      return;
    }
    // 键盘/面板正在切换时不做校正：那时视口还是中间态，校正会把光标
    // 拉来拉去；停稳后的落位由 [_scheduleCaretFollow] 统一处理。
    if (_panelTransitioning || _caretFollowing || _imeCollapsing) {
      return;
    }
    _caretVisibilityPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _caretVisibilityPending = false;
      if (_panelTransitioning ||
          _caretFollowing ||
          _imeCollapsing ||
          _disposed) {
        return;
      }
      // 滚动正在执行时也照常算一次：只更新目标，不重启动画
      // （见 [_requestCaretScroll]），连续输入时轨迹才连续。
      _ensureCaretVisible();
    });
  }

  /// 逐帧平滑滚动的当前目标（null = 没有待执行的滚动）。
  ///
  /// 用 [Ticker] 自己收敛，而不是 `ScrollController.animateTo`：后者每次
  /// 调用都会从零速度重新开一段曲线，输入/退格时目标随光标逐帧变化，
  /// 观感就是「一顿一顿、一跳一跳」。逐帧收敛只改变剩余距离、不重置
  /// 速度，目标怎么变，光标所在行的轨迹都是连续的。
  double? _caretScrollTarget;

  /// 上一帧的时间戳：按真实帧间隔换算收敛系数（高刷屏不会变快）。
  Duration _caretScrollLastTick = Duration.zero;

  late final Ticker _caretScrollTicker;

  /// 逐帧驱动器自己调用 jumpTo 时为 true：此时不能被当成「外部跳转」接管。
  bool _tickerJumping = false;

  /// 正在等键盘/视口停稳。
  bool _caretFollowing = false;

  /// 停稳检测：连续多少帧「视口 + 输入法高度」不变。
  int _followStableFrames = 0;
  double? _followLastViewport;
  double? _followLastIme;

  /// 最近一帧的输入法高度（build 时刷新，供停稳检测用）。
  double _imeInset = 0;

  Timer? _caretFollowTimer;

  /// 锚点释放兜底计时器（见 [_scheduleAnchorRelease]）。
  Timer? _anchorReleaseTimer;

  /// 键盘停稳后，一次性平滑抬到舒适位。
  ///
  /// 键盘动画期间 body/视口每帧都在变，如果逐帧跟手，会在 IME 最后
  /// 回弹的那一两帧里把内容来回拉扯（用户反馈「滑上去又回滑一下」）。
  /// 这里改成：等「视口 + 输入法高度」连续 4 帧不变（动画真正结束），
  /// 再执行**一次** 280ms 的缓出动画。慢一点、一次到位，不会回滑。
  void _scheduleCaretFollow() {
    // 键盘正在收起：视口在变大，任何落位都会把正文往下拽。
    if (_disposed || _panelTransitioning || _imeCollapsing) {
      return;
    }
    // 视口（键盘）开始变化：先停掉正在执行的落位。滚动与键盘动画叠加
    // 会出现「先滑上去、停稳后再补一下 / 回滑一下」的两段式观感。
    _stopCaretScroll();
    if (_caretFollowing) {
      return;
    }
    _caretFollowing = true;
    _followStableFrames = 0;
    _followLastViewport = null;
    _followLastIme = null;
    WidgetsBinding.instance.addPostFrameCallback(_followTick);
    // 兜底：极端情况下（一直读不到视口）也不要无限等待。
    _caretFollowTimer?.cancel();
    _caretFollowTimer = Timer(const Duration(milliseconds: 700), () {
      if (!_caretFollowing) {
        return;
      }
      _caretFollowing = false;
      _applyCaretComfort();
    });
  }

  void _followTick(Duration _) {
    if (!_caretFollowing) {
      return;
    }
    if (_disposed || !mounted || _panelTransitioning) {
      _caretFollowing = false;
      _caretFollowTimer?.cancel();
      return;
    }
    final double? viewport = _editorScroll.hasClients
        ? _editorScroll.position.viewportDimension
        : null;
    if (viewport != null &&
        viewport == _followLastViewport &&
        _imeInset == _followLastIme) {
      _followStableFrames++;
    } else {
      _followStableFrames = 0;
      _followLastViewport = viewport;
      _followLastIme = _imeInset;
    }
    if (_followStableFrames >= 4) {
      _caretFollowing = false;
      _caretFollowTimer?.cancel();
      _applyCaretComfort();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback(_followTick);
  }

  /// 执行一次落位计算（由逐帧驱动器平滑移动过去）。
  void _applyCaretComfort() {
    if (_disposed || !mounted || _panelTransitioning) {
      return;
    }
    _ensureCaretVisible(forceComfort: true);
  }

  /// 取消尚未执行的跟进（进入面板/键盘交替时调用）。
  void _cancelCaretFollow() {
    _caretFollowTimer?.cancel();
    _caretFollowTimer = null;
    _caretFollowing = false;
    // 面板/键盘交替期间不许有任何自动滚动（用户明确要求这段不要滑动）。
    _stopCaretScroll();
  }

  /// 光标下沿距视口底部小于这个距离，才认为「快贴到键盘/工具条了」。
  static const double _caretTriggerGap = 10;

  /// 跟进滚动落点：光标下沿与视口底部之间保留的空白（约 5 行正文 26）。
  static const double _caretComfortGap = 132;

  /// 光标在上方被遮住时向上滚的余量（约两行）。
  static const double _caretTopGap = 52;

  /// 正文行盒高度（字号 15.5 × 行高 1.7）：滚动目标按它取整。
  static const double _caretLineHeight = 26.35;

  /// 光标被输入法/工具条挡住时，把正文滚到「舒适位置」。
  ///
  ///  - **触发**：光标进入下方舒适区（[forceComfort]）或贴到视口底部
  ///    （日常输入）才滚。光标在可视区中部时一像素都不动。
  ///  - **落点**：滚到光标下方留约 5 行空白（[_caretComfortGap]）的位置，
  ///    而不是「刚好露出」——一次滚动能覆盖后续 4~5 行输入。
  ///  - **节奏**：只更新滚动目标，由 [_caretScrollTicker] 逐帧收敛过去；
  ///    连续输入/删除时目标反复更新也不会重启动画，光标所在行始终
  ///    平滑移动（不用 animateTo —— 每次调用都会把速度清零重来）。
  ///
  /// 落点留白不超过视口高度的 1/3：小视口不会把光标推到屏幕上半区。
  /// 光标在上方被遮住时维持「只补两行」，不做居中。
  void _ensureCaretVisible({bool forceComfort = false}) {
    if (_disposed || !mounted || !_editorScroll.hasClients) {
      return;
    }
    if (_panelTransitioning || _imeCollapsing) {
      // 面板/键盘交替、键盘收起期间视口是中间态：任何滚动都会造成
      // 「先滑一下、后面再补一下」的两段式观感。这段过程一律不动。
      return;
    }
    final selection = _composer.selection;
    if (selection == null || !selection.isCollapsed) {
      return;
    }

    final Rect? caret;
    try {
      final DocumentLayoutEditable layoutEditable =
          _editor.context.find<DocumentLayoutEditable>(Editor.layoutKey);
      caret =
          layoutEditable.documentLayout.getRectForPosition(selection.extent);
    } catch (_) {
      // 布局尚未挂载 / 该位置不是文本（附件、图片）：无需也不该滚动。
      return;
    }
    if (caret == null || caret.height <= 0) {
      return;
    }

    final ScrollPosition position = _editorScroll.position;
    final double viewTop = position.pixels;
    final double viewBottom = position.pixels + position.viewportDimension;
    final double comfortGap = math.min(
      _caretComfortGap,
      position.viewportDimension / 3,
    );
    final double triggerGap = forceComfort ? comfortGap : _caretTriggerGap;

    double? target;
    if (caret.bottom > viewBottom - triggerGap) {
      target = caret.bottom + comfortGap - position.viewportDimension;
    } else if (caret.top < viewTop + _caretTopGap) {
      target = caret.top - _caretTopGap;
    }
    if (target == null) {
      return;
    }
    // 目标按行高取整：同一行内继续打字/退格时目标不变，不会每次都
    // 重新开一段动画（观感上就不会「一跳一跳」）；只有真的跨行时才
    // 平滑上移一行。
    final double snapped =
        (target / _caretLineHeight).roundToDouble() * _caretLineHeight;
    final double clamped = snapped.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((clamped - position.pixels).abs() < 1) {
      return;
    }
    _requestCaretScroll(clamped);
  }

  /// 请求把正文平滑滚到 [target]。
  ///
  /// 不直接开动画，只更新「当前目标」，由 [_caretScrollTicker] 逐帧收敛。
  /// 连续输入时目标会被反复更新，但速度/轨迹不重置，光标行就是一条
  /// 连续的平滑轨迹（用户反馈「一跳一跳」「不卡一卡的」）。
  void _requestCaretScroll(double target) {
    _caretScrollTarget = target;
    if (!_caretScrollTicker.isActive) {
      _caretScrollTicker.start();
    }
  }

  void _stopCaretScroll() {
    if (_caretScrollTicker.isActive) {
      _caretScrollTicker.stop();
    }
    _caretScrollTarget = null;
    _caretScrollLastTick = Duration.zero;
  }

  /// 每帧把剩余距离消掉固定比例（指数收敛）。
  ///
  /// 系数按真实帧间隔归一化到 16.7ms：60Hz / 120Hz 手感一致，丢帧后也
  /// 不会一步跳太远。每帧约 22%：一行（26.35）的移动约 200ms 到位，
  /// 起步带着缓出，不会「突然上跳」。
  void _onCaretScrollTick(Duration elapsed) {
    final double dtMs =
        (elapsed - _caretScrollLastTick).inMicroseconds / 1000.0;
    _caretScrollLastTick = elapsed;
    if (_disposed || !mounted || !_editorScroll.hasClients) {
      _stopCaretScroll();
      return;
    }
    final ScrollPosition position = _editorScroll.position;
    // 手指拖动/惯性滑动期间让手势优先：jumpTo 会打断滚动活动，必须先退出。
    if (position.isScrollingNotifier.value) {
      _stopCaretScroll();
      return;
    }
    final double? target = _caretScrollTarget;
    if (target == null) {
      _stopCaretScroll();
      return;
    }
    // 内容可能刚缩短（删除行），上限每帧都按当前几何重新夹一次。
    final double destination = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final double remaining = destination - position.pixels;
    if (remaining.abs() < 0.5) {
      _jumpCaretScrollTo(position, destination);
      _stopCaretScroll();
      return;
    }
    // 首帧 dt 可能为 0（与 start 同一帧），按一帧算；丢帧最多补 3 帧的量。
    final double frames = dtMs > 0 ? math.min(dtMs / 16.7, 3.0) : 1.0;
    final double factor = (1.0 - math.pow(0.78, frames)).toDouble();
    // 限速：远距离（首次落位、粘贴）按约 22px/帧 匀速逼近，避免第一帧
    // 因为剩余距离大而直接“跳跃”。
    final double maxStep = 22.0 * frames;
    final double step = (remaining * factor).clamp(-maxStep, maxStep);
    _jumpCaretScrollTo(position, position.pixels + step);
  }

  /// 驱动器内部使用的 jumpTo：带标记，避免又被 [_onExternalCaretJump] 接管。
  void _jumpCaretScrollTo(ScrollPosition position, double target) {
    _tickerJumping = true;
    try {
      position.jumpTo(target);
    } finally {
      _tickerJumping = false;
    }
  }

  /// 接管「框架发起的瞬时跳转」。
  ///
  /// super_editor 在**每次文档变化**后都会调用
  /// `DragHandleAutoScroller.ensureOffsetIsVisible`，用 `jumpTo` 把光标
  /// 一瞬间抬到视口边界（默认距底部 54）——这正是输入/退格时「一跳一跳」
  /// 的根源：它绕过逐帧平滑滚动，一帧就跳到位。
  /// 这里把它改写成「更新滚动目标」，光标所在行才会连续平滑移动。
  ///
  /// 返回 true 表示已接管，真正的 jumpTo 不再执行。
  bool _onExternalCaretJump(double target, ScrollPosition position) {
    if (_disposed || _tickerJumping) {
      return false;
    }
    // 面板/键盘交替期间用户明确要求不要滚动：直接吞掉。
    // 键盘还在升降时（_caretFollowing 等视口停稳）同样吞掉，否则会和
    // 键盘动画叠加成「先滑一下、停稳后再补一下」。键盘收起后的短暂窗口
    // （_imeCollapsing）也吞掉：框架按变大后的视口重算出的目标更小，
    // 执行它会让正文往下移（用户反馈的「收起输入法后详情页下移」）。
    if (_panelTransitioning || _caretFollowing || _imeCollapsing) {
      return true;
    }
    // 浏览态保持框架原生行为（例如拖动手势的自动滚动）。
    if (!_editing.value) {
      return false;
    }
    if ((target - position.pixels).abs() < 1) {
      return true;
    }
    _requestCaretScroll(target);
    return true;
  }

  /// 打开底部系统弹层（链接输入 / 选图 / 选文件）的一瞬间冻结当前选区。
  ///
  /// 必须在 showXiaojiSheet 之前调用：modal 一打开焦点就转移，composer
  /// 选区随后会被折叠，再读就只剩末尾一个光标。
  void _onPanelOpening() {
    _panelOpen = true;
    _lastSelection = _composer.selection;
  }

  /// 工具条子菜单开关（受控模式，严格对齐语雀）。
  ///
  /// 点 Aa / 插入 / 加号：先收起输入法，面板在工具条**下方**（原键盘
  /// 区域）展开；工具条本身位置不动。再点「×」收起，键盘原位回来。
  void _togglePanel(MarkdownToolbarPanel next) {
    if (next == _panel) {
      return;
    }
    if (next == MarkdownToolbarPanel.none) {
      _closePanel(showKeyboard: true);
      return;
    }
    if (_panelExpanded) {
      // 已经是「面板占位」的稳定态（键盘早已收起）：直接换面板。
      setState(() => _panel = next);
      return;
    }
    final double ime = MediaQuery.viewInsetsOf(context).bottom;
    if (ime <= 0) {
      // 键盘不在（浏览态 / 已收起）：没有「原键盘区域」可铺面板。
      return;
    }
    // 隐藏输入法会让系统短暂回收 IME 焦点：先冻结选区快照，面板里的
    // 样式命令才能作用在用户原本的光标/选区上。
    _lastSelection = _composer.selection;
    _cancelCaretFollow();
    _anchorReleaseTimer?.cancel();
    setState(() {
      _panel = next;
      _toolbarAnchorIme = ime;
      _panelClosing = false;
      _panelOpeningUntilHidden = true;
    });
    // 只隐藏键盘、不失焦：IME 连接和选区都保留，命令直接生效。
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  /// 关闭子菜单；[showKeyboard] 为 true 时把键盘原位弹回来。
  ///
  /// 两种场景：
  ///  - 点「×」/ 选了插入项：键盘回到原位继续输入（工具条锚点不变）；
  ///  - 键盘被重新调起、或离开编辑态：只关面板，不再拉起键盘。
  void _closePanel({required bool showKeyboard}) {
    if (!_panelExpanded) {
      return;
    }
    _cancelCaretFollow();
    setState(() {
      _panel = MarkdownToolbarPanel.none;
      _panelOpeningUntilHidden = false;
      // 锚点保留到键盘真正回来（_reconcilePanelWithKeyboard 里清理），
      // 否则工具条会先掉到屏幕底部再被顶上来。
      _panelClosing = showKeyboard;
    });
    // 兜底释放：系统键盘高度可能和展开前不同（候选栏/输入法切换），
    // 到不了锚点高度时锚点会一直留着，正文底部就会多出一片空白
    // （用户反馈「反复调起几次后偶现底部空白」）。超时后无条件释放。
    _scheduleAnchorRelease();
    if (showKeyboard) {
      // 键盘高度与展开前一致，工具条位置不会跳动。
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    }
  }

  /// 面板里点的样式命令：焦点/选区都还在，直接执行。
  ///
  /// 不能走 [_runToolbarCommand]：它会 requestFocus 把键盘拉起来，
  /// 面板会被顶掉。链接是例外（要弹输入层），先收面板、回键盘。
  void _runPanelCommand(MarkdownCommand command) {
    if (command == MarkdownCommand.link) {
      _closePanel(showKeyboard: true);
      _showLinkSheet();
      return;
    }
    // 没选中文字时，行内样式作用于「接下来输入的文字」（内核的输入态，
    // 与 Word / Notion / 语雀同语义）。按钮点亮即反馈，不弹任何提示：
    // 主流编辑器都不会为输入态弹 SnackBar（旧实现的长提示会盖住键盘）。
    // 记录当前块，光标跨块移动时清空输入态。
    final DocumentSelection? selection = _composer.selection;
    if (_isInlineStyleCommand(command) &&
        selection != null &&
        selection.isCollapsed) {
      _typingStyleNodeId = selection.extent.nodeId;
    }
    _commands.handleCommand(command);
    _refreshActiveCommands();
    // 块级 / 插入类命令是一次性结构动作：执行后立刻收面板、回键盘，
    // 用户可以马上继续输入（不用再点一次 Aa，符合「点一下就走」的直觉）。
    // 文字样式保持展开，方便连续加粗 + 斜体。
    if (_isOneShotPanelCommand(command)) {
      _closePanel(showKeyboard: true);
    }
  }

  /// 是否属于「行内样式」（可以作用于输入态而不只是选区）。
  bool _isInlineStyleCommand(MarkdownCommand command) {
    return switch (command) {
      MarkdownCommand.bold ||
      MarkdownCommand.italic ||
      MarkdownCommand.strike ||
      MarkdownCommand.code ||
      MarkdownCommand.highlight =>
        true,
      _ => false,
    };
  }

  /// Aa 面板里「点一下就收起」的命令（结构/插入类）。
  bool _isOneShotPanelCommand(MarkdownCommand command) {
    return switch (command) {
      MarkdownCommand.bold ||
      MarkdownCommand.italic ||
      MarkdownCommand.strike ||
      MarkdownCommand.code ||
      MarkdownCommand.highlight ||
      MarkdownCommand.link =>
        false,
      _ => true,
    };
  }

  /// 面板/键盘交替的状态机（在 build 里按当前 ime 结算）。
  ///
  ///  - 面板展开期间键盘被重新调起（用户点了正文、系统回收后恢复）：
  ///    面板让位，锚点一并释放；
  ///  - 面板已收起、键盘回到原高度：锚点释放，工具条自然回到
  ///    `bottom: 0`（此时 body 已按键盘缩短，屏幕 Y 相同，不会跳）；
  ///  - 离开编辑态：锚点直接释放。
  void _reconcilePanelWithKeyboard(double imeInset) {
    if (_toolbarAnchorIme == null) {
      return;
    }
    if (!_editing.value) {
      _toolbarAnchorIme = null;
      _panelClosing = false;
      return;
    }
    if (_panelExpanded) {
      if (_panelOpeningUntilHidden) {
        if (imeInset <= 0) {
          _panelOpeningUntilHidden = false;
        }
        return;
      }
      if (imeInset > 0) {
        // 键盘回来了：面板必须让位，否则会盖住键盘。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _panelExpanded) {
            setState(() {
              _panel = MarkdownToolbarPanel.none;
              _toolbarAnchorIme = null;
              _panelClosing = false;
            });
          }
        });
      }
      return;
    }
    if (_panelClosing) {
      final double anchor = _toolbarAnchorIme!;
      if (imeInset >= anchor - 1) {
        // 键盘已回到展开前的高度：释放锚点，几何与 `bottom: 0` 等价。
        _toolbarAnchorIme = null;
        _panelClosing = false;
        _cancelCaretFollow();
      }
      return;
    }
    // 面板已收起、也不在等键盘（例如「附件 → 系统选择器」返回）：
    // 键盘一旦可见，锚点必须释放，否则正文底部会一直多留一片空白。
    if (imeInset > 0) {
      _toolbarAnchorIme = null;
      _panelOpeningUntilHidden = false;
      _stopCaretScroll();
    }
  }

  /// 锚点释放兜底：超时后无论键盘回到什么高度都解除。
  ///
  /// 反复调起面板/键盘时，系统键盘高度可能变化（候选栏、输入法切换），
  /// 锚点靠 `ime >= 锚点` 永远等不到，正文底部会残留一片空白。
  void _scheduleAnchorRelease() {
    _anchorReleaseTimer?.cancel();
    _anchorReleaseTimer = Timer(const Duration(milliseconds: 400), () {
      if (_disposed || !mounted || _toolbarAnchorIme == null) {
        return;
      }
      if (_panelExpanded) {
        return;
      }
      setState(() {
        _toolbarAnchorIme = null;
        _panelClosing = false;
        _panelOpeningUntilHidden = false;
      });
      _stopCaretScroll();
    });
  }

  /// 工具条相对 body 底部的偏移。
  ///
  /// 正常情况下贴住 body 底部（贴键盘上沿）；面板/键盘交替期间用锚点
  /// 保持屏幕 Y 不变：`锚点 - 当前 ime`。
  double _toolbarBottomOffset(double imeInset) {
    final double? anchor = _toolbarAnchorIme;
    if (anchor == null) {
      return 0;
    }
    return math.max(anchor - imeInset, 0);
  }

  /// 同步撤销/重做可用态。super_editor 的历史在 Editor 内部，getter
  /// 返回的是副本，所以每次编辑后按长度刷新，不直接依赖可变对象。
  void _syncHistoryButtons() {
    final canUndo = _editor.history.isNotEmpty;
    final canRedo = _editor.future.isNotEmpty;
    if (_canUndo.value != canUndo) {
      _canUndo.value = canUndo;
    }
    if (_canRedo.value != canRedo) {
      _canRedo.value = canRedo;
    }
  }

  /// 恢复编辑态选区。底部面板（Aa / 插入）打开时编辑器会失焦、
  /// composer 选区被清空；面板关闭后先恢复快照选区，命令才能作用到
  /// 用户打开面板前的光标位置，而不是静默 no-op。
  void _restoreEditingSelection() {
    if (_disposed) {
      return;
    }
    final wasPanelOpen = _panelOpen;
    _panelOpen = false;
    final selection = _lastSelection;
    // 面板打开过就必须用冻结快照覆盖当前选区：modal 会把展开选区折叠成
    // 末尾一个光标，这个「非空但已变短」的选区不能直接拿来执行命令。
    if (selection != null && (wasPanelOpen || _composer.selection == null)) {
      _editor.execute(<EditRequest>[
        ChangeSelectionRequest(
          selection,
          SelectionChangeType.expandSelection,
          SelectionReason.userInteraction,
        ),
      ]);
    }
    // 焦点交还编辑器，键盘/光标一起回来（modal 关闭后 FocusScope 不一定
    // 会把焦点还给原节点）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) {
        _editorFocus.requestFocus();
      }
    });
  }

  /// 工具条命令的统一入口：先保证有可作用的选区，再执行内核命令。
  void _runToolbarCommand(MarkdownCommand command) {
    _restoreEditingSelection();
    if (command == MarkdownCommand.link) {
      _showLinkSheet();
      return;
    }
    _commands.handleCommand(command);
    _refreshActiveCommands();
  }

  /// 插入链接：走真正的输入弹层，确认后插入带 LinkAttribution 的文本。
  Future<void> _showLinkSheet() async {
    final String initialLabel = _selectedPlainText();
    _onPanelOpening();
    final result = await showLinkEditorSheet(
      context: context,
      initialLabel: initialLabel.isEmpty ? '文字' : initialLabel,
    );
    _restoreEditingSelection();
    if (result == null || !mounted) {
      return;
    }
    _commands.insertAttachment(result.label, result.url);
  }

  /// 当前单节点选区的纯文本（用于链接弹层回填）。
  String _selectedPlainText() {
    final selection = _composer.selection;
    if (selection == null || selection.base.nodeId != selection.extent.nodeId) {
      return '';
    }
    final node = _document.getNodeById(selection.extent.nodeId);
    if (node is! TextNode) {
      return '';
    }
    final base = (selection.base.nodePosition as TextNodePosition).offset;
    final extent = (selection.extent.nodePosition as TextNodePosition).offset;
    final lo = base < extent ? base : extent;
    final hi = base < extent ? extent : base;
    return node.text.toPlainText().substring(lo, hi);
  }

  /// 收起键盘回到浏览态。
  ///
  /// 两步缺一不可：收掉 IME；选区置空让 SuperEditor 不再因「有选区 +
  /// 有焦点」把键盘重新拉起（实测只收 IME 会被焦点策略顶回来）。
  /// 不用 FocusManager.unfocus：SuperEditor 内部焦点节点由内核自管，
  /// 外部抢着 unfocus 会让下一次点击进编辑变迟钝。
  /// 另外 `TextInput.hide()` 在当前 Flutter 版本已不可直接调用，
  /// 走 SystemChannels 等价收起。
  // ---------------------------------------------------------------------------
  // 右上角「⋯」笔记操作菜单（早期版本同款：置顶/复制文本/编辑标签/删除）
  // ---------------------------------------------------------------------------

  Future<void> _showEditorMenu() async {
    // 与主页长按共用同一个动作菜单组件：标题、行高、图标、分隔线、
    // 取消按钮全部走 HarmonyOS 规范，不再各页面手写一套。
    final String? action = await showXiaojiActionSheet<String>(
      context: context,
      title: '',
      actions: <SheetAction<String>>[
        SheetAction<String>(
          value: 'pin',
          label: _currentNote.pinned ? '取消置顶' : '置顶',
          icon: Icons.push_pin_outlined,
          selected: _currentNote.pinned,
        ),
        const SheetAction<String>(
          value: 'copy',
          label: '复制文本',
          icon: Icons.content_copy_outlined,
        ),
        const SheetAction<String>(
          value: 'shareImage',
          label: '分享为图片',
          icon: Icons.share_outlined,
        ),
        const SheetAction<String>(
          value: 'tags',
          label: '编辑标签',
          icon: Icons.sell_outlined,
        ),
        const SheetAction<String>(
          value: 'history',
          label: '历史版本',
          icon: Icons.history_rounded,
        ),
        SheetAction<String>(
          value: 'lock',
          label: _currentNote.locked ? '取消锁定' : '锁定笔记',
          icon: _currentNote.locked
              ? Icons.lock_open_outlined
              : Icons.lock_outline_rounded,
        ),
        const SheetAction<String>(
          value: 'delete',
          label: '删除',
          icon: Icons.delete_outline_rounded,
          destructive: true,
        ),
      ],
    );
    if (action == null || !mounted) {
      return;
    }
    switch (action) {
      case 'pin':
        await _togglePin();
        break;
      case 'copy':
        await _copyBody();
        break;
      case 'shareImage':
        await _shareAsImage();
        break;
      case 'tags':
        await _editTags();
        break;
      case 'history':
        await _showVersionHistory();
        break;
      case 'lock':
        await _toggleLock();
        break;
      case 'delete':
        await _confirmDelete();
        break;
    }
  }

  Future<void> _togglePin() async {
    _currentNote = await widget.repository.togglePin(_currentNote);
    if (mounted) {
      setState(() {});
    }
  }

  // ---------------------------------------------------------------------------
  // 历史版本
  // ---------------------------------------------------------------------------

  Future<void> _showVersionHistory() async {
    final NoteStore store = widget.repository.store;
    final List<NoteVersion> versions =
        await store.listVersions(_currentNote.id);
    if (!mounted) {
      return;
    }
    if (versions.isEmpty) {
      _showHint('还没有历史版本');
      return;
    }
    final NoteVersion? picked = await showModalBottomSheet<NoteVersion>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _VersionHistorySheet(
        versions: versions,
        locked: _currentNote.locked,
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    final String raw = await store.readVersion(picked);
    final Note? preview = Note.decode(raw, fallbackId: _currentNote.id);
    if (!mounted) {
      return;
    }
    final bool? confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _VersionPreviewSheet(
        note: preview,
        time: picked.time,
        locked: _currentNote.locked,
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final Note? restored = await store.restoreVersion(_currentNote, picked);
    if (restored == null || !mounted) {
      _showHint('这个版本无法恢复');
      return;
    }
    await widget.repository.upsert(restored);
    if (!mounted) {
      return;
    }
    // 整页重建：文档/选区/撤销栈全部按恢复后的内容重新初始化。
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => NewEditorPage(
          repository: widget.repository,
          note: restored,
          autoFocus: false,
        ),
      ),
    );
  }

  /// 单篇锁定：开启后正文以密文落盘，每次打开都要先验证身份。
  ///
  /// 只加密正文（图片/附件保持原样），与设置页的说明一致。
  Future<void> _toggleLock() async {
    if (_currentNote.locked) {
      final bool ok = await verifyIdentity(
        context,
        settings: widget.repository.settings,
        reason: '取消锁定这条笔记',
      );
      if (!ok || !mounted) {
        return;
      }
      await _applyLock(false);
      if (mounted) {
        _showHint('已取消锁定');
      }
      return;
    }
    final bool? confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '锁定这条笔记？',
      message: '锁定后正文加密保存，每次打开都要验证身份。'
          '图片和附件不加密。',
      confirmLabel: '锁定',
    );
    if (confirmed != true || !mounted) {
      return;
    }
    // 设备没有安全锁屏、也没设过 PIN 时，先设一个 —— 否则锁定笔记
    // 打开时无从验证，锁定就只剩「磁盘加密」一层，防不住旁人翻看。
    if (!await _ensureVerificationAvailable()) {
      return;
    }
    await _applyLock(true);
    if (mounted) {
      _showHint('已锁定，正文已加密保存');
    }
  }

  /// 确保至少有一种可用的身份验证方式（系统凭证或应用 PIN）。
  Future<bool> _ensureVerificationAvailable() async {
    try {
      final settings = widget.repository.settings;
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
      final salt = await kSecurity.randomSalt();
      final hash = await kSecurity.hashPin(pin: pin, salt: salt);
      await widget.repository.updateSettings(
        settings.copyWith(pinHash: hash, pinSalt: salt),
      );
      return true;
    } catch (error) {
      if (mounted) {
        _showHint('无法启用锁定：$error');
      }
      return false;
    }
  }

  /// 切换锁定状态并立即落盘（不等 800ms 防抖）。
  ///
  /// 先 [_flushSave] 把当前编辑内容写回 [_currentNote]，再改 locked 落盘：
  /// 否则刚锁定就退出，最后一段输入会被当成「锁定前的正文」重复加密。
  Future<void> _applyLock(bool locked) async {
    _saveDebounce?.cancel();
    // 必须等这一笔写完再写锁定态：两笔保存同时落在同一条路径上，
    // 后写的那笔可能把「已加密」覆盖回明文（或反之）。
    await _flushSave();
    if (_discarded) {
      return;
    }
    _currentNote = _currentNote.copyWith(
      locked: locked,
      updated: DateTime.now(),
    );
    await widget.repository.upsert(_currentNote);
    if (mounted) {
      setState(() {});
    }
    _applySecureScreen();
  }

  /// 锁定笔记打开期间开启 FLAG_SECURE，退出/取消锁定时恢复。
  void _applySecureScreen() {
    final bool should =
        _currentNote.locked && widget.repository.settings.secureScreen;
    if (should == _secureScreenApplied) {
      return;
    }
    _secureScreenApplied = should;
    // 失败不影响锁定本身（个别 ROM 可能不支持）。
    kSecurity.setSecureHolder(_secureKey, should).catchError((Object _) {});
  }

  Future<void> _copyBody() async {
    await Clipboard.setData(
      ClipboardData(text: serializeDocumentToXiaojiMarkdown(_document)),
    );
    if (mounted) {
      showSnack(context, message: '已复制到剪贴板');
    }
  }

  /// 把当前详情渲染成整篇长图并调起系统分享。
  ///
  /// 直接取详情页文档布局的渲染对象（`_documentLayoutKey`），所以分享图与
  /// 详情是同一份排版：列宽、换行、表格、代码块、图片全部一致，而不是另外
  /// 用 Markdown 再渲染一遍（那样宽度不同会导致每行字数不一致、表格丢失）。
  Future<void> _shareAsImage() async {
    if (_documentEmpty.value) {
      _showHint('空白笔记没有可分享的内容');
      return;
    }
    final AppColors colors = AppColors.of(context);
    // 分享图里不应出现光标/选区高亮：先失焦并清空选区，再等这一帧画完。
    FocusManager.instance.primaryFocus?.unfocus();
    _composer.clearSelection();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      return;
    }
    final RenderObject? layout =
        _documentLayoutKey.currentContext?.findRenderObject();
    if (layout == null) {
      _showHint('分享失败：内容还没准备好');
      return;
    }
    try {
      await shareNoteAsImage(
        documentLayout: layout,
        background: colors.page,
      );
    } catch (error) {
      if (mounted) {
        _showHint('分享失败：$error');
      }
    }
  }

  /// 编辑标签：输入框 + 已有标签候选 chips（旧版同款）。
  Future<void> _editTags() async {
    final result = await showTagEditorSheet(
      context: context,
      initialText: _currentNote.tags.join(', '),
      candidates: widget.repository.tags,
    );
    if (result == null || !mounted) {
      return;
    }
    _currentNote = Note(
      id: _currentNote.id,
      created: _currentNote.created,
      updated: _currentNote.updated,
      tags: Note.parseTags(result),
      pinned: _currentNote.pinned,
      locked: _currentNote.locked,
      body: _currentNote.body,
    );
    await widget.repository.upsert(_currentNote);
    // 左下角标签栏读的是 _currentNote，弹层关闭后要立刻反映新的标签。
    if (mounted) {
      setState(() {});
    }
  }

  void _onEditorFocusChanged() {
    if (_editorFocus.hasFocus) {
      _refreshClipboardSnapshot();
    }
  }

  /// 缓存剪贴板内容（纯文本 + HTML），供 IME 粘贴识别使用。
  ///
  /// Android 10+ 只有持有窗口焦点的应用才能读剪贴板：`resumed` 回调触发时
  /// 焦点往往还没回来，第一次读会拿到空字符串。空了就短延迟重试，
  /// 否则快照一直是空的，键盘粘贴永远识别不了。
  Future<void> _refreshClipboardSnapshot({int attempt = 0}) async {
    try {
      final ClipboardContent content = await const ClipboardReader().read();
      if (!mounted) {
        return;
      }
      if (content.text.isEmpty && attempt < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted) {
          return;
        }
        await _refreshClipboardSnapshot(attempt: attempt + 1);
        return;
      }
      _clipboardText = content.text;
      _clipboardHtml = content.html;
    } catch (error) {
      debugPrint('读取剪贴板快照失败: $error');
    }
  }

  /// 一次 IME 插入是否等价于「粘贴当前剪贴板」。
  ///
  /// 判定逻辑在 [shouldTreatImeInsertAsPaste]（可单测）：除了和快照对得上，
  /// 快照过期但插入文本本身结构明确时也拦截 —— 否则只能退出重进才解析。
  bool _shouldInterceptImePaste(String inserted) {
    if (_handlingImePaste) {
      return false;
    }
    return shouldTreatImeInsertAsPaste(
      inserted,
      clipboardText: _clipboardText,
      clipboardHtml: _clipboardHtml,
    );
  }

  /// 键盘粘贴：必须同步完成。
  ///
  /// 输入法上报「插入 = 剪贴板内容」后，如果这里只 return、稍后再异步改文档，
  /// 系统输入法会继续按「已粘贴」的文本上报位置，与文档结构错位
  /// （实测抛 `No such document position in the IME content`）。
  /// 所以直接拿页面缓存的剪贴板快照同步解析；解析不了返回 false，
  /// 交回输入法默认粘贴。
  bool _handleImePaste(String inserted) {
    if (_handlingImePaste) {
      return false;
    }
    _handlingImePaste = true;
    try {
      final String? snapshot = _clipboardText;
      // 只有快照确实对应这次插入时才用它的 HTML，否则 HTML 属于上一次
      // 复制的内容，会把无关排版套进来。
      final bool fromSnapshot = snapshot != null &&
          snapshot.trim().isNotEmpty &&
          clipboardTextsMatch(inserted.trim(), snapshot.trim());
      final ClipboardContent content = fromSnapshot
          ? ClipboardContent(text: snapshot, html: _clipboardHtml)
          : ClipboardContent(text: inserted);
      final bool handled = MarkdownPaster(
        editor: _editor,
        document: _document,
        composer: _composer,
        ops: _ops,
      ).pasteContent(content);
      if (handled) {
        _notifyMarkdownPaste();
      }
      return handled;
    } catch (error, stack) {
      debugPrint('键盘粘贴解析失败，交给输入法: $error\n$stack');
      return false;
    } finally {
      _handlingImePaste = false;
    }
  }

  /// 解析成功后的即时反馈（语雀式提示）。
  ///
  /// 用户看不到文档结构被「重建」的过程，需要一句话告诉他这次粘贴被
  /// 识别成了 Markdown；否则会把「自动排版」当成内容丢失。
  void _notifyMarkdownPaste() {
    final DateTime now = DateTime.now();
    if (_lastMarkdownPasteHint != null &&
        now.difference(_lastMarkdownPasteHint!) <
            const Duration(milliseconds: 800)) {
      return;
    }
    _lastMarkdownPasteHint = now;
    // 粘贴回调发生在输入法消息里，等这一帧布局结束再弹，避免与文档
    // 重建撞在同一帧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed) {
        return;
      }
      _showHint('已识别为 Markdown');
    });
  }

  DateTime? _lastMarkdownPasteHint;

  /// 长按菜单「粘贴」：优先按 Markdown / HTML 解析成块，失败退回默认粘贴。
  Future<bool> _pasteFromClipboard() async {
    try {
      final bool handled = await MarkdownPaster(
        editor: _editor,
        document: _document,
        composer: _composer,
        ops: _ops,
      ).paste();
      if (handled) {
        _notifyMarkdownPaste();
      } else {
        _ops.paste();
      }
      return handled;
    } catch (error, stack) {
      debugPrint('智能粘贴异常，回退默认粘贴: $error\n$stack');
      _ops.paste();
      return false;
    }
  }

  /// 工具栏「标签」入口：弹层关闭后把焦点和键盘交还编辑器，
  /// 不让用户点完标签还得再点一次正文。
  Future<void> _editTagsFromToolbar() async {
    await _editTags();
    if (!mounted || _disposed) {
      return;
    }
    _restoreEditingSelection();
  }

  // ---------------------------------------------------------------------------
  // 图片长按菜单
  // ---------------------------------------------------------------------------

  /// 长按图片：小图/大图显示、下载、删除。
  Future<void> _showImageActions(
    BuildContext componentContext,
    String nodeId,
    String absolutePath,
    ImageDisplaySize current,
  ) async {
    final DocumentNode? node = _document.getNodeById(nodeId);
    if (node is! ImageNode) {
      return;
    }
    // 菜单期间不保留光标/键盘：和点开大图一致，回到干净的浏览态。
    _editor.execute(<EditRequest>[const ClearSelectionRequest()]);
    final _ImageAction? action = await showXiaojiActionSheet<_ImageAction>(
      context: componentContext,
      title: '图片',
      actions: <SheetAction<_ImageAction>>[
        SheetAction(
          value: _ImageAction.small,
          label: '小图显示',
          icon: Icons.photo_size_select_small_outlined,
          selected: current == ImageDisplaySize.small,
        ),
        SheetAction(
          value: _ImageAction.large,
          label: '大图显示',
          icon: Icons.fullscreen_rounded,
          selected: current == ImageDisplaySize.large,
        ),
        const SheetAction(
          value: _ImageAction.download,
          label: '下载',
          icon: Icons.download_outlined,
        ),
        const SheetAction(
          value: _ImageAction.delete,
          label: '删除',
          icon: Icons.delete_outline_rounded,
          destructive: true,
        ),
      ],
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case _ImageAction.small:
        _setImageSize(node, ImageDisplaySize.small);
      case _ImageAction.large:
        _setImageSize(node, ImageDisplaySize.large);
      case _ImageAction.download:
        await _downloadImage(absolutePath);
      case _ImageAction.delete:
        await _deleteImage(node);
    }
  }

  /// 切换正文显示尺寸（写入笔记，重开仍然生效）。
  void _setImageSize(ImageNode node, ImageDisplaySize size) {
    final String nextUrl = imageUrlWithSize(node.imageUrl, size);
    if (nextUrl == node.imageUrl) {
      return;
    }
    _editor.execute(<EditRequest>[
      ReplaceNodeRequest(
        existingNodeId: node.id,
        newNode: ImageNode(
          id: node.id,
          imageUrl: nextUrl,
          altText: node.altText,
        ),
      ),
    ]);
  }

  /// 下载到系统相册（Android 10+ 进相册，旧系统进应用目录）。
  Future<void> _downloadImage(String absolutePath) async {
    try {
      final bool savedToGallery = await saveImageToGallery(absolutePath);
      if (!mounted) {
        return;
      }
      _showHint(savedToGallery ? '已保存到相册' : '已保存到应用目录');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showHint('保存失败：$error');
    }
  }

  Future<void> _deleteImage(ImageNode node) async {
    final bool? confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '删除图片',
      message: '删除后正文里将不再显示这张图片。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    _editor.execute(<EditRequest>[DeleteNodeRequest(nodeId: node.id)]);
  }

  void _showHint(String message) {
    showSnack(context, message: message);
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '删除这条小记？',
      message: '正文和附件会一起移到「回收站」，到期后自动清理。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    // 先停掉防抖，再删；删除成功后标记 _discarded，dispose 就不会把
    // 刚删掉的正文写回去（否则笔记会「删了又回来」）。
    _saveDebounce?.cancel();
    await widget.repository.remove(_currentNote);
    _discarded = true;
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _hideKeyboard() {
    // 子菜单必须先收起：工具栏马上要滑走，挂着面板会看起来像没收干净。
    _closePanel(showKeyboard: false);
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    _composer.clearSelection();
  }

  /// 附件面板选中动作：直接进相机/相册/文件选择器。
  ///
  /// 面板本身由工具条就地展开（与 Aa/插入同一套交互），不再弹底部菜单
  /// ——弹层会抢走焦点、把你正在编辑的键盘收起来（用户反馈）。
  Future<void> _handleAttachAction(MarkdownAttachAction action) async {
    switch (action) {
      case MarkdownAttachAction.camera:
        await _pickImage(ImageSource.camera);
        break;
      case MarkdownAttachAction.gallery:
        await _pickImage(ImageSource.gallery);
        break;
      case MarkdownAttachAction.file:
        await _pickFile();
        break;
    }
  }

  /// 选图（拍照/相册）→ 拷进附件目录 → 插入图片块。
  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? file = await _imagePicker.pickImage(
        source: source,
        imageQuality: 92,
      );
      if (file == null) {
        _restoreEditingSelection();
        return;
      }
      final relative = await widget.repository.store.importAttachment(
        noteId: widget.note.id,
        sourcePath: file.path,
      );
      if (!mounted) {
        return;
      }
      // 选择器/相机可能把焦点和选区抢走：插入前把快照选区还回来，
      // 图片才会落在用户原本的光标处。
      _restoreEditingSelection();
      // 新插入的图片默认用小图：正文里先给一个不打断阅读的缩略，
      // 需要看细节时再通过图片菜单切「大图」（对齐主流笔记 App）。
      _commands.insertImageNode(
        imageUrlWithSize(relative, ImageDisplaySize.small),
      );
    } catch (error) {
      // 图片插入失败不能崩编辑页：提示后照常继续编辑。
      _restoreEditingSelection();
      if (!mounted) {
        return;
      }
      showSnack(context, message: '插入图片失败：$error');
    }
  }

  /// 文件附件：拷进附件目录 → 插入 `[文件名](相对路径)` 链接行。
  ///
  /// md 方言里文件附件与链接同语法（旧渲染器按整行解析成附件块，
  /// 新内核解析成带链接样式的文本行），双向兼容、序列化无损。
  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      final picked = result?.files.single;
      final path = picked?.path;
      if (picked == null || path == null || !mounted) {
        _restoreEditingSelection();
        return;
      }
      final relative = await widget.repository.store.importAttachment(
        noteId: widget.note.id,
        sourcePath: path,
      );
      if (!mounted) {
        return;
      }
      // 不能直接插字面量 `[名](路径)`：新内核里那只是一段文本，不会变成
      // 可点的链接，也不会被 AttachmentComponent 识别。插带 LinkAttribution
      // 的文本，显示/落盘才是完整的附件。
      _restoreEditingSelection();
      _commands.insertAttachment(picked.name, relative);
    } catch (error) {
      _restoreEditingSelection();
      if (!mounted) {
        return;
      }
      showSnack(context, message: '插入附件失败：$error');
    }
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // 输入法高度必须从 Scaffold 之外读。
    //
    // resizeToAvoidBottomInset: true 时，Scaffold 会给 body 的 MediaQuery
    // 做 removeBottomInset —— body 子树里 `viewInsets.bottom` 恒为 0，
    // body 之所以缩短是布局给的约束，不是 inset。在 body 内判断
    // 「键盘是否可见」永远为假，工具栏会彻底不显示（实测）。
    final double imeInset = MediaQuery.viewInsetsOf(context).bottom;
    _imeInset = imeInset;
    // 每帧按最新 viewInsets 结算键盘升降（didChangeMetrics 的时机不可靠）。
    _syncImeState(imeInset);
    // 面板/键盘交替时按当前 ime 结算锚点（工具条保持同一屏幕 Y）。
    _reconcilePanelWithKeyboard(imeInset);
    return Scaffold(
      backgroundColor: colors.page,
      // 键盘避让根修的延续：视口真正缩短，编辑器视口贴键盘上沿。
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: <Widget>[
            Column(
              children: <Widget>[
                _buildHeader(colors),
                Container(height: 0.5, color: colors.dividerStrong),
                Expanded(
                  // 工具条是浮层，会盖住正文底部。工具条可见时给视口
                  // 让出它的高度（含安全区），键盘弹出时正文就停在工具条
                  // 上方，不再出现「最后几行被工具栏/键盘压住」。
                  //
                  // 子菜单展开时键盘收起、body 变高：这里把「键盘原本占的
                  // 高度」补回来（锚点 - 当前 ime），正文视口高度全程不变。
                  // 否则视口突然变高会让滚动位置被 clamp，光标跟着往下掉
                  // （用户反馈）。预留量每帧精确计算，所以不用动画。
                  child: AnimatedBuilder(
                    animation: _editing,
                    builder: (
                      BuildContext context,
                      Widget? child,
                    ) {
                      final double panelReserve = _toolbarAnchorIme == null
                          ? 0
                          : math.max(_toolbarAnchorIme! - imeInset, 0);
                      // 预留必须在「工具栏真的会盖住正文」时才有意义：
                      //  - 键盘可见（工具条贴键盘上沿）；
                      //  - 面板/键盘交替（工具条被锚点钉住）；
                      //  - 面板打开过的流程（链接弹层、选图/选文件，选区被
                      //    冻结，工具条位置要全程不变）。
                      // 不能只看 `_editing`：用输入法自带的收起键把键盘收起后，
                      // 选区还在、工具条已经滑走，多预留的一条就会变成页面
                      // 底部一片「工具栏白底」的遮挡（用户反馈）。
                      final bool reserve =
                          imeInset > 0 || _panelTransitioning || _panelOpen;
                      // 预留量在编辑态是**常量**（工具条高度 + 面板补偿），
                      // 不含 safe area、也不随键盘高度变化：
                      //  - 键盘升降时 body 与视口同步伸缩，不会产生额外空白；
                      //  - 面板展开/收起时「锚点 - ime」把键盘占的高度补回来，
                      //    视口高度全程不变 → 滚动位置不会被 clamp、内容不跳。
                      final double reserveHeight =
                          _toolbarHeight + panelReserve;
                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: reserve ? reserveHeight : 0,
                        ),
                        child: child,
                      );
                    },
                    child: Theme(
                      // checkbox 主色：内核的 Checkbox 走全局 CheckboxTheme，
                      // 没有样式键可配——在编辑器子树局部覆盖主题，主色统一
                      // 成 accent，不动全局 app_theme。
                      data: Theme.of(context).copyWith(
                        checkboxTheme: CheckboxThemeData(
                          fillColor: WidgetStateProperty.resolveWith(
                            (states) => states.contains(WidgetState.selected)
                                ? colors.accent
                                : null,
                          ),
                          side: BorderSide(color: colors.tertiary, width: 1.6),
                        ),
                      ),
                      child: LayoutBuilder(
                        builder: (
                          BuildContext context,
                          BoxConstraints constraints,
                        ) {
                          // 占位提示要和正文内容列对齐：SingleColumnLayout
                          // 在宽度超过 maxWidth(640) 时把内容整体居中，
                          // 提示语若仍按页边距摆放，宽屏上会比光标左出一截
                          // （用户反馈「提示语和光标没对齐」）。
                          const double contentMaxWidth = 640;
                          final bool centered =
                              constraints.maxWidth > contentMaxWidth;
                          final double gutter = centered
                              ? (constraints.maxWidth - contentMaxWidth) / 2 +
                                  AppSpace.page
                              : AppSpace.page;
                          return Stack(
                            children: <Widget>[
                              SuperEditorAndroidControlsScope(
                                controller: _androidControls,
                                child: _buildEditor(colors),
                              ),
                              // 空文档占位提示（新建小记时的 tip）。
                              // 不拦截点击：点它应该像点正文一样把光标放进来。
                              // top 12 与段落规则里的 `padding top: 12` 一致，
                              // 文字行盒与光标起点因此完全重合。
                              Positioned(
                                left: gutter,
                                top: 12,
                                right: gutter,
                                child: IgnorePointer(
                                  child: ValueListenableBuilder<bool>(
                                    valueListenable: _documentEmpty,
                                    builder: (
                                      BuildContext context,
                                      bool empty,
                                      _,
                                    ) {
                                      if (!empty) {
                                        return const SizedBox.shrink();
                                      }
                                      return Text(
                                        '开始记录…',
                                        style: TextStyle(
                                          fontSize: AppFontSize.summary,
                                          height: 1.7,
                                          letterSpacing: 0.3,
                                          leadingDistribution:
                                              TextLeadingDistribution.even,
                                          color: colors.tertiary,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                // 左下角标签栏：显示本条笔记的标签，点标签打开编辑弹层。
                _buildTagBar(colors, imeInset),
              ],
            ),
            // 子菜单：铺在工具条下方（原键盘区域），工具条位置不动。
            if (_panelExpanded) _buildPanelSheet(colors, imeInset),
            // 工具条浮层：贴键盘上沿；空白处 Listener 吞事件，防止穿透
            // 挪光标（旧版实测的坑）。
            _buildToolbar(imeInset),
          ],
        ),
      ),
    );
  }

  /// 子菜单面板：占据原键盘区域，内容垂直居中。
  ///
  /// 高度必须取「工具条底边到 body 底边」的距离（即锚点减去当前 ime），
  /// 而不是固定取锚点：
  ///
  /// 打开面板时键盘是逐帧收起的，body 也在逐帧变高。如果面板按锚点高度
  /// 直接铺满，在键盘还没完全收起的那些帧里，它的顶边会跑到工具条**上方**，
  /// 面板内容就会在工具栏上面闪一下（用户实测）。改成跟着工具条底边走，
  /// 面板永远从工具栏下沿开始展开；内容按最终高度（锚点）布局后再裁剪，
  /// 所以内容本身不随动画上下漂移。
  Widget _buildPanelSheet(AppColors colors, double imeInset) {
    final double full = _toolbarAnchorIme ?? 0;
    final double visible = math.max(full - imeInset, 0);
    if (full <= 0 || visible <= 0) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: visible,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: full,
          maxHeight: full,
          child: ColoredBox(
            // 与面板同色：面板只占键盘区域的一段，剩余的上下留白必须同色，
            // 才能读成「一块完整的键盘替代面板」而不是白带浮在灰底上。
            color: colors.page,
            // 面板内容垂直居中：＋ 面板只有一组、Aa 面板四行，顶在上沿会让
            // 下面留一大片空白（用户反馈「太空」）。居中后上下留白对称。
            child: Center(
              child: ValueListenableBuilder<Set<MarkdownCommand>>(
                valueListenable: _activeCommands,
                builder: (
                  BuildContext context,
                  Set<MarkdownCommand> active,
                  _,
                ) {
                  return switch (_panel) {
                    // 子菜单铺在工具条下方的键盘区域里，本身就是独立白面：
                    // 不再画顶部分隔线（否则工具栏和面板之间多出一道横线）。
                    MarkdownToolbarPanel.textStyle => MarkdownTextStylePanel(
                        active: active,
                        showTopDivider: false,
                        onPick: _runPanelCommand,
                      ),
                    MarkdownToolbarPanel.insert => MarkdownInsertPanel(
                        active: active,
                        showTopDivider: false,
                        onPick: (MarkdownCommand command) {
                          // 插入是一次性动作：收面板、回键盘，再执行。
                          _closePanel(showKeyboard: true);
                          _runToolbarCommand(command);
                        },
                      ),
                    MarkdownToolbarPanel.attach => MarkdownAttachPanel(
                        showTopDivider: false,
                        onPick: (MarkdownAttachAction action) {
                          // 选完收起面板，交给系统选择器（它会接管焦点）。
                          _closePanel(showKeyboard: false);
                          _onPanelOpening();
                          _handleAttachAction(action);
                        },
                      ),
                    MarkdownToolbarPanel.none => const SizedBox.shrink(),
                  };
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 附件卡片点击/长按：打开「复制路径 / 从正文移除」弹层。
  void _showAttachmentActions(
    BuildContext context,
    String nodeId,
    String name,
    String url,
  ) {
    showAttachmentActionsSheet(
      context: context,
      repository: widget.repository,
      editor: _editor,
      nodeId: nodeId,
      name: name,
      url: url,
    );
  }

  /// 左下角标签栏。
  ///
  /// 展示当前笔记的标签（与列表卡片同一个 [TagChip] 规格），点任意标签
  /// 打开「编辑标签」弹层（含候选标签）。没有标签时只留一个「+ 标签」
  /// 入口，保证随时能加。
  ///
  /// 编辑态且键盘弹起时整条隐藏：那时底部已经有工具条，再挂一条标签栏
  /// 会把正文挤掉，也和工具条抢位置。
  Widget _buildTagBar(AppColors colors, double imeInset) {
    return ValueListenableBuilder<bool>(
      valueListenable: _editing,
      builder: (BuildContext context, bool editing, _) {
        // 编辑态键盘弹起、或面板 ↔ 键盘交替时整条隐藏：底部已经有
        // 工具条/面板，再挂一条标签栏会把正文挤掉。交替期间也必须隐藏，
        // 否则正文视口会多出标签栏那一截，滚动位置被 clamp → 内容跟着动。
        if (_panelTransitioning || (editing && imeInset > 0)) {
          return const SizedBox.shrink();
        }
        final List<String> tags = _currentNote.tags;
        // 无标签时不占位，也不显示「+标签」：新增入口已移到工具栏的
        // 标签按钮（用户要求），左下角只负责展示已有标签，避免两个入口重复。
        if (tags.isEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpace.page,
            2,
            AppSpace.page,
            8 + MediaQuery.paddingOf(context).bottom,
          ),
          // 固定一行高：标签多了横向滚动，不再换行把正文顶上去。
          // （换行会让底部条越堆越高，标签多时正文被压得只剩半屏。）
          // width: infinity 必须给：Column 的 crossAxisAlignment 默认居中，
          // 内容宽度只按标签占位时，只有一个标签会被整条居中（用户反馈）。
          child: SizedBox(
            width: double.infinity,
            height: 22,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: <Widget>[
                  for (final tag in tags)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _editTags,
                        child: TagChip(label: tag),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(AppColors colors) {
    return SizedBox(
      height: AppSize.navBar,
      child: Stack(
        children: <Widget>[
          // 顶栏按早期版本逻辑：居中显示更新时间（编辑后实时刷新）。
          Center(
            child: Text(
              formatEditorTime(_updated),
              style: AppText.meta.copyWith(color: colors.secondary),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: AppBackButton(
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // 撤销 / 还原已移到下方工具条（用户要求工具栏统一承载
                // 高频动作），顶栏只留笔记级操作「⋯」。
                AppIconButton(
                  icon: Icons.more_horiz_rounded,
                  onTap: _showEditorMenu,
                  tooltip: '更多',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditor(AppColors colors) {
    return NotificationListener<ScrollNotification>(
      // 只用来区分「手指拖动」和「内核自动滚动」：dragDetails 只有真实
      // 拖动才会带上，ballistic / animateTo 都没有。
      onNotification: (ScrollNotification notification) {
        if (notification is ScrollStartNotification) {
          _userDraggingScroll = notification.dragDetails != null;
        } else if (notification is ScrollEndNotification) {
          _userDraggingScroll = false;
        }
        return false;
      },
      child: SuperEditor(
        editor: _editor,
        // 自己持有焦点节点：底部面板关闭后要把焦点/IME 交还编辑器。
        focusNode: _editorFocus,
        // 粘贴拦截：键盘粘贴与工具条粘贴走同一套 Markdown 解析。
        imeOverrides: _pasteImeDecorator,
        // 外部持有滚动控制器：光标被输入法/工具条挡住时要精确滚动（见
        // _ensureCaretVisible），内部自建的控制器拿不到位置。
        scrollController: _editorScroll,
        // 分享长图用的布局入口：直接取这份渲染结果，宽度/换行/表格与详情一致。
        documentLayoutKey: _documentLayoutKey,
        // 光标/选区/手柄全部走主色，不出现系统默认蓝以外的第二主色。
        selectionStyle: SelectionStyles(
          // super_text_layout 的选区按行绘制、上下各外扩 2px，相邻行矩形
          // 必然重叠；半透明色叠两层就会出现一条更深的蓝带（用户反馈）。
          // 预先与页面底色混成不透明色，画多少层都是同一个颜色。
          selectionColor: Color.alphaBlend(
            colors.accent.withValues(alpha: 0.25),
            colors.page,
          ),
        ),
        androidHandleColor: colors.accent,
        stylesheet: _buildStylesheet(colors),
        // 点链接直接跳系统浏览器。官方默认 handler 只在「交互模式」生效，
        // 常驻编辑的小记永远不满足条件，链接点了没反应（用户反馈）。
        contentTapDelegateFactories: <SuperEditorContentTapDelegateFactory>[
          (SuperEditorContext context) =>
              XiaojiLinkTapHandler(context.document),
        ],
        // 图层链：官方 Android 光标（宽度 0，只保留选择手柄/工具条锚点）
        // 之外，再挂一层自绘光标 —— 官方光标按整行行盒画，比字高 70%
        // 且 2dp 粗（用户反馈），自绘版按字号比例重画。
        documentOverlayBuilders: <SuperEditorLayerBuilder>[
          const SuperEditorIosToolbarFocalPointDocumentLayerBuilder(),
          const SuperEditorIosHandlesDocumentLayerBuilder(),
          const SuperEditorAndroidToolbarFocalPointDocumentLayerBuilder(),
          const SuperEditorAndroidHandlesDocumentLayerBuilder(caretWidth: 0),
          const DefaultCaretOverlayBuilder(),
          XiaojiCaretLayerBuilder(_composer),
        ],
        componentBuilders: <ComponentBuilder>[
          // 相对路径图片解析（assets/… → 真实文件），必须排在默认构建器
          // 之前才能接管 ImageNode；其余组件保持默认链（含 Task）。
          _LabImageComponentBuilder(
            repository: widget.repository,
            editor: _editor,
            onImageLongPress: _showImageActions,
          ),
          // 分隔线颜色接管：HorizontalRuleComponent 的线色写死 Colors.grey
          // （源码实测，HorizontalRuleComponentViewModel 不透出 color 键，
          // stylesheet 无法配），深色模式下灰线几乎不可见。这里排在默认
          // 构建器前面，用主题 divider 色重建同一个组件。
          const _LabHorizontalRuleComponentBuilder(),
          // 代码块：官方 ParagraphComponent 外面包一层不接手势的视觉外壳
          // （见 _LabCodeBlockComponentBuilder），光标/长按走内核原生路径。
          _LabCodeBlockComponentBuilder(editor: _editor),
          // 引用块：自建组件（官方实现点不进去且内边距写死 16/16）。
          _LabBlockquoteComponentBuilder(
            editor: _editor,
            focusNode: _editorFocus,
          ),
          // 任务勾选框对齐修复：官方 Checkbox 视觉盒 40px 导致框比文字
          // 低约 10px（真机用户反馈），换自绘 22px 勾选框与首行视觉居中。
          XiaojiTaskComponentBuilder(_editor),
          // 文件附件：整行只有 `[文件名](assets/…)` 的段落渲染成卡片，
          // 点击查看/复制路径，不再是一条点了没反应的下划线链接。
          AttachmentComponentBuilder(
            repository: widget.repository,
            editor: _editor,
            onShowActions: _showAttachmentActions,
          ),
          // 列表项缩进收紧：官方默认 37.2dp 的记号列宽，编号离行头太远。
          const _LabListItemComponentBuilder(),
          // 表格：列宽按「正文可用宽度 / 列数」分配，单列再做封顶，
          // 单元格内换行 —— 手机窄屏不再被长文本撑到几千 dp
          // （用户反馈「横向要滑很久」）。列特别多、单列窄于 96dp 时
          // 才保留横向滚动兜底。断点差异只体现在这里，结构不动。
          _AdaptiveTableComponentBuilder(
            availableWidth: MediaQuery.sizeOf(context).width - 36,
          ),
          ...defaultComponentBuilders,
          const UnknownComponentBuilder(),
        ],
      ),
    );
  }

  Stylesheet _buildStylesheet(AppColors colors) {
    // 文档级默认：15.5/1.7 主文字、左右 18 页边距；底部 96 是常量
    // （工具条 52 + 呼吸），不随键盘变化——旧版的坑。
    //
    // 手机端精读排版：汉字是全角方块，同一个 px 值比西文更「满」。
    // 对比语雀移动端后再往上收一档：15.5 / 1.7（行盒 26px）、字距 0.3、
    // 段距 12；标题 21/18.5/16.5、行高 1.3。比 15/1.6 更适合长文连续
    // 阅读，又比 16/1.75 更利落。leadingDistribution.even 让中文字形的
    // 上下留白对称（默认的 leading 会偏下），整页竖向节奏更稳。
    // 必须用 addRulesAfter：super_editor 的样式表按「先命中先生效、
    // 后命中的值覆盖前面」合并，addRulesBefore 会被 defaultStylesheet
    // 里 PC 端的默认值（正文 18、H1 38、段落/列表间距 24）盖掉 ——
    // 之前写在这一层里的手机端字阶其实从未生效，真机上看到的一直是
    // 桌面排版（用户反馈的「整体偏大、Typora 感」就是这个根因）。
    return defaultStylesheet.copyWith(
      // 行内样式必须挂在 Stylesheet 上，不能写进 StyleRule！
      // super_editor 的 SingleColumnStylesheetStyler 合并样式时，对
      // **非 TextStyle / 非 CascadingPadding** 的值只保留旧值（见
      // _mergeStyles：既不是 TextStyle 也不是 CascadingPadding 时什么都不做），
      // 而 aggregateStyles 一开始就塞了 stylesheet.inlineTextStyler。所以
      // 写在规则里的 Styles.inlineTextStyler 会被静默丢弃 —— 这正是
      // 「高亮 / 行内码在详情页完全没效果，列表摘要却正常」的根因。
      inlineTextStyler: (Set<Attribution> attributions, TextStyle baseStyle) =>
          xiaojiInlineTextStyler(
        attributions,
        baseStyle,
        textColor: colors.text,
        accentColor: colors.accent,
        mutedColor: colors.tertiary,
        codeBackground: colors.surface2,
        highlightBackground: colors.accentBg,
      ),
      addRulesAfter: <StyleRule>[
        StyleRule(
          BlockSelector.all,
          (Document doc, DocumentNode node) {
            return <String, dynamic>{
              Styles.textStyle: TextStyle(
                fontSize: AppFontSize.summary,
                height: 1.7,
                letterSpacing: 0.3,
                leadingDistribution: TextLeadingDistribution.even,
                color: colors.text,
              ),
              Styles.maxWidth: 640.0,
              // 页边距用设计 token（列表/设置页同一个值）。正文、引用、
              // 代码块都走这条；图片/附件块的 ViewModel 也要用同一个值，
              // 否则媒体会通栏贴屏幕边（用户反馈「详情没有内边距」）。
              Styles.padding:
                  const CascadingPadding.symmetric(horizontal: AppSpace.page),
              // IME 组词下划线：super_editor 默认是 2px 纯黑方头，
              // 在手机上像一条粗黑杠（用户反馈「正在输入的文字下面有粗黑线」）。
              // 这里换成 1dp 主色细线，保留组词提示又不抢视觉。
              Styles.composingRegionUnderlineStyle: StraightUnderlineStyle(
                color: colors.accent.withValues(alpha: 0.55),
                thickness: 1,
                offset: 3,
                capType: StrokeCap.round,
              ),
              // 行内样式见上方 `inlineTextStyler` 参数（写在规则里会被丢弃）。
            };
          },
        ),
        // 文档末尾留白：**只有最后一个块**。之前写在 BlockSelector.all
        // 上，每个块底下都垫了 96，块间隙大到离谱（实测）。
        //
        // 键盘收起且内容不足一屏时，这里额外补 [_imeCollapseBottomPad]：
        // 直接加在「内容」里，`maxScrollExtent` 随之变大，滚动位置才有
        // 空间保得住；加在编辑器外层的 Padding 只会缩小视口，补不回
        // 原有的 offset（实测 max 仍是 0）。
        StyleRule(
          BlockSelector.all.last(),
          (Document doc, DocumentNode node) {
            return <String, dynamic>{
              Styles.padding: CascadingPadding.only(
                bottom: 96 + _imeCollapseBottomPad,
              ),
            };
          },
        ),
        // 段落间距收紧（默认 24 太散，手机端要紧凑）。
        // 12 与列表项上下 2 形成「段落明显断开、列表行内轻微呼吸」的层级，
        // 而不是所有块都用同一个大间距（那样看起来每一行都散着）。
        //
        // 正文行距：只覆盖 paragraph 的 height（1.7 → 1.6），16 号字下
        // 行盒从 27.2 收到 25.6，接近语雀/Notion 移动端的 1.6，长文
        // 连续阅读不再「一行一行散着」。TextStyle.merge 只覆盖非空字段，
        // 字号/字距/颜色仍从 BlockSelector.all 级联。
        //
        // 标题（1.3/1.35）、引用（AppQuote.height）、代码块（卡片规格）、
        // 列表行都各自有行高来源，不受这条影响 —— 用户明确要求
        // 「不要影响其他的行间距」。
        StyleRule(
          const BlockSelector('paragraph'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.textStyle: const TextStyle(height: 1.6),
            Styles.padding: const CascadingPadding.only(top: 12),
          },
        ),
        // 标题后的首段落不再叠段距：标题自身已有 bottom padding，
        // 再叠 12 会出现「标题和第一句断开」的空档。这三条要排在上面的
        // 通用段落规则之后，后命中的规则才会覆盖它。
        StyleRule(
          const BlockSelector('paragraph').after('header1'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.padding: const CascadingPadding.only(top: 0),
          },
        ),
        StyleRule(
          const BlockSelector('paragraph').after('header2'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.padding: const CascadingPadding.only(top: 0),
          },
        ),
        StyleRule(
          const BlockSelector('paragraph').after('header3'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.padding: const CascadingPadding.only(top: 0),
          },
        ),
        // 列表项/待办：小间距，像语雀一样紧凑。
        // 有序列表标记对齐已核对：OrderedListItemComponent 用行文本同款
        // styleBuilder（inherit: false）+ 右对齐 OverflowBox 渲染编号，
        // 与正文基线天然对齐，接受默认，不做 hack。
        StyleRule(
          const BlockSelector('listItem'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.padding: const CascadingPadding.symmetric(vertical: 2),
            // 无序列表的圆点默认跟着正文色走，太重；淡显成三级文字色，
            // 视觉层级回到「内容在前、记号在后」（与阅读态渲染器一致）。
            Styles.dotColor: colors.tertiary,
          },
        ),
        // 待办 checkbox：TaskComponent 用的是 Material 原生 Checkbox，
        // 勾选色走全局 CheckboxTheme/ColorScheme（源码实测，无 Styles 键
        // 可配），stylesheet 管不到 —— 主色已经由 app_theme 的 ColorScheme
        // 统一成 accent，接受默认，不在组件内 hack。
        StyleRule(
          const BlockSelector('task'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.padding: const CascadingPadding.symmetric(vertical: 3),
          },
        ),
        // 标题三档：21/18.5/16.5，行高 1.3。比正文 15.5 高 1.35/1.19/1.06 倍，
        // 层级清楚但不占掉半屏。段前留白 24/18/14 逐级递减 —— 参考
        // GitHub/语雀的「标题前留白明显大于段后」，一章开始时有呼吸感，
        // 且不会把半屏吃掉。leadingDistribution.even 与正文保持一致。
        StyleRule(
          const BlockSelector('header1'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.textStyle: TextStyle(
              fontSize: AppFontSize.titleLg,
              fontWeight: AppWeight.semibold,
              height: 1.3,
              letterSpacing: 0.3,
              leadingDistribution: TextLeadingDistribution.even,
              color: colors.text,
            ),
            Styles.padding: const CascadingPadding.only(top: 24, bottom: 8),
          },
        ),
        StyleRule(
          const BlockSelector('header2'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.textStyle: TextStyle(
              fontSize: AppFontSize.heading,
              fontWeight: AppWeight.semibold,
              height: 1.3,
              letterSpacing: 0.25,
              leadingDistribution: TextLeadingDistribution.even,
              color: colors.text,
            ),
            Styles.padding: const CascadingPadding.only(top: 18, bottom: 6),
          },
        ),
        StyleRule(
          const BlockSelector('header3'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.textStyle: TextStyle(
              fontSize: AppFontSize.bodyLg,
              fontWeight: AppWeight.semibold,
              height: 1.3,
              letterSpacing: 0.2,
              leadingDistribution: TextLeadingDistribution.even,
              color: colors.text,
            ),
            Styles.padding: const CascadingPadding.only(top: 14, bottom: 4),
          },
        ),
        // H4–H6：内核默认样式表只写到 H3，不补的话这三档在详情页与正文
        // 完全一样（列表摘要却按层级递减，两处看起来不是同一篇文档）。
        // 字号已到正文下限，靠字重与颜色继续区分层级。
        StyleRule(
          const BlockSelector('header4'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.textStyle: TextStyle(
              fontSize: AppFontSize.summary,
              fontWeight: AppWeight.semibold,
              height: 1.35,
              leadingDistribution: TextLeadingDistribution.even,
              color: colors.text,
            ),
            Styles.padding: const CascadingPadding.only(top: 12, bottom: 4),
          },
        ),
        StyleRule(
          const BlockSelector('header5'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.textStyle: TextStyle(
              fontSize: AppFontSize.summary,
              fontWeight: AppWeight.medium,
              height: 1.35,
              leadingDistribution: TextLeadingDistribution.even,
              color: colors.text,
            ),
            Styles.padding: const CascadingPadding.only(top: 10, bottom: 2),
          },
        ),
        StyleRule(
          const BlockSelector('header6'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.textStyle: TextStyle(
              fontSize: AppFontSize.summary,
              fontWeight: AppWeight.regular,
              height: 1.35,
              leadingDistribution: TextLeadingDistribution.even,
              color: colors.text.withValues(alpha: 0.72),
            ),
            Styles.padding: const CascadingPadding.only(top: 8, bottom: 2),
          },
        ),
        // 引用块：底色/圆角/竖条/内边距都由 [QuoteBlock] 画（见
        // _LabBlockquoteComponentBuilder），这里只管字阶和外层纵向间距。
        // 左右页边距仍从 BlockSelector.all 级联过来，块与正文同宽。
        StyleRule(
          const BlockSelector('blockquote'),
          (Document doc, DocumentNode node) {
            final bool continuesAbove = _quoteContinuesAbove(doc, node);
            final bool continuesBelow = _quoteContinuesBelow(doc, node);
            return <String, dynamic>{
              Styles.textStyle: TextStyle(
                fontSize: AppQuote.fontSize,
                height: AppQuote.height,
                letterSpacing: AppQuote.letterSpacing,
                leadingDistribution: TextLeadingDistribution.even,
                color: colors.text.withValues(alpha: 0.8),
              ),
              // 相邻引用行之间的段距归零：上下各 6 会在两块中间留一条
              // 页面底色的缝，回车续行的两行看起来就是两个独立引用框。
              Styles.padding: CascadingPadding.only(
                top: continuesAbove ? 0 : 6,
                bottom: continuesBelow ? 0 : 6,
              ),
            };
          },
        ),
        // 表格：细线网格 + 表头淡底，与语雀的「轻网格」观感一致。
        // 表格组件只认 TableStyles（MarkdownTableComponent 的样式入口），
        // 单元格内边距比正文松一点，手指横向滚动时不容易误触。
        StyleRule(
          const BlockSelector('tableBlock'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            TableStyles.border: TableBorder.all(
              color: colors.divider,
              width: 0.8,
            ),
            TableStyles.headerTextStyle: const TextStyle(
              fontWeight: AppWeight.semibold,
            ),
            TableStyles.cellPadding: const CascadingPadding.symmetric(
              horizontal: 10,
              vertical: 7,
            ),
            TableStyles.cellDecorator: _tableCellDecorator(colors),
            Styles.padding: const CascadingPadding.symmetric(vertical: 8),
          },
        ),
        // 代码块：等宽 + 字号/行高/内边距与列表摘要同源
        // （[CodeBlockCardStyle]，两处共用一份规格）。
        // 底色/圆角由 _LabCodeBlockComponentBuilder 的外层卡片画（整宽），
        // 这里只负责文字本身，不能再给 TextStyle 加 backgroundColor ——
        // 逐行字符底色会在卡片里叠出一圈毛边。
        StyleRule(
          const BlockSelector('code'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.textStyle: TextStyle(
              fontFamily: 'monospace',
              fontSize:
                  AppFontSize.summary * CodeBlockCardStyle.fontSizeFactor,
              height: CodeBlockCardStyle.lineHeight,
              letterSpacing: 0,
              leadingDistribution: TextLeadingDistribution.even,
              color: colors.text
                  .withValues(alpha: CodeBlockCardStyle.textAlpha),
            ),
            // 横向页边距从 BlockSelector.all 级联（16），卡片与正文同宽；
            // 卡片内边距在组件里给，这里只补块间呼吸。
            Styles.padding: const CascadingPadding.symmetric(
              vertical: CodeBlockCardStyle.outerGap,
            ),
          },
        ),
        // 代码块后面的块：不再叠加自己的顶部段距。
        //
        // 卡片外部已经有 6 的底部留白，这 6 就是「卡片与下一行」的全部间距；
        // 下一块如果还保留正文默认的 12，合计 18，比列表摘要（卡片下方只有
        // 6）明显发空（用户多轮反馈「详情代码块下面的间距偏大」）。
        // 与列表摘要对齐：卡片之后只留卡片自己的 6。
        StyleRule(
          BlockSelector.all.after('code'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.padding: const CascadingPadding.only(top: 0),
          },
        ),
        // 有序列表分层编号（1. → a. → i.），与阅读态渲染器同方案。
        StyleRule(
          BlockSelector.all,
          (Document doc, DocumentNode node) {
            if (node is ListItemNode && node.type == ListItemType.ordered) {
              if (node.indent == 1) {
                return <String, dynamic>{
                  Styles.listNumeralStyle: OrderedListNumeralStyle.lowerAlpha,
                };
              }
              if (node.indent >= 2) {
                return <String, dynamic>{
                  Styles.listNumeralStyle: OrderedListNumeralStyle.lowerRoman,
                };
              }
            }
            return const <String, dynamic>{};
          },
        ),
      ],
    );
  }

  /// 工具条：复用早期版本验证过的 [MarkdownToolbar]（布局逻辑零改动），
  /// 命令经 [KernelCommands] 映射到 super_editor 内核。
  ///
  /// 只在编辑态（有光标/选区）显示：浏览态露出来时按钮没有作用对象，
  /// 点下去只会 no-op，用户会误判成「功能坏了」。显隐用滑入/淡入，
  /// 内容区底部 padding 是常量，不会因为工具条出现而顶动正文。
  Widget _buildToolbar(double imeInset) {
    const duration = Duration(milliseconds: 180);
    return Positioned(
      left: 0,
      right: 0,
      // 平时贴 body 底部（贴键盘上沿）；面板/键盘交替期间用锚点把工具条
      // 钉在原键盘高度上（`锚点 - 当前 ime`），整段动画屏幕 Y 不变。
      bottom: _toolbarBottomOffset(imeInset),
      child: ValueListenableBuilder<bool>(
        valueListenable: _editing,
        builder: (BuildContext context, bool editing, _) {
          // 输入法收起（系统返回键/手势）后，即使编辑器选区还在，
          // 工具栏也必须跟着收起；否则底部会一直挂着一条按钮条。
          // 子菜单展开、或正在「面板 → 键盘」回弹时，键盘高度可能短暂为
          // 0，但工具栏必须留下（否则会先滑下去再被顶上来，用户反馈）。
          final bool show = editing && (imeInset > 0 || _panelTransitioning);
          return IgnorePointer(
            // 不可见时也别让它接住点击（否则会点和渲染态完全无关的东西）。
            ignoring: !show,
            child: AnimatedSlide(
              offset: show ? Offset.zero : const Offset(0, 1),
              duration: duration,
              curve: Curves.easeOut,
              child: AnimatedOpacity(
                opacity: show ? 1 : 0,
                duration: duration,
                curve: Curves.easeOut,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) {},
                  child: AnimatedBuilder(
                    animation: Listenable.merge(<Listenable>[
                      _activeCommands,
                      _canUndo,
                      _canRedo,
                    ]),
                    builder: (BuildContext context, Widget? _) {
                      final Set<MarkdownCommand> active = _activeCommands.value;
                      final bool canUndo = _canUndo.value;
                      final bool canRedo = _canRedo.value;
                      // 面板展开/收起、键盘回弹这一整段里，系统底部安全区
                      // （手势条）会重新算进 SafeArea —— 工具条内部那一层
                      // SafeArea 会让按钮行整体偏移一截（实测 21dp）。
                      // 交替期间把底部安全区从工具条的 MediaQuery 里去掉：
                      // 键盘可见时它本来就是 0，整段过程保持同一套几何，
                      // 工具条位置因此纹丝不动。
                      return MediaQuery.removePadding(
                        context: context,
                        removeBottom: _panelTransitioning,
                        child: MarkdownToolbar(
                          onCommand: _runToolbarCommand,
                          onAttachAction: _handleAttachAction,
                          onHideKeyboard: _hideKeyboard,
                          // 受控模式：面板由页面渲染在工具条下方（原键盘
                          // 区域），工具条本身不移动、不做正文预留。
                          panel: _panel,
                          onPanelToggle: _togglePanel,
                          active: active,
                          // 工具栏新布局：标签入口 + 撤销/还原（顶栏已精简）。
                          onEditTags: _editTagsFromToolbar,
                          onUndo: _editor.undo,
                          onRedo: _editor.redo,
                          canUndo: canUndo,
                          canRedo: canRedo,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 图片点击 / 长按区：用 [Listener] 而不是 GestureDetector。
///
/// 图片现在承载了 `componentKey`（官方 ImageComponent / BoxComponent），
/// 编辑器自己的选择手势会和 GestureDetector 抢竞技场，导致点击图片
/// 只出现选区手柄、不打开查看器（实测）。Listener 不进竞技场，
/// 按下/抬起位移小于 12、时长小于 500ms 就当作点击，滑动滚动手势不受影响；
/// 按住 500ms 不动则触发长按菜单（图片操作）。
class _ImageViewerTapArea extends StatefulWidget {
  const _ImageViewerTapArea({
    required this.onTap,
    this.onLongPress,
    required this.child,
  });

  final VoidCallback onTap;

  /// 长按（500ms 内位移不超过 12dp）：打开图片操作菜单。
  final VoidCallback? onLongPress;

  final Widget child;

  @override
  State<_ImageViewerTapArea> createState() => _ImageViewerTapAreaState();
}

class _ImageViewerTapAreaState extends State<_ImageViewerTapArea> {
  Offset? _downPosition;
  DateTime? _downAt;
  Timer? _longPressTimer;
  bool _longPressFired = false;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (PointerDownEvent event) {
        _downPosition = event.position;
        _downAt = DateTime.now();
        _longPressFired = false;
        _cancelLongPress();
        if (widget.onLongPress != null) {
          _longPressTimer = Timer(const Duration(milliseconds: 500), () {
            _longPressFired = true;
            widget.onLongPress!();
          });
        }
      },
      onPointerMove: (PointerMoveEvent event) {
        final Offset? down = _downPosition;
        if (down != null && (event.position - down).distance > 12) {
          _cancelLongPress();
        }
      },
      onPointerUp: (PointerUpEvent event) {
        final Offset? down = _downPosition;
        final DateTime? at = _downAt;
        _downPosition = null;
        _downAt = null;
        _cancelLongPress();
        if (_longPressFired) {
          _longPressFired = false;
          return;
        }
        if (down == null || at == null) {
          return;
        }
        final double distance = (event.position - down).distance;
        final int millis = DateTime.now().difference(at).inMilliseconds;
        if (distance <= 12 && millis <= 500) {
          widget.onTap();
        }
      },
      onPointerCancel: (_) {
        _downPosition = null;
        _downAt = null;
        _longPressFired = false;
        _cancelLongPress();
      },
      child: widget.child,
    );
  }
}

/// ImageNode 渲染：把我们的相对路径（assets/…）解析成真实文件路径。
class _LabImageComponentBuilder implements ComponentBuilder {
  const _LabImageComponentBuilder({
    required this.repository,
    required this.editor,
    required this.onImageLongPress,
  });

  final NoteRepository repository;
  final Editor editor;

  /// 长按图片：打开「小图/大图、下载、删除」菜单。
  final void Function(
    BuildContext context,
    String nodeId,
    String absolutePath,
    ImageDisplaySize size,
  ) onImageLongPress;

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    if (node is! ImageNode) {
      return null;
    }
    return _LabImageViewModel(
      nodeId: node.id,
      imageUrl: node.imageUrl,
      altText: node.altText,
      repository: repository,
    );
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! _LabImageViewModel) {
      return null;
    }
    // URL 末尾可能带「小图」标记：解析真实文件前先剥掉。
    final ImageDisplaySize size =
        imageDisplaySizeOf(componentViewModel.imageUrl);
    final String rawPath = imageFilePath(componentViewModel.imageUrl);
    final String path = rawPath.startsWith('assets/')
        ? componentViewModel.repository.store.absoluteAssetPath(rawPath)
        : rawPath;

    final Widget image = ImageComponent(
      componentKey: componentContext.componentKey,
      imageUrl: path,
      imageBuilder: (BuildContext context, String _) => Image.file(
        File(path),
        // 由外层的 AdaptiveImageFrame 决定盒子尺寸：
        //  - 普通图片盒子的宽高比 = 原图比例，cover 等价于等比缩放；
        //  - 超长图盒子被限高后才裁切，并显示「长图」角标（微信逻辑）。
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        width: double.infinity,
        // 图挂了不能白屏：errorBuilder 退回占位框，alt 文字可读。
        errorBuilder: (_, __, ___) => _placeholder(componentViewModel),
      ),
    );

    // 点击/长按区域必须**包在图片盒子里面**：AdaptiveImageFrame 右对齐
    // 之外还有一整行空白（Align 会撑满可用宽度），如果把 Listener 放在
    // 外面，点图片右侧的空白也会打开查看器（用户反馈）。
    // 现在 Listener 拿到的是 SizedBox 的紧约束，命中范围严格等于图片框。
    final Widget tappable = _ImageViewerTapArea(
      onTap: () {
        // 点图先退出编辑态：否则键盘/选区手柄会在查看器后面挂着。
        editor.execute(<EditRequest>[const ClearSelectionRequest()]);
        _openViewer(
          componentContext,
          path,
          componentViewModel.altText,
        );
      },
      onLongPress: () => onImageLongPress(
        componentContext.context,
        componentViewModel.nodeId,
        path,
        size,
      ),
      child: image,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      // 微信式尺寸规则（大小图都遵循，详见 AdaptiveImageFrame）：
      //  - 不放大：小图按原始尺寸显示；
      //  - 普通竖图：整体缩小到高度上限内（不裁切）；
      //  - 超长截图：定宽 + 限高裁切，右下角标「长图」，点开看原图。
      // 只给「目标宽度比例」和「高度上限」，具体盒子由图片比例决定，
      // 所以超长图不会再一条铺满屏幕。
      child: AdaptiveImageFrame(
        path: path,
        widthFactor: size == ImageDisplaySize.small ? 0.4 : 1,
        maxHeight: size == ImageDisplaySize.small ? 180 : 420,
        child: tappable,
      ),
    );
  }

  /// 捕获图片块当前的全局矩形，打开大图查看器。
  void _openViewer(
    SingleColumnDocumentComponentContext componentContext,
    String absolutePath,
    String alt,
  ) {
    Rect sourceRect = Rect.zero;
    final renderObject =
        componentContext.componentKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox &&
        renderObject.attached &&
        renderObject.hasSize) {
      sourceRect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    }
    Navigator.of(componentContext.context).push(
      buildImageViewerRoute(
        sourceRect: sourceRect,
        absolutePath: absolutePath,
        alt: alt,
      ),
    );
  }

  Widget _placeholder(_LabImageViewModel vm) {
    return Builder(
      builder: (BuildContext context) {
        final colors = AppColors.of(context);
        return Container(
          height: 120,
          decoration: BoxDecoration(
            color: colors.surface2,
            borderRadius: BorderRadius.circular(AppRadius.block),
          ),
          alignment: Alignment.center,
          child: Text(
            vm.altText.isEmpty ? '图片' : vm.altText,
            style:
                TextStyle(fontSize: AppFontSize.label, color: colors.tertiary),
          ),
        );
      },
    );
  }
}

class _LabImageViewModel extends SingleColumnLayoutComponentViewModel {
  _LabImageViewModel({
    required super.nodeId,
    required this.imageUrl,
    required this.altText,
    required this.repository,
  }) : super(
          createdAt: null,
          // 图片块与正文用同一个左右页边距：之前是 EdgeInsets.zero，
          // 图片直接从屏幕最左铺到最右，正文却有边距，看起来像两张皮。
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
        );

  final String imageUrl;
  final String altText;
  final NoteRepository repository;

  @override
  SingleColumnLayoutComponentViewModel copy() {
    return _LabImageViewModel(
      nodeId: nodeId,
      imageUrl: imageUrl,
      altText: altText,
      repository: repository,
    );
  }
}

/// 代码块：官方段落 + 外层整宽圆角卡片。
///
/// 为什么不自建组件：单列布局的命中测试只认官方组件状态，自建的 Proxy
/// 组件会被跳过（用户实测「点不进光标」）。所以 `componentKey` 仍然交给
/// 官方 `ParagraphComponent`，只在外面包一层负责视觉的外壳。
///
/// 外壳必须**不参与命中测试**：`Container`/`DecoratedBox` 的
/// `BoxDecoration.hitTest` 会命中自身，内容层被命中后，super_editor 垫在
/// 内容下方的点击层（`SliverHybridStack` 里更靠下）就收不到事件 ——
/// 整块代码块点不动、长按也选不了词（实测）。`CustomPaint` 默认不命中，
/// 点击照常落到内核，光标/拖选/长按全部保持官方行为。
class _LabCodeBlockComponentBuilder implements ComponentBuilder {
  const _LabCodeBlockComponentBuilder({required this.editor});

  final Editor editor;

  /// ViewModel 直接复用官方构建器（含 indent / textStyleBuilder / 选区）。
  static const ParagraphComponentBuilder _delegate =
      ParagraphComponentBuilder();

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    if (!_isCodeBlock(node)) {
      return null;
    }
    return _delegate.createViewModel(document, node);
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! ParagraphComponentViewModel) {
      return null;
    }
    // 注意：createComponent 会被**所有** builder 依次调用（ViewModel 由
    // 哪个 builder 产出都一样），所以这里必须再按节点类型判断一次，
    // 否则所有普通段落都会套上代码块卡片（实测：整页变灰块）。
    final DocumentNode? node =
        editor.document.getNodeById(componentViewModel.nodeId);
    if (!_isCodeBlock(node)) {
      return null;
    }
    return _CodeBlockCard(
      child: ParagraphComponent(
        key: componentContext.componentKey,
        viewModel: componentViewModel,
      ),
    );
  }

  static bool _isCodeBlock(DocumentNode? node) {
    return node is ParagraphNode &&
        node.getMetadataValue(NodeMetadata.blockType) == codeAttribution;
  }
}

/// 代码块的视觉外壳：整宽、圆角、surface2 底色 + 内边距。
///
/// 只画背景、不接手势（见 [_LabCodeBlockComponentBuilder] 的注释）。
class _CodeBlockCard extends StatelessWidget {
  const _CodeBlockCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        // 背景层用 IgnorePointer 包住：CustomPaint/DecoratedBox 都可能命中
        // 自身，一旦命中，内核垫在内容下方的点击层就收不到事件（实测：
        // 代码块整块点不动、长按选不了词）。背景层只负责画，不接手势。
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _CodeBlockCardPainter(
                color: AppColors.of(context).surface2,
              ),
            ),
          ),
        ),
        Padding(
          // 内边距与列表摘要的代码块卡片同源（[CodeBlockCardStyle]）。
          padding: const EdgeInsets.symmetric(
            horizontal: CodeBlockCardStyle.paddingHorizontal,
            vertical: CodeBlockCardStyle.paddingVertical,
          ),
          child: child,
        ),
      ],
    );
  }
}

class _CodeBlockCardPainter extends CustomPainter {
  const _CodeBlockCardPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(AppRadius.block),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_CodeBlockCardPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 点击「已有光标」不再切换选择工具条。
///
/// super_editor 的 Android 手势在「点击落在已有 collapsed 选区」时会
/// `toggleToolbar()` —— 双击的第二下正好命中这个条件，于是双击就弹出
/// 「复制/剪切/粘贴/全选」（用户反馈）。主流移动笔记只在**有选区**时
/// 显示工具条，所以这里把 toggle 关掉；长按选词走的是 `showToolbar()`
/// （展开选区分支），不受影响。
class _XiaojiAndroidControlsController
    extends SuperEditorAndroidControlsController {
  _XiaojiAndroidControlsController({required super.toolbarBuilder});

  @override
  void toggleToolbar() {
    // 刻意不实现：点光标不弹工具条。
  }
}

/// 该节点是否是引用段落。
bool _isQuoteNode(DocumentNode? node) {
  return node is ParagraphNode &&
      node.getMetadataValue(NodeMetadata.blockType) == blockquoteAttribution;
}

/// 上方紧邻的是否也是引用段。
///
/// 回车续行会把引用拆成两个相邻段落；渲染时它们必须合流成一整块，
/// 否则中间会露出一条页面底色的缝（见 [QuoteBlock.continuesAbove]）。
bool _quoteContinuesAbove(Document doc, DocumentNode node) =>
    _isQuoteNode(doc.getNodeBeforeById(node.id));

/// 下方紧邻的是否也是引用段。
bool _quoteContinuesBelow(Document doc, DocumentNode node) =>
    _isQuoteNode(doc.getNodeAfterById(node.id));

/// 引用块：自建组件，不复用官方 `BlockquoteComponent`。
///
/// 官方实现有两处硬伤（源码实测）：
///  1. 整块包在 `IgnorePointer` 里 —— 点击引用块永远不进编辑态，
///     只能从下一行退格「挤」进去（用户反馈）；
///  2. 内部 padding 写死 `16/16`，stylesheet 的内边距只在外面再叠一层，
///     单行引用块高到 56dp，明显比语雀/GitHub 胖。
///
/// 这里按 [QuoteBlock] 的规格重建：整块圆角裁剪 + 左侧竖条（竖条两端
/// 也跟着圆角），上下 8 + 行盒 24 ≈ 40dp，且正常接收点击/选区。
class _LabBlockquoteComponentBuilder implements ComponentBuilder {
  const _LabBlockquoteComponentBuilder({
    required this.editor,
    required this.focusNode,
  });

  final Editor editor;
  final FocusNode focusNode;

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    if (node is! ParagraphNode) {
      return null;
    }
    if (node.getMetadataValue(NodeMetadata.blockType) !=
        blockquoteAttribution) {
      return null;
    }
    final TextDirection textDirection =
        getParagraphDirection(node.text.toPlainText());
    return BlockquoteComponentViewModel(
      nodeId: node.id,
      createdAt: node.metadata[NodeMetadata.createdAt] as DateTime?,
      text: node.text,
      textStyleBuilder: noStyleBuilder,
      indent: node.indent,
      backgroundColor: const Color(0x00000000),
      borderRadius: BorderRadius.zero,
      textDirection: textDirection,
      textAlignment:
          textDirection == TextDirection.ltr ? TextAlign.left : TextAlign.right,
      selectionColor: const Color(0x00000000),
    );
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! BlockquoteComponentViewModel) {
      return null;
    }
    final DocumentNode? node = editor.document.getNodeById(
      componentViewModel.nodeId,
    );
    return _XiaojiBlockquoteComponent(
      componentKey: componentContext.componentKey,
      viewModel: componentViewModel,
      editor: editor,
      focusNode: focusNode,
      // 相邻引用段要合流：这一块负责画多大规模的圆角/内边距。
      continuesAbove:
          node != null && _quoteContinuesAbove(editor.document, node),
      continuesBelow:
          node != null && _quoteContinuesBelow(editor.document, node),
    );
  }
}

/// 引用块的组件本体。
///
/// 关键点：`TextComponent` 只实现了 `TextComposable`，**不是**
/// `ProxyTextComposable`。官方 `BlockquoteComponent` 把 componentKey 直接
/// 挂在 TextComponent 上，所以编辑器找不到这一块的文本布局 —— 点按、
/// 选区矩形、光标定位全部失效（这就是「点引用块不进入编辑态」的根因）。
/// 这里补一层 `ProxyTextDocumentComponent`，并把 key 挂到代理上。
class _XiaojiBlockquoteComponent extends StatefulWidget {
  const _XiaojiBlockquoteComponent({
    required this.componentKey,
    required this.viewModel,
    required this.editor,
    required this.focusNode,
    this.continuesAbove = false,
    this.continuesBelow = false,
  });

  final GlobalKey componentKey;
  final BlockquoteComponentViewModel viewModel;

  /// 点按引用块时自己落光标用（见 [_XiaojiBlockquoteComponentState]）。
  final Editor editor;
  final FocusNode focusNode;

  /// 上下相邻块是否也是引用（决定合流时省掉哪一侧的圆角/内边距）。
  final bool continuesAbove;
  final bool continuesBelow;

  @override
  State<_XiaojiBlockquoteComponent> createState() =>
      _XiaojiBlockquoteComponentState();
}

class _XiaojiBlockquoteComponentState
    extends State<_XiaojiBlockquoteComponent> {
  /// 代理与内部文本组件的连接键（生命周期跟 State 走，不能每次 build 新建）。
  final GlobalKey _innerTextComponentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final BlockquoteComponentViewModel vm = widget.viewModel;
    return GestureDetector(
      // translucent：自己处理点按落光标，同时不挡住内部链接/标签的命中。
      behavior: HitTestBehavior.translucent,
      onTapDown: _placeCaretAt,
      child: QuoteBlock(
        continuesAbove: widget.continuesAbove,
        continuesBelow: widget.continuesBelow,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 引用块不缩进（indent 恒为 0），保留这段宽度以兼容将来
            // 引用嵌套缩进的模型变化。
            SizedBox(
              width: vm.indentCalculator(
                vm.textStyleBuilder(<Attribution>{}),
                vm.indent,
              ),
            ),
            Expanded(
              child: ProxyTextDocumentComponent(
                key: widget.componentKey,
                textComponentKey: _innerTextComponentKey,
                child: TextComponent(
                  key: _innerTextComponentKey,
                  text: vm.text,
                  maxLines: vm.maxLines,
                  overflow: vm.overflow,
                  textStyleBuilder: vm.textStyleBuilder,
                  inlineWidgetBuilders: vm.inlineWidgetBuilders,
                  textSelection: vm.selection,
                  selectionColor: vm.selectionColor,
                  highlightWhenEmpty: vm.highlightWhenEmpty,
                  underlines: vm.createUnderlines(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 点引用块直接落光标。
  ///
  /// super_editor 的点按是「文档坐标 → 组件 → 文本位置」三段式，引用块
  /// 走这条链路时拿不到文本布局（见类注释）。这里改用组件自身的
  /// [DocumentComponent.getPositionAtOffset]，再整体选中该位置。
  void _placeCaretAt(TapDownDetails details) {
    final DocumentComponent? component =
        widget.componentKey.currentState as DocumentComponent?;
    final RenderObject? renderObject =
        widget.componentKey.currentContext?.findRenderObject();
    if (component == null || renderObject is! RenderBox) {
      return;
    }
    final Offset localOffset =
        renderObject.globalToLocal(details.globalPosition);
    final NodePosition? position = component.getPositionAtOffset(localOffset);
    if (position == null) {
      return;
    }
    widget.editor.execute(<EditRequest>[
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: widget.viewModel.nodeId,
            nodePosition: position,
          ),
        ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    ]);
    widget.focusNode.requestFocus();
  }
}

/// 只替换列表项的缩进计算，编号/圆点/选区/IME 全部沿用官方组件。
///
/// 不做整块复刻：官方 `ListItemComponentBuilder` 负责 ViewModel（含
/// 序号、序号风格、行内属性），那部分逻辑没有任何需要改的地方。
/// 记号列宽与待办行统一取自 [AppListMarker]（三类行的正文起点一致）。
class _LabListItemComponentBuilder implements ComponentBuilder {
  const _LabListItemComponentBuilder();

  static const ListItemComponentBuilder _delegate = ListItemComponentBuilder();

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    final SingleColumnLayoutComponentViewModel? viewModel =
        _delegate.createViewModel(document, node);
    // 有序列表：内核只算「同层第几个」，起始编号存在节点 metadata 里，
    // 这里补上偏移，`5.` 开头的列表在编辑器里也显示 5、6、7。
    if (viewModel is OrderedListItemComponentViewModel &&
        node is ListItemNode) {
      final ({int ordinal, int start})? number =
          orderedListItemNumber(document, node);
      if (number != null) {
        viewModel.ordinalValue = number.start + number.ordinal - 1;
      }
    }
    return viewModel;
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is UnorderedListItemComponentViewModel) {
      return UnorderedListItemComponent(
        componentKey: componentContext.componentKey,
        text: componentViewModel.text,
        styleBuilder: componentViewModel.textStyleBuilder,
        indent: componentViewModel.indent,
        dotStyle: componentViewModel.dotStyle,
        textSelection: componentViewModel.selection,
        textDirection: componentViewModel.textDirection,
        textAlignment: componentViewModel.textAlignment,
        selectionColor: componentViewModel.selectionColor,
        highlightWhenEmpty: componentViewModel.highlightWhenEmpty,
        underlines: componentViewModel.createUnderlines(),
        inlineWidgetBuilders: componentViewModel.inlineWidgetBuilders,
        indentCalculator: AppListMarker.width,
        // 层级用符号区分（• → ◦ → ▪），与阅读态渲染器 [MarkdownBlockView]
        // 的无序列表完全同一套；官方默认各层都画同一个实心点，子列表
        // 只能靠缩进辨认。参考 Notion / 语雀 / 微信做法。
        dotBuilder: _buildUnorderedListDot,
      );
    }
    if (componentViewModel is OrderedListItemComponentViewModel) {
      return OrderedListItemComponent(
        componentKey: componentContext.componentKey,
        indent: componentViewModel.indent,
        listIndex: componentViewModel.ordinalValue!,
        text: componentViewModel.text,
        textDirection: componentViewModel.textDirection,
        textAlignment: componentViewModel.textAlignment,
        styleBuilder: componentViewModel.textStyleBuilder,
        numeralStyle: componentViewModel.numeralStyle,
        textSelection: componentViewModel.selection,
        selectionColor: componentViewModel.selectionColor,
        highlightWhenEmpty: componentViewModel.highlightWhenEmpty,
        underlines: componentViewModel.createUnderlines(),
        inlineWidgetBuilders: componentViewModel.inlineWidgetBuilders,
        indentCalculator: AppListMarker.width,
      );
    }
    return null;
  }
}

/// 无序列表记号：按缩进层级换符号（• → ◦ → ▪）。
///
/// 与阅读态渲染器 [MarkdownBlockView] 的 `_bulletGlyph` 同一套符号，
/// 详情页与主页摘要看起来一致。官方默认各层都画同一个 4dp 实心圆，
/// 嵌套子列表只能靠缩进辨认（Notion / 语雀 / 微信都会换符号）。
///
/// 用 [TextStyle] 原样继承正文行高（不改 height），记号的基线因此与
/// 首行文字对齐；外层容器已按正文行盒高度约束并右对齐。
Widget _buildUnorderedListDot(
  BuildContext context,
  UnorderedListItemComponent component,
) {
  final TextStyle textStyle = component.styleBuilder(
    component.text.getAllAttributionsAt(0).toSet(),
  );
  final String glyph = switch (component.indent) {
    0 => '•',
    1 => '◦',
    _ => '▪',
  };
  return Align(
    alignment: Alignment.centerRight,
    child: Padding(
      // 与官方默认记号相同的右侧留白，正文起点不受影响。
      padding: const EdgeInsets.only(right: 10),
      child: Text(
        glyph,
        style: textStyle.copyWith(color: AppColors.of(context).tertiary),
      ),
    ),
  );
}

/// 分隔线渲染接管：颜色写死是 super_editor 的缺口（见 componentBuilders
/// 处的注释），这里用主题 divider 色重建官方组件 —— 不 hack 内部实现，
/// 只是把「线的颜色」这一个构造参数换掉。
class _LabHorizontalRuleComponentBuilder implements ComponentBuilder {
  const _LabHorizontalRuleComponentBuilder();

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    if (node is! HorizontalRuleNode) {
      return null;
    }
    // 与官方 HorizontalRuleComponentBuilder 相同的 ViewModel 默认值
    // （选区/光标全透明），只有组件层的线色由本类重绘。
    return HorizontalRuleComponentViewModel(
      nodeId: node.id,
      createdAt: node.metadata[NodeMetadata.createdAt] as DateTime?,
      selectionColor: const Color(0x00000000),
      caretColor: const Color(0x00000000),
    );
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! HorizontalRuleComponentViewModel) {
      return null;
    }
    final colors = AppColors.of(componentContext.context);
    return HorizontalRuleComponent(
      componentKey: componentContext.componentKey,
      selection: componentViewModel.selection?.nodeSelection
          as UpstreamDownstreamNodeSelection?,
      selectionColor: componentViewModel.selectionColor,
      showCaret: componentViewModel.caret != null,
      caretColor: componentViewModel.caretColor,
      opacity: componentViewModel.opacity,
      // 品牌色的分隔线：浅色用 6% 黑、深色用 7% 白，两种主题都贴纸感。
      color: colors.divider,
    );
  }
}

/// 表格单元格装饰：表头一行铺页面次级底色，数据行交给表格边框。
TableCellDecorator _tableCellDecorator(AppColors colors) {
  return ({
    required int rowIndex,
    required int columnIndex,
    required AttributedText cellText,
    required Map<String, dynamic> cellMetadata,
  }) {
    return rowIndex == 0 ? BoxDecoration(color: colors.pageAlt) : null;
  };
}

/// 列宽 = 内容自适应，但每条列最多 [maxWidth]，超出的单元格内换行。
///
/// Flutter 自带的 `MaxColumnWidth` 是「取两个宽度的较大者」，没有封顶
/// 语义，所以这里单独实现。
class _CappedIntrinsicColumnWidth extends TableColumnWidth {
  const _CappedIntrinsicColumnWidth(this.maxWidth);

  final double maxWidth;

  static const TableColumnWidth _intrinsic = IntrinsicColumnWidth();

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      math.min(_intrinsic.minIntrinsicWidth(cells, containerWidth), maxWidth);

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      math.min(_intrinsic.maxIntrinsicWidth(cells, containerWidth), maxWidth);
}

/// 表格单列宽度上限：正文可用宽度按列数均分，单列夹在 [min] 与 [max] 之间。
///
/// 2~3 列表格在手机上基本一屏放下；列特别多时单列不低于 [min]，宁可
/// 略微横向滚动也不把字挤成一条；平板/PC 因 [availableWidth] 更大，
/// 单列自然更宽，不需要按端写第二套分支。
double tableColumnCap({
  required double availableWidth,
  required int columns,
  double min = 96,
  double max = 240,
}) {
  if (columns <= 0 || availableWidth <= 0) {
    return max;
  }
  return (availableWidth / columns).clamp(min, max).toDouble();
}

/// 表格组件：按「正文可用宽度 / 列数」给每列分配上限。
///
/// 手机窄屏下，长文本单元格以前会把列撑到内容宽度（整表几千 dp），
/// 必须横向滑很久才能看完。现在每列最多拿到自己那份屏宽。
class _AdaptiveTableComponentBuilder extends MarkdownTableComponentBuilder {
  const _AdaptiveTableComponentBuilder({required this.availableWidth})
      : super(fit: TableComponentFit.scroll);

  /// 正文内容区宽度（已扣掉页面左右页边距）。
  final double availableWidth;

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    final SingleColumnLayoutComponentViewModel? viewModel =
        super.createViewModel(document, node);
    if (viewModel is! MarkdownTableViewModel || node is! TableBlockNode) {
      return viewModel;
    }
    final int columns = node.columnCount;
    if (columns > 0 && availableWidth > 0) {
      viewModel.columnWidth = _CappedIntrinsicColumnWidth(
        tableColumnCap(availableWidth: availableWidth, columns: columns),
      );
    }
    return viewModel;
  }
}

/// 图片长按菜单的动作。
enum _ImageAction { small, large, download, delete }

/// 滚动控制器：把「框架发起的瞬时跳转」交给页面接管。
///
/// super_editor 每次文档变化后会用 `jumpTo` 把光标瞬间抬到视口边界，
/// 这会让逐帧平滑落位失效（表现为「一跳一跳」）。这里只做转发，
/// 是否接管由页面判断（见 `_onExternalCaretJump`）。
class _CaretAwareScrollController extends ScrollController {
  _CaretAwareScrollController();

  /// 返回 true 表示这次跳转已被接管（不再执行原生 jumpTo）。
  bool Function(double target, ScrollPosition position)? onExternalJump;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _CaretAwareScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      onExternalJump: (double target, ScrollPosition position) =>
          onExternalJump?.call(target, position) ?? false,
    );
  }
}

class _CaretAwareScrollPosition extends ScrollPositionWithSingleContext {
  _CaretAwareScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
    required this.onExternalJump,
  });

  final bool Function(double target, ScrollPosition position) onExternalJump;

  @override
  void jumpTo(double value) {
    if (onExternalJump(value, this)) {
      return;
    }
    super.jumpTo(value);
  }

  /// 框架/内核用 `animateTo` 做的自动滚动（如选区保可见）也要接管。
  ///
  /// 之前只拦了 `jumpTo`：键盘收起时内核用 600ms 的 animateTo 把正文
  /// 缓动回顶部，`jumpTo` 拦截完全看不到它，页面就「慢慢下移」。
  /// 交给页面判断：收起窗口内直接吞掉；正常编辑时改走逐帧平滑滚动。
  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    if (onExternalJump(to, this)) {
      return Future<void>.value();
    }
    return super.animateTo(to, duration: duration, curve: curve);
  }
}

/// 历史版本列表：时间 + 体积，点一条进入预览。
class _VersionHistorySheet extends StatelessWidget {
  const _VersionHistorySheet({required this.versions, required this.locked});

  final List<NoteVersion> versions;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 90),
      decoration: BoxDecoration(
        color: colors.page,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      // SafeArea 放在卡片内部：底色一直铺到屏幕最底部（含手势指示器
      // 区域），内容再按底部 insets 避开手势条。之前 SafeArea 包在
      // 卡片外面，手势条位置会漏出一条透明缝（看着像没适配）。
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.lg,
                AppSpace.lg,
                AppSpace.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '历史版本',
                    style: TextStyle(
                      fontSize: AppFontSize.subtitle,
                      fontWeight: AppWeight.semibold,
                      color: colors.text,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    locked ? '锁定笔记的版本不可预览，但仍可恢复' : '恢复前会自动保留当前内容',
                    style: TextStyle(
                      fontSize: AppFontSize.meta,
                      color: colors.tertiary,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: AppSpace.md),
                itemCount: versions.length,
                separatorBuilder: (BuildContext context, int index) => Divider(
                  height: 0.5,
                  thickness: 0.5,
                  indent: AppSpace.lg,
                  endIndent: AppSpace.lg,
                  color: colors.divider,
                ),
                itemBuilder: (BuildContext context, int index) {
                  final NoteVersion version = versions[index];
                  return InkWell(
                    onTap: () => Navigator.of(context).pop(version),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.lg,
                        vertical: AppSpace.md,
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              formatEditorTime(version.time),
                              style: TextStyle(
                                fontSize: AppFontSize.value,
                                color: colors.text,
                              ),
                            ),
                          ),
                          Text(
                            formatFileSize(version.size),
                            style: TextStyle(
                              fontSize: AppFontSize.meta,
                              color: colors.tertiary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: AppIcon.chevron,
                            color: colors.tertiary,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 历史版本预览：普通笔记用阅读态渲染，锁定笔记只给「无法预览」。
class _VersionPreviewSheet extends StatelessWidget {
  const _VersionPreviewSheet({
    required this.note,
    required this.time,
    required this.locked,
  });

  final Note? note;
  final DateTime time;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.75;
    final List<String> blocks = (locked || note == null)
        ? const <String>[]
        : note!.body.split(RegExp(r'\n{2,}'));
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        margin: const EdgeInsets.only(top: 70),
        decoration: BoxDecoration(
          color: colors.page,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
        ),
        // 与历史版本列表同一处理：SafeArea 放进卡片里，底色铺到屏幕底部。
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.lg,
                  AppSpace.lg,
                  AppSpace.sm,
                ),
                child: Text(
                  formatEditorTime(time),
                  style: TextStyle(
                    fontSize: AppFontSize.subtitle,
                    fontWeight: AppWeight.semibold,
                    color: colors.text,
                  ),
                ),
              ),
              Flexible(
                child: locked || note == null
                    ? Padding(
                        padding: const EdgeInsets.all(AppSpace.lg),
                        child: Text(
                          '这条笔记已锁定，历史版本无法预览。',
                          style: TextStyle(
                            fontSize: AppFontSize.value,
                            height: 1.6,
                            color: colors.secondary,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpace.lg,
                          0,
                          AppSpace.lg,
                          AppSpace.md,
                        ),
                        itemCount: blocks.length,
                        itemBuilder: (BuildContext context, int index) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: AppSpace.md),
                            child: MarkdownBlockView(
                              text: blocks[index],
                              baseSize: AppFontSize.summary,
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.sm,
                  AppSpace.lg,
                  AppSpace.lg,
                ),
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('恢复此版本'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
