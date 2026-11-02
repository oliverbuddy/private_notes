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
import '../../theme/app_theme.dart';
import '../../ui/quote_block.dart';
import '../../ui/show_sheet.dart';
import '../../ui/tag_chip.dart';
import '../markdown_toolbar.dart';
import '../link_editor_sheet.dart';
import '../tag_editor_sheet.dart';
import 'kernel_commands.dart';
import '../../util/date_format.dart' show formatEditorTime;
import '../../ui/show_sheet.dart' show showXiaojiSheet, showXiaojiConfirmSheet;
import 'selection_toolbar.dart';
import '../widgets/image_block_view.dart';
import 'attachment_component.dart';
import 'caret_overlay.dart';
import 'editor_request_handlers.dart';
import 'list_style.dart';
import 'tag_style.dart';
import 'task_component.dart';
import 'xiaoji_markdown.dart';

/// M1：跑在 super_editor 内核上的并行编辑页。
///
/// 与旧编辑器（editor_page.dart）并存，不共用任何编辑逻辑。旧编辑器
/// 17 轮迭代沉淀的坑在这里按条规避：
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
  /// MarkdownToolbar 那一小块，不重建整个页面（对齐旧编辑器的做法）。
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

  /// SuperEditor 自己的焦点节点。面板关闭后（选区可能被清空）用
  /// requestFocus 把 IME 和光标一起接回来，避免「键盘在、光标没了」。
  final FocusNode _editorFocus = FocusNode(debugLabel: 'xiaoji-editor');

  /// 底部工具条高度（与 MarkdownToolbar 的 SizedBox 一致）。
  ///
  /// 编辑态要从正文视口里扣掉这一条：工具条是浮层，不参与 Column 布局，
  /// 不预留的话它会盖住正文最后 52dp（用户反馈「工具栏和输入法遮挡内容」）。
  static const double _toolbarHeight = 52;

  /// Android 选择控件接管：内建选择条文案写死英文，这里通过 controller
  /// 的 toolbarBuilder 注入中文胶囊工具条（OverlayManager 优先取它，
  /// 定位/边界避让仍走内核 Follower 体系）。
  late final SuperEditorAndroidControlsController _androidControls =
      SuperEditorAndroidControlsController(
    toolbarBuilder:
        (BuildContext context, Key mobileToolbarKey, LeaderLink focalPoint) =>
            XiaojiSelectionToolbar(
      floatingToolbarKey: mobileToolbarKey,
      focalPoint: focalPoint,
      editorOps: _ops,
      controls: _androidControls,
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
    // 打开时先给 `#标签` 打上显示标记：胶囊由 TagChips 内容层绘制，
    // 文字颜色由 stylesheet 的 inlineTextStyler 接管。
    applyTagAttributions(_document);
    _composer = MutableDocumentComposer();
    _editor = createXiaojiEditor(document: _document, composer: _composer);
    _ops = CommonEditorOperations(
      document: _document,
      editor: _editor,
      composer: _composer,
      documentLayoutResolver: () => throw UnimplementedError('M1 不依赖布局解析器'),
    );
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
        // 这次文本变更的 document 通知已经发出、内容层已排队重建；
        // 在这里补打标签属性，重建时看到的就是新标签（同一帧内完成）。
        // 组词期间先不动，避免和 IME 的 composing 区抢字符。
        if (_composer.composingRegion.value == null) {
          applyTagAttributions(_document);
        }
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
    _caretFollowing = false;
    _caretScrollTarget = null;
    _caretScrollTicker.dispose();
    _disposing = true;
    _flushSave();
    _activeCommands.dispose();
    _editing.dispose();
    _canUndo.dispose();
    _canRedo.dispose();
    _documentEmpty.dispose();
    _editorFocus.dispose();
    _editorScroll.dispose();
    _editor.dispose();
    _composer.dispose();
    _document.dispose();
    _disposed = true;
    super.dispose();
  }

  /// 输入法弹出/收起、屏幕尺寸变化后，可用视口变了，光标可能被挡住。
  ///
  /// 键盘是逐帧动画：每一帧都跟着校正一次（[jumpTo] 跟手），
  /// 内容与键盘同步上升/下降，不会出现「等键盘停稳再滑一下」。
  @override
  void didChangeMetrics() {
    _scheduleCaretFollow();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 800), _flushSave);
  }

  void _flushSave() {
    if (_disposed) {
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
      body: md,
    );
    widget.repository.upsert(_currentNote);
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
    if (_panelTransitioning || _caretFollowing) {
      return;
    }
    _caretVisibilityPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _caretVisibilityPending = false;
      if (_panelTransitioning || _caretFollowing || _disposed) {
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
    if (_disposed || _panelTransitioning) {
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
    if (_panelTransitioning) {
      // 面板/键盘交替期间视口是中间态：任何滚动都会造成「先滑一下、
      // 后面再补一下」的两段式观感。这段过程一律不动。
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
      caret = layoutEditable.documentLayout.getRectForPosition(selection.extent);
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
    // 键盘动画叠加成「先滑一下、停稳后再补一下」。
    if (_panelTransitioning || _caretFollowing) {
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
    _commands.handleCommand(command);
    _refreshActiveCommands();
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
  // 右上角「⋯」笔记操作菜单（旧编辑器同款：置顶/复制文本/编辑标签/删除）
  // ---------------------------------------------------------------------------

  Future<void> _showEditorMenu() async {
    final action = await showXiaojiSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) {
        final sheetColors = AppColors.of(sheetContext);
        Widget tile(IconData icon, String label, String value,
            {Color? foreground}) {
          return InkWell(
            onTap: () => Navigator.of(sheetContext).pop(value),
            child: Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              alignment: Alignment.centerLeft,
              child: Row(
                children: <Widget>[
                  Icon(icon, size: 20, color: foreground ?? sheetColors.text),
                  const SizedBox(width: 14),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      color: foreground ?? sheetColors.text,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              tile(
                _currentNote.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                _currentNote.pinned ? '取消置顶' : '置顶',
                'pin',
              ),
              tile(Icons.content_copy, '复制文本', 'copy'),
              tile(Icons.label_outline, '编辑标签', 'tags'),
              tile(Icons.delete_outline, '删除', 'delete',
                  foreground: sheetColors.danger),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
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
      case 'tags':
        await _editTags();
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

  Future<void> _copyBody() async {
    await Clipboard.setData(
      ClipboardData(text: serializeDocumentToXiaojiMarkdown(_document)),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制到剪贴板')),
      );
    }
  }

  /// 编辑标签：输入框 + 已有标签候选 chips（旧版同款）。
  Future<void> _editTags() async {
    final result = await showTagEditorSheet(
      context: context,
      initialText: _currentNote.tags.join(', '),
      candidates: widget.repository.tags.take(12).toList(),
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
      body: _currentNote.body,
    );
    await widget.repository.upsert(_currentNote);
    // 左下角标签栏读的是 _currentNote，弹层关闭后要立刻反映新的标签。
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '删除这条小记？',
      message: '删除后正文会移到 Xiaoji/trash 目录，附件会一并清掉。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await widget.repository.remove(_currentNote);
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
      _commands.insertImageNode(relative);
    } catch (error) {
      // 图片插入失败不能崩编辑页：提示后照常继续编辑。
      _restoreEditingSelection();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('插入图片失败：$error')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('插入附件失败：$error')),
      );
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
                      final double panelReserve =
                          _toolbarAnchorIme == null
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
                      final bool reserve = imeInset > 0 ||
                          _panelTransitioning ||
                          _panelOpen;
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
                                          fontSize: 15.5,
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
            if (_panelExpanded) _buildPanelSheet(colors),
            // 工具条浮层：贴键盘上沿；空白处 Listener 吞事件，防止穿透
            // 挪光标（旧版实测的坑）。
            _buildToolbar(imeInset),
          ],
        ),
      ),
    );
  }

  /// 子菜单面板：占据原键盘区域，内容贴顶部。
  ///
  /// 高度取展开那一刻的键盘高度，所以贴在它上沿的工具条位置完全不动；
  /// 面板内容固定高度，剩余部分保持页面底色 —— 视觉上就是「键盘被
  /// 面板替换」，点「×」关闭后键盘原位回来，工具栏不跳。
  Widget _buildPanelSheet(AppColors colors) {
    final double sheetHeight = _toolbarAnchorIme ?? 0;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: sheetHeight,
      child: ColoredBox(
        color: colors.page,
        child: Align(
          alignment: Alignment.topCenter,
          child: ValueListenableBuilder<Set<MarkdownCommand>>(
            valueListenable: _activeCommands,
            builder: (
              BuildContext context,
              Set<MarkdownCommand> active,
              _,
            ) {
              return switch (_panel) {
                MarkdownToolbarPanel.textStyle => MarkdownTextStylePanel(
                    active: active,
                    onPick: _runPanelCommand,
                  ),
                MarkdownToolbarPanel.insert => MarkdownInsertPanel(
                    active: active,
                    onPick: (MarkdownCommand command) {
                      // 插入是一次性动作：收面板、回键盘，再执行。
                      _closePanel(showKeyboard: true);
                      _runToolbarCommand(command);
                    },
                  ),
                MarkdownToolbarPanel.attach => MarkdownAttachPanel(
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
            child: tags.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: _AddTagChip(onTap: _editTags),
                  )
                : SingleChildScrollView(
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
      height: 48,
      child: Stack(
        children: <Widget>[
          // 顶栏按旧编辑器逻辑：居中显示更新时间（编辑后实时刷新）。
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
            child: InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              child: SizedBox(
                width: 48,
                child: Icon(
                  Icons.arrow_back_ios_new,
                  size: 22,
                  color: colors.secondary,
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // 撤销 / 重做 / 更多：统一 40dp 槽位 + 22dp 系统图标，
                // 三个按钮等距，和左下角返回箭头同视觉重量；无历史时
                // 撤销/重做置灰但保留占位（不出现左右抖动）。
                AnimatedBuilder(
                  animation: Listenable.merge(<Listenable>[_canUndo, _canRedo]),
                  builder: (BuildContext context, Widget? _) {
                    final bool canUndo = _canUndo.value;
                    final bool canRedo = _canRedo.value;
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        SizedBox(
                          width: 40,
                          child: InkWell(
                            onTap: canUndo ? _editor.undo : null,
                            child: Icon(
                              // 系统内置的撤销/重做字形，尺寸与顶栏其它
                              // 22dp 图标一致（自绘图标的视觉重量对不齐）。
                              Icons.undo,
                              size: 22,
                              color: canUndo ? colors.text : colors.tertiary,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 40,
                          child: InkWell(
                            onTap: canRedo ? _editor.redo : null,
                            child: Icon(
                              Icons.redo,
                              size: 22,
                              color: canRedo ? colors.text : colors.tertiary,
                            ),
                          ),
                        ),
                        // 右上角「⋯」笔记操作菜单（置顶/复制/标签/删除，旧逻辑移植）。
                        SizedBox(
                          width: 40,
                          child: InkWell(
                            onTap: _showEditorMenu,
                            child: Icon(
                              Icons.more_horiz,
                              size: 22,
                              color: colors.text,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditor(AppColors colors) {
    return SuperEditor(
      editor: _editor,
      // 自己持有焦点节点：底部面板关闭后要把焦点/IME 交还编辑器。
      focusNode: _editorFocus,
      // 外部持有滚动控制器：光标被输入法/工具条挡住时要精确滚动（见
      // _ensureCaretVisible），内部自建的控制器拿不到位置。
      scrollController: _editorScroll,
      // 光标/选区/手柄全部走主色，不出现系统默认蓝以外的第二主色。
      selectionStyle: SelectionStyles(
        selectionColor: colors.accent.withValues(alpha: 0.25),
      ),
      androidHandleColor: colors.accent,
      stylesheet: _buildStylesheet(colors),
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
      // `#标签` 的圆角胶囊画在正文下面（文字仍是文档里的真字符，
      // 不替换成 widget，光标偏移/选区/输入都不受影响）。
      documentUnderlayBuilders: const <SuperEditorLayerBuilder>[
        TagChipsUnderlayBuilder(),
      ],
      componentBuilders: <ComponentBuilder>[
        // 相对路径图片解析（assets/… → 真实文件），必须排在默认构建器
        // 之前才能接管 ImageNode；其余组件保持默认链（含 Task）。
        _LabImageComponentBuilder(
          repository: widget.repository,
          editor: _editor,
        ),
        // 分隔线颜色接管：HorizontalRuleComponent 的线色写死 Colors.grey
        // （源码实测，HorizontalRuleComponentViewModel 不透出 color 键，
        // stylesheet 无法配），深色模式下灰线几乎不可见。这里排在默认
        // 构建器前面，用主题 divider 色重建同一个组件。
        const _LabHorizontalRuleComponentBuilder(),
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
        ...defaultComponentBuilders,
        const UnknownComponentBuilder(),
      ],
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
      // `#标签` 文字用主色；胶囊底由 TagChips 内容层画。其余行内样式
      // （粗体/斜体/删除线/行内码/链接）继续走 super_editor 默认实现。
      inlineTextStyler: (
        Set<Attribution> attributions,
        TextStyle existingStyle,
      ) {
        final style = defaultInlineTextStyler(attributions, existingStyle);
        if (attributions.any((Attribution a) => a is TagAttribution)) {
          return style.copyWith(
            color: colors.accent,
            letterSpacing: 0.2,
          );
        }
        return style;
      },
      addRulesAfter: <StyleRule>[
        StyleRule(
          BlockSelector.all,
          (Document doc, DocumentNode node) {
            return <String, dynamic>{
              Styles.textStyle: TextStyle(
                fontSize: 15.5,
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
            };
          },
        ),
        // 文档末尾留白：**只有最后一个块**。之前写在 BlockSelector.all
        // 上，每个块底下都垫了 96，块间隙大到离谱（实测）。
        StyleRule(
          BlockSelector.all.last(),
          (Document doc, DocumentNode node) {
            return <String, dynamic>{
              Styles.padding: const CascadingPadding.only(bottom: 96),
            };
          },
        ),
        // 段落间距收紧（默认 24 太散，手机端要紧凑）。
        // 12 与列表项上下 2 形成「段落明显断开、列表行内轻微呼吸」的层级，
        // 而不是所有块都用同一个大间距（那样看起来每一行都散着）。
        StyleRule(
          const BlockSelector('paragraph'),
          (Document doc, DocumentNode node) => <String, dynamic>{
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
              fontSize: 21,
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
              fontSize: 18.5,
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
              fontSize: 16.5,
              fontWeight: AppWeight.semibold,
              height: 1.3,
              letterSpacing: 0.2,
              leadingDistribution: TextLeadingDistribution.even,
              color: colors.text,
            ),
            Styles.padding: const CascadingPadding.only(top: 14, bottom: 4),
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
        // 代码块：等宽 + 底色。等宽字形比中文正文更宽，13 才与 15px
        // 正文在同一视觉重量上；内边距同步收小，代码块不再「撑满一屏」。
        StyleRule(
          const BlockSelector('code'),
          (Document doc, DocumentNode node) => <String, dynamic>{
            Styles.textStyle: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13.5,
              height: 1.6,
              letterSpacing: 0,
              leadingDistribution: TextLeadingDistribution.even,
              color: colors.text.withValues(alpha: 0.85),
              backgroundColor: colors.surface2,
            ),
            Styles.padding: const CascadingPadding.symmetric(
              vertical: 10,
              horizontal: 16,
            ),
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

  /// 工具条：复用旧编辑器验证过的 [MarkdownToolbar]（布局逻辑零改动），
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
          final bool show =
              editing && (imeInset > 0 || _panelTransitioning);
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
                  child: ValueListenableBuilder<Set<MarkdownCommand>>(
                    valueListenable: _activeCommands,
                    builder:
                        (BuildContext context, Set<MarkdownCommand> active, _) {
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
                          // 选图/选文件会打开系统弹层，按下时冻结选区。
                          onPanelOpening: _onPanelOpening,
                          // 受控模式：面板由页面渲染在工具条下方（原键盘
                          // 区域），工具条本身不移动、不做正文预留。
                          panel: _panel,
                          onPanelToggle: _togglePanel,
                          active: active,
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

/// 「+ 标签」入口：虚线感的描边小胶囊，与真标签同高。
class _AddTagChip extends StatelessWidget {
  const _AddTagChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: colors.chipBorder, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.add, size: 12, color: colors.secondary),
            const SizedBox(width: 2),
            Text(
              '标签',
              style: TextStyle(
                fontSize: 12,
                height: 1,
                fontWeight: AppWeight.medium,
                color: colors.secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 图片点击区：用 [Listener] 而不是 GestureDetector。
///
/// 图片现在承载了 `componentKey`（官方 ImageComponent / BoxComponent），
/// 编辑器自己的选择手势会和 GestureDetector 抢竞技场，导致点击图片
/// 只出现选区手柄、不打开查看器（实测）。Listener 不进竞技场，
/// 按下/抬起位移小于 12、时长小于 500ms 就当作点击，滑动滚动手势不受影响。
class _ImageViewerTapArea extends StatefulWidget {
  const _ImageViewerTapArea({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_ImageViewerTapArea> createState() => _ImageViewerTapAreaState();
}

class _ImageViewerTapAreaState extends State<_ImageViewerTapArea> {
  Offset? _downPosition;
  DateTime? _downAt;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (PointerDownEvent event) {
        _downPosition = event.position;
        _downAt = DateTime.now();
      },
      onPointerUp: (PointerUpEvent event) {
        final Offset? down = _downPosition;
        final DateTime? at = _downAt;
        _downPosition = null;
        _downAt = null;
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
  });

  final NoteRepository repository;
  final Editor editor;

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
    final path = componentViewModel.imageUrl.startsWith('assets/')
        ? componentViewModel.repository.store
            .absoluteAssetPath(componentViewModel.imageUrl)
        : componentViewModel.imageUrl;
    return _ImageViewerTapArea(
      onTap: () {
        // 点图先退出编辑态：否则键盘/选区手柄会在查看器后面挂着。
        editor.execute(<EditRequest>[const ClearSelectionRequest()]);
        _openViewer(
          componentContext,
          path,
          componentViewModel.altText,
        );
      },
      child: Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.block),
          // 必须用官方 ImageComponent 承载 componentKey：查看器的
          // sourceRect 是从这个 key 的 RenderBox 取出来的。之前自己
          // 直接返回 Image.file，componentKey 没挂到任何组件上，
          // currentContext 恒为 null → sourceRect = Rect.zero，
          // 于是「放大动画总是从左上角飞出来」（用户反馈）。
          child: ImageComponent(
            componentKey: componentContext.componentKey,
            imageUrl: path,
            imageBuilder: (BuildContext context, String _) => Image.file(
              File(path),
              fit: BoxFit.cover,
              width: double.infinity,
              // 图挂了不能白屏：errorBuilder 退回占位框，alt 文字可读。
              errorBuilder: (_, __, ___) => _placeholder(componentViewModel),
            ),
          ),
        ),
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
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            vm.altText.isEmpty ? '图片' : vm.altText,
            style: TextStyle(fontSize: 13, color: colors.tertiary),
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
    return _delegate.createViewModel(document, node);
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
}
