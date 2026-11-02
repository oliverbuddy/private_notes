import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../data/note_repository.dart';
import '../data/note_store.dart';
import '../models/note.dart';
import '../theme/app_theme.dart';
import '../ui/show_sheet.dart';
import '../util/date_format.dart';
import 'block.dart';
import 'markdown_controller.dart';
import 'markdown_shortcut_formatter.dart';
import 'markdown_view.dart';
import 'markdown_toolbar.dart';
import 'widgets/file_block_view.dart';
import 'widgets/image_block_view.dart';

/// 编辑页的更多菜单。
enum _EditorMenu { copy, tags, pin, delete }

/// 标签编辑弹层的输入框：TextEditingController 的生命周期归这个 widget。
///
/// 之前的写法是弹层 pop 返回后立刻 dispose 控制器 —— 但 bottom sheet 的
/// pop Future 在**退场动画开始之前**就完成，此刻键盘焦点还在输入框上，
/// TextField 要挂着已销毁的控制器播完 260ms 退场动画，debug 包里直接触发
/// 框架断言崩溃（InheritedElement `_dependents.isEmpty`，取消/保存两条路
/// 都炸）。控制器跟着 widget 走、随弹层树销毁，时序天然正确。
///
/// [external] 是候选 chips 的回填通道：chips 只写 [ValueNotifier.value]，
/// 这里监听并同步到控制器（光标移到末尾，接着打字顺理成章）。
class _TagInputField extends StatefulWidget {
  const _TagInputField({
    required this.initialText,
    required this.external,
    required this.onChanged,
  });

  final String initialText;
  final ValueNotifier<String> external;
  final ValueChanged<String> onChanged;

  @override
  State<_TagInputField> createState() => _TagInputFieldState();
}

class _TagInputFieldState extends State<_TagInputField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void initState() {
    super.initState();
    widget.external.addListener(_onExternal);
  }

  void _onExternal() {
    if (widget.external.value == _controller.text) {
      return;
    }
    _controller.value = TextEditingValue(
      text: widget.external.value,
      selection: TextSelection.collapsed(offset: widget.external.value.length),
    );
  }

  @override
  void dispose() {
    widget.external.removeListener(_onExternal);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return TextField(
      controller: _controller,
      autofocus: true,
      onChanged: widget.onChanged,
      style: TextStyle(fontSize: 15, color: colors.text),
      decoration: InputDecoration(
        hintText: '逗号分隔，例如：旅行, 想法',
        hintStyle: TextStyle(fontSize: 13.5, color: colors.tertiary),
        border: InputBorder.none,
      ),
    );
  }
}

/// 「已有标签」区里的单个候选 chip：点一下在输入文本里增删该标签。
class _TagCandidateChip extends StatelessWidget {
  const _TagCandidateChip({
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: selected ? colors.accentBg : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(
            color: selected ? colors.chipBorderSelected : colors.chipBorder,
            width: 0.5,
          ),
        ),
        child: Center(
          widthFactor: 1,
          child: Text(
            '#$label',
            style: TextStyle(
              fontSize: 13,
              height: 1,
              color: selected ? colors.accent : colors.secondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部常驻标签栏里的单个标签 chip。
class _BottomTagChip extends StatelessWidget {
  const _BottomTagChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.accentBg,
          borderRadius: BorderRadius.circular(AppRadius.chip),
        ),
        child: Text(
          '#$label',
          style: TextStyle(
            fontSize: 13,
            height: 1,
            color: colors.accent,
          ),
        ),
      ),
    );
  }
}

/// 块列表里的一项：块模型 + 它可能持有的编辑资源。
///
/// 文本块有 controller/focusNode，图片和文件块没有 —— 它们由真正的 widget 渲染。
class _BlockEntry {
  _BlockEntry(this.block);

  final Block block;
  MarkdownEditingController? controller;
  FocusNode? focus;

  /// 编辑态 TextField 的锚点：阅读态点击进编辑时，靠它找到
  /// [RenderEditable] 把光标定位到点击位置（见 [_enterEdit]）。
  final GlobalKey fieldKey = GlobalKey();

  /// 上一次的文本，用来识别「回车落在块尾」和「删掉最后一个字符」这两个动作。
  String lastText = '';
}

/// 编辑历史里的一帧：整篇正文 + 光标位置。
///
/// 存的是**块结构**而不是拼接后的 markdown：两个相邻的文本块在 markdown 里
/// 就是一个换行，拼起来再解析回来会糊成一块（撤销一次，光标就跑到上一段去了）。
class _EditorSnapshot {
  const _EditorSnapshot({
    required this.blocks,
    required this.focusedTextOrdinal,
    required this.caret,
  });

  final List<_BlockSnapshot> blocks;

  /// 聚焦的是第几个文本块（-1 = 浏览态）。
  final int focusedTextOrdinal;

  /// 聚焦块内的光标偏移。
  final int caret;
}

enum _BlockKind { text, image, file }

/// 单块的快照（图片/附件只存引用信息，不动磁盘上的文件）。
class _BlockSnapshot {
  const _BlockSnapshot.text(this.text)
      : kind = _BlockKind.text,
        name = '',
        path = '',
        alt = '',
        trailing = '';

  const _BlockSnapshot.image({
    required this.path,
    required this.alt,
    required this.trailing,
  })  : kind = _BlockKind.image,
        text = '',
        name = '';

  const _BlockSnapshot.file({
    required this.name,
    required this.path,
    required this.trailing,
  })  : kind = _BlockKind.file,
        text = '',
        alt = '';

  final _BlockKind kind;
  final String text;
  final String name;
  final String path;
  final String alt;
  final String trailing;

  Block toBlock() {
    switch (kind) {
      case _BlockKind.text:
        return TextBlock(text);
      case _BlockKind.image:
        return ImageBlock(alt: alt, path: path, trailing: trailing);
      case _BlockKind.file:
        return FileBlock(name: name, path: path, trailing: trailing);
    }
  }
}

/// 编辑页。
///
/// 没有保存按钮：随手记的核心体验是「写完就走」，任何显式保存都是打断。
/// 停手 600ms 落盘，页面退出再补一次，空内容的新笔记直接丢弃。
class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.repository,
    this.note,
  });

  final NoteRepository repository;

  /// 为空表示新建。
  final Note? note;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  static const Duration _saveDebounce = Duration(milliseconds: 600);

  /// 工具条出入场动画时长（滑入/淡入共用）。
  static const Duration _toolbarAnimation = Duration(milliseconds: 220);

  /// 顶栏高度。
  static const double _headerHeight = 48;

  /// 底部编辑工具条高度（与 MarkdownToolbar 的 SizedBox 保持一致）。
  static const double _toolbarHeight = 52;

  /// 底部常驻标签栏高度（不含安全区）。
  static const double _tagBarHeight = 40;

  final List<_BlockEntry> _entries = <_BlockEntry>[];
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _imagePicker = ImagePicker();

  NoteStore get _store => widget.repository.store;

  late String _id;
  late DateTime _created;
  late DateTime _updated;
  late DateTime _headerTime;
  List<String> _tags = <String>[];
  bool _pinned = false;

  /// 是否已经在磁盘上留下过文件。用来判断「空内容的新笔记不落盘」。
  bool _persisted = false;

  /// 用户主动删除后，dispose 不能再把笔记写回去。
  bool _discarded = false;

  /// 有「还没落盘的改动」。
  ///
  /// dispose 补写时靠它决定要不要刷新 `updated`：只是打开看一眼再退出，
  /// 不该把笔记顶到列表最前面。
  bool _dirty = false;

  /// 当前处于编辑中的块（单态块混合，语雀式）。
  ///
  /// null = 浏览：所有文本块按渲染态呈现（记号剔除、待办可勾选）；
  /// 非 null = 只有这一块是 TextField，其余块保持渲染。点哪块编哪块，
  /// 收起键盘回到浏览 —— 不再有「阅读/编辑」双态和「完成」按钮。
  /// 渲染/编辑的切换只是同一 entry 换 widget，controller 常驻不销毁。
  _BlockEntry? _focusedEntry;

  /// 程序化改写 controller 时屏蔽监听器，否则会被误判成用户输入。
  bool _suppressed = false;

  Timer? _saveTimer;

  /// 工具条激活态。单独用 notifier 而不是 setState，
  /// 是为了让选区变化只重建工具条那一行，不重建整个块列表。
  final ValueNotifier<Set<MarkdownCommand>> _activeCommands =
      ValueNotifier<Set<MarkdownCommand>>(<MarkdownCommand>{});

  /// 光标所在行的字号（随标题级别变化）。光标高度用它 ×0.95，
  /// 让光标始终与当前行的文字等高 —— 编辑标题时光标不再是正文字号。
  final ValueNotifier<double> _cursorFontSize =
      ValueNotifier<double>(MarkdownEditingController.baseFontSize);

  /// 最后一次真正获得焦点的块。
  ///
  /// 打开标题/列表面板会让 TextField 失焦，如果这时按「谁在聚焦」去找目标块，
  /// 就会退回到文末，命令会改到错误的段落上。所以记一份。
  _BlockEntry? _lastFocused;

  // ---------------------------------------------------------------------------
  // 撤销 / 重做
  // ---------------------------------------------------------------------------

  /// 撤销栈上限。再多的历史在手机上也没人翻得到，反而占内存。
  static const int _undoLimit = 60;

  /// 连续打字合并成一步的窗口：停顿超过这个时长才另起一个历史节点。
  static const Duration _undoCoalesce = Duration(milliseconds: 800);

  final List<_EditorSnapshot> _undoStack = <_EditorSnapshot>[];
  final List<_EditorSnapshot> _redoStack = <_EditorSnapshot>[];

  /// 「上一次改动完成后」的快照。
  ///
  /// controller 的监听器是在文本**已经变了之后**才被调用，现场再抓就抓不到
  /// 改动前的状态了。所以每次改动结束都预存一份，下一次需要压栈时直接用它。
  _EditorSnapshot? _pendingSnapshot;

  DateTime _lastUndoAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 上一个历史节点是结构性改动（回车 / 合并 / 格式命令）。
  ///
  /// 结构改动之后紧接着的打字必须另起一步，否则「回车后打了一段字」再撤销，
  /// 会连回车一起退掉（用户实测：撤销把光标退到了上一段开头）。
  bool _coalesceBlocked = false;

  /// 正在一次 [_beginMutation] … [_endMutation] 之间。
  /// 合并块这类「可能被文本改动触发、也可能被硬件键盘触发」的动作靠它判断
  /// 要不要自己补一个撤销点。
  bool _mutationOpen = false;

  final ValueNotifier<bool> _canUndo = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _canRedo = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    final note = widget.note;
    _id = note?.id ?? Note.generateId(DateTime.now());
    _created = note?.created ?? DateTime.now();
    _updated = note?.updated ?? _created;
    _headerTime = _updated;
    _tags = <String>[...?note?.tags];
    _pinned = note?.pinned ?? false;
    _persisted = note != null;

    for (final block in parseBlocks(note?.body ?? '')) {
      _entries.add(_entryFor(block));
    }
    // 新建笔记自动聚焦第一块开写；已有笔记先浏览（语雀同款）。
    if (note == null && _entries.isNotEmpty) {
      _focusedEntry = _entries.first;
    }
    _ensureTrailingTextBlock();
    _pendingSnapshot = _captureSnapshot();

    // 新建笔记要把输入法顶起来。不能用 TextField 的 autofocus：它在路由动画
    // 进行中（或进程冷启动时）会先抢到焦点，导致后续 requestFocus 不再触发 IME。
    // 所以等路由动画基本结束再主动要焦点一次。
    if (note == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future<void>.delayed(const Duration(milliseconds: 260), () {
          if (!mounted) {
            return;
          }
          final first = _entries.isEmpty ? null : _entries.first;
          first?.focus?.requestFocus();
        });
      });
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();

    // 页面退出时补一次落盘。先算好快照再把 controller 销毁，顺序不能反。
    // 只有存在未落盘改动时才刷新 updated：用户在 600ms 防抖窗口内打完字
    // 直接返回，内容存对了但 updated 不变的话，列表里这条不会浮到顶部。
    final snapshot = _buildSnapshot(
      updatedOverride: _dirty ? DateTime.now() : null,
    );
    for (final entry in _entries) {
      entry.controller?.dispose();
      entry.focus?.dispose();
    }
    _scrollController.dispose();
    _activeCommands.dispose();
    _cursorFontSize.dispose();
    _canUndo.dispose();
    _canRedo.dispose();

    if (snapshot != null) {
      // 路由正在销毁，用微任务把 notifyListeners 推到当前调用栈之后，
      // 避免在 build/析构期间触发重建。
      scheduleMicrotask(() {
        widget.repository.upsert(snapshot);
      });
    }

    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 块的生命周期
  // ---------------------------------------------------------------------------

  _BlockEntry _entryFor(Block block) {
    if (block is TextBlock) {
      return _createTextEntry(block.text, block: block);
    }
    return _BlockEntry(block);
  }

  _BlockEntry _createTextEntry(String text, {TextBlock? block}) {
    final entry = _BlockEntry(block ?? TextBlock(text));
    final controller = MarkdownEditingController(text: text);
    final node = FocusNode(debugLabel: 'xiaoji-block');
    entry.controller = controller;
    entry.focus = node;
    entry.lastText = text;

    controller.addListener(() => _handleTextChange(entry));
    // 选区变化也要刷新工具条激活态，但只在集合真的变了才通知，
    // 否则每个按键都会重建一次工具条。
    controller.addListener(_refreshActiveCommands);
    node.addListener(() {
      if (node.hasFocus) {
        _lastFocused = entry;
        _ensureVisible(entry);
        // 获得焦点时刷新光标行字号：_focusEntry 的 postFrame 里
        // _updateCursorFontSize 跑在 hasFocus 生效之前，会拿到「无聚焦」
        // 的过时状态（真机上表现为标题行光标一直是正文尺寸，用户实测）。
        // 焦点真正落地后再刷一次才可靠。
        _updateCursorFontSize();
        // 撤销点跟着焦点走：撤销回到「还没点进来」的那一帧会把用户
        // 踢回浏览态，这里让快照始终带着「当前在编哪一块」。
        _pendingSnapshot = _captureSnapshot();
      }
    });
    node.onKeyEvent =
        (FocusNode target, KeyEvent event) => _handleHardwareKey(event, entry);
    return entry;
  }

  /// 硬件键盘（iPad / 桌面）的退格需要单独处理：
  /// 软键盘的删除走文本增量，而空块上的退格根本不会产生增量事件。
  KeyEventResult _handleHardwareKey(KeyEvent event, _BlockEntry entry) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    // 外接键盘 / 桌面端的撤销重做（Android 手机上没有这些键，不影响）。
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyZ &&
        (keyboard.isControlPressed || keyboard.isMetaPressed)) {
      if (keyboard.isShiftPressed) {
        _redo();
      } else {
        _undo();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    final controller = entry.controller;
    if (controller == null) {
      return KeyEventResult.ignored;
    }
    final selection = controller.selection;
    if (!selection.isCollapsed || selection.baseOffset != 0) {
      return KeyEventResult.ignored;
    }
    final index = _entries.indexOf(entry);
    if (index <= 0) {
      return KeyEventResult.ignored;
    }
    _mergeIntoPrevious(index);
    return KeyEventResult.handled;
  }

  void _handleTextChange(_BlockEntry entry) {
    if (_suppressed) {
      return;
    }
    final controller = entry.controller;
    if (controller == null) {
      return;
    }
    final text = controller.text;

    // 只有选区变了（点一下光标、选中一段）：这不是编辑，不能标记成改动 ——
    // 否则「点进详情看一眼再退出」也会把 updated 刷新成现在，笔记无缘无故
    // 跳到列表最前面（用户实测反馈）。
    if (text == entry.lastText) {
      return;
    }

    final oldText = entry.lastText;
    final int oldLineCount = oldText.split('\n').length;
    final int newLineCount = text.split('\n').length;
    // 结构性改动（回车拆块、删掉一整行）各占一步历史；普通打字按时间窗口合并。
    _beginMutation(force: newLineCount != oldLineCount);
    try {
      // 回车换行：按「字符级前后缀对齐」定位这次真正插入的片段。
      //
      // 为什么不用行级 diff：中文输入法会把「组词上屏 + 换行」合成一次批量
      // 更新，自动更正还会改掉已经输入的字符，行级比较在这种批量提交下会
      // 错位（用户实测「列表续号时灵时不灵」）。字符级对齐只关心「插入片段
      // 里有没有换行」，与提交方式无关。
      if (text.length > oldText.length) {
        var prefix = 0;
        final int prefixLimit =
            oldText.length < text.length ? oldText.length : text.length;
        while (prefix < prefixLimit && oldText[prefix] == text[prefix]) {
          prefix++;
        }
        var suffix = 0;
        while (suffix < oldText.length - prefix &&
            suffix < text.length - prefix &&
            oldText[oldText.length - 1 - suffix] ==
                text[text.length - 1 - suffix]) {
          suffix++;
        }
        final inserted = text.substring(prefix, text.length - suffix);
        final newlineAt = inserted.indexOf('\n');
        // 代码围栏里回车 = 块内换行：拆块会把围栏劈成两半，读态整段错渲染。
        if (newlineAt >= 0 && !_isInsideOpenFence(text, prefix + newlineAt)) {
          // 光标前的内容留在本块，光标后的全部搬到新块。
          var left = text.substring(0, prefix + newlineAt);
          // 光标落在行首时，左半会带着上一行的行尾换行 —— 那是用户刚敲出来的
          // 空行，留给新块当续号的落点；留在左半会让渲染多出一条空白。
          if (left.endsWith('\n')) {
            left = left.substring(0, left.length - 1);
          }
          final right = text.substring(prefix + newlineAt + 1);
          final index = _entries.indexOf(entry);
          final next = continuationFor(left);
          var kept = next.strippedBlock;
          if (kept.endsWith('\n')) {
            kept = kept.substring(0, kept.length - 1);
          }
          // 空的列表项再回车 = 退出列表：本块去掉记号就够了，别再插一个空块，
          // 否则「1. aaa / 回车 / 回车 / 继续写」会在正文里凭空多一个空行。
          if (right.isEmpty && next.initialText.isEmpty && kept != left) {
            _applyProgrammatic(
              entry,
              kept,
              selection: TextSelection.collapsed(offset: kept.length),
            );
            _renumberOrderedLists();
            _scheduleSave();
            return;
          }
          _applyProgrammatic(
            entry,
            kept,
            selection: TextSelection.collapsed(offset: kept.length),
          );
          // 右边本身就是一个新行块（列表项/标题/引用）时另起一行：直接把记号
          // 拼上去会得到「4. 4. xxx」这种双重编号。
          final String initial;
          if (right.isEmpty) {
            initial = next.initialText;
          } else if (_startsBlockMarker(right)) {
            initial = next.initialText.isEmpty
                ? right
                : '${next.initialText}\n$right';
          } else {
            initial = '${next.initialText}$right';
          }
          _insertTextBlockAt(
            index + 1,
            initial: initial,
            caret: next.initialText.isEmpty ? null : next.initialText.length,
          );
          // 中间插了一行 → 后面各项的有序列表编号依次顺延。
          _renumberOrderedLists();
          _scheduleSave();
          return;
        }
      }

      // 删掉最后一个字符后块为空：并进上一块，避免留下无法输入的空块。
      if (text.isEmpty && oldText.length == 1) {
        final index = _entries.indexOf(entry);
        if (index > 0) {
          _mergeIntoPrevious(index);
          return;
        }
      }

      // 把列表项的记号删光后，这一行要整行移除（连同换行），不能留一条
      // 空白 —— 空行会把有序列表的编号组打断，变成「7. xxx / 空行 / 9. xxx」，
      // 后面的编号也不再顺延（用户实测）。普通段落删空则保留空行：
      // 那可能是用户想空一行继续写。判定「这行只剩记号」用整行匹配，
      // 这样 `9.` 这种删到一半的编号也算。
      if (newLineCount == oldLineCount && text.isNotEmpty) {
        final cleanup = _removeEmptiedMarkerLines(
          oldText,
          text,
          controller.selection,
        );
        if (cleanup != null) {
          _applyProgrammatic(
            entry,
            cleanup.$1,
            selection: TextSelection.collapsed(offset: cleanup.$2),
          );
          _renumberOrderedLists();
          _scheduleSave();
          return;
        }
      }

      final block = entry.block;
      if (block is TextBlock) {
        block.text = text;
      }
      entry.lastText = text;
      // 删掉整行（退格删空一个列表项）：后面的编号要顺延回来。
      if (newLineCount < oldLineCount) {
        _renumberOrderedLists();
      }
      _scheduleSave();
    } finally {
      _endMutation();
    }
  }

  /// 光标是否处在一个**没闭合**的代码围栏里（```）。
  static bool _isInsideOpenFence(String text, int index) {
    if (index <= 0) {
      return false;
    }
    var fences = 0;
    for (final line in text.substring(0, index).split('\n')) {
      if (line.trimLeft().startsWith('```')) {
        fences++;
      }
    }
    return fences.isOdd;
  }

  /// 这一行是否以块级记号开头（列表项 / 标题 / 引用）。
  static bool _startsBlockMarker(String line) {
    return RegExp(r'^\s*(?:[-*+]\s|\d+[.)]\s|>|#{1,6}\s)').hasMatch(line);
  }

  /// 整行只剩块级记号（含删到一半的编号，如 `9`、`9.`、`- `、`## `）。
  static final RegExp _bareMarkerLinePattern = RegExp(
    r'^\s*(?:#{1,6}\s*|>\s*|[-*+]\s\[[ xX]\]\s*|[-*+]\s*|\d+[.)]?\s*)$',
  );

  /// 找出这次编辑里被删空的记号行并整行移除。
  ///
  /// 返回 `(清理后的文本, 光标位置)`；没有可清理的行返回 null。
  /// 判定用「旧行整行只剩记号 && 新行为空」，普通段落删空不受影响。
  static (String, int)? _removeEmptiedMarkerLines(
    String oldText,
    String newText,
    TextSelection selection,
  ) {
    final oldLines = oldText.split('\n');
    final newLines = newText.split('\n');
    if (oldLines.length != newLines.length) {
      return null;
    }

    final emptied = <int>[];
    for (var i = 0; i < newLines.length; i++) {
      if (newLines[i].isEmpty &&
          oldLines[i].isNotEmpty &&
          _bareMarkerLinePattern.hasMatch(oldLines[i])) {
        emptied.add(i);
      }
    }
    if (emptied.isEmpty) {
      return null;
    }

    final kept = List<String>.of(newLines);
    // 从后往前删，前面的下标不受影响。
    for (final i in emptied.reversed) {
      kept.removeAt(i);
    }
    final result = kept.join('\n');

    // 光标放到第一个被删行的原位置（它之前的行都原样保留）。
    var caret = 0;
    final first = emptied.first;
    for (var j = 0; j < first; j++) {
      caret += newLines[j].length + 1;
    }
    return (
      result,
      caret.clamp(0, result.length),
    );
  }

  /// 行首的块级记号：标题、引用、待办、无序列表、有序列表。
  ///
  /// 工具栏是**切换块类型**，不是往里叠记号。所以每次改类型前先把已有的
  /// 全部剥掉 —— 否则把「> 21. 内容」改成无序列表会得到 `-> 21. 内容`
  /// 这种残渣（用户实测），标题也会变成「## > 21. 内容」的堆叠。
  static final RegExp _blockPrefixPattern = RegExp(
    r'^(?:#{1,6}\s+|>\s?|[-*+]\s\[[ xX]\]\s*|[-*+]\s+|\d+[.)]\s+)',
  );

  /// 剥掉行首所有块级记号，返回纯正文（缩进与内容原样保留）。
  static String _stripBlockPrefixes(String line) {
    var rest = line;
    // 循环剥：`- [ ] `、`## > ` 这类复合前缀要一层层去掉。
    while (true) {
      final match = _blockPrefixPattern.firstMatch(rest);
      if (match == null || match.end == 0) {
        return rest;
      }
      rest = rest.substring(match.end);
    }
  }

  /// 这一行当前是否**已经是** [marker] 代表的块类型。
  ///
  /// 用类型判断而不是字符串相等：有序列表的编号会变（`3. ` 不等于 `1. `），
  /// 但「再点一次有序列表」的语义仍然是取消。
  static bool _hasBlockPrefixOfKind(String line, String marker) {
    if (marker.startsWith('#')) {
      return RegExp(r'^\s*#{1,6}\s+').hasMatch(line);
    }
    if (marker.startsWith('>')) {
      return RegExp(r'^\s*>\s?').hasMatch(line);
    }
    if (marker.contains('[')) {
      return RegExp(r'^\s*[-*+]\s\[[ xX]\]').hasMatch(line);
    }
    if (RegExp(r'^\d').hasMatch(marker)) {
      return RegExp(r'^\s*\d+[.)]\s').hasMatch(line);
    }
    // 无序列表：待办不算（否则待办行点「列表」会被当成同一类型直接取消）。
    return RegExp(r'^\s*[-*+]\s').hasMatch(line) &&
        !RegExp(r'^\s*[-*+]\s\[[ xX]\]').hasMatch(line);
  }

  /// 重排全文的有序列表编号。
  ///
  /// 在中间插入一行或删掉一行后，后面各项的编号必须依次顺延，否则会出现
  /// `1. 2. 3. 3. 4.` 这种断号（用户实测反馈）。改写只发生在相邻的列表行
  /// 之间：空行、普通段落、图片/附件块都会断开一组，绝不改远处的内容。
  void _renumberOrderedLists() {
    final cursor = OrderedListNumberingCursor();
    for (final entry in _entries) {
      final controller = entry.controller;
      if (entry.block is! TextBlock || controller == null) {
        cursor.reset();
        continue;
      }
      final oldText = controller.text;
      final result = cursor.apply(oldText);
      if (result == null) {
        continue;
      }
      final selection = controller.selection;
      final caret = selection.isValid
          ? _mapCaretThroughNumbering(oldText, result, selection.baseOffset)
          : result.text.length;
      _applyProgrammatic(
        entry,
        result.text,
        selection: TextSelection.collapsed(
          offset: caret.clamp(0, result.text.length),
        ),
      );
    }
  }

  /// 把光标从「编号重排前」映射到「重排后」：只按该行数字长度的变化平移，
  /// 落在数字中间的光标贴到新数字末尾。
  static int _mapCaretThroughNumbering(
    String oldText,
    OrderedListNumbering result,
    int caret,
  ) {
    final lines = oldText.split('\n');
    var lineStart = 0;
    var shift = 0;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final change = result.numberChanges[i];
      if (caret <= lineStart + line.length) {
        if (change == null) {
          return caret + shift;
        }
        final indent = RegExp(r'^\s*').firstMatch(line)?.group(0)?.length ?? 0;
        final (oldLength, newLength) = change;
        final delta = newLength - oldLength;
        if (caret - lineStart >= indent + oldLength) {
          return caret + shift + delta;
        }
        return lineStart + shift + indent + newLength;
      }
      if (change != null) {
        shift += change.$2 - change.$1;
      }
      lineStart += line.length + 1;
    }
    return caret + shift;
  }

  /// 程序化改写某个块的文本，同时同步块模型。
  void _applyProgrammatic(
    _BlockEntry entry,
    String text, {
    TextSelection? selection,
    bool focus = false,
  }) {
    final controller = entry.controller;
    if (controller == null) {
      return;
    }
    _suppressed = true;
    controller.value = TextEditingValue(
      text: text,
      selection: selection ?? TextSelection.collapsed(offset: text.length),
    );
    _suppressed = false;

    final block = entry.block;
    if (block is TextBlock) {
      block.text = text;
    }
    entry.lastText = text;

    if (focus) {
      _requestFocus(entry);
    }
  }

  void _requestFocus(_BlockEntry entry) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final node = entry.focus;
      if (node == null) {
        return;
      }
      // 走 FocusScope 而不是 node.requestFocus()：
      // 分块时新旧两个 TextField 会同时存在一帧，直接 requestFocus 偶尔会
      // 让两个节点都认为自己有焦点，屏幕上就出现两根光标。
      FocusScope.of(context).requestFocus(node);
      _ensureVisible(entry);
    });
  }

  void _insertTextBlockAt(int index, {String initial = '', int? caret}) {
    final entry = _createTextEntry(initial);
    entry.controller?.selection = TextSelection.collapsed(
      offset: (caret ?? initial.length).clamp(0, initial.length),
    );
    final bounded = index.clamp(0, _entries.length);
    setState(() {
      _entries.insert(bounded, entry);
      // 单态：新块接管聚焦（否则它会被渲染成只读视图，回车续号看着「没生效」）。
      _focusedEntry = entry;
    });
    _requestFocus(entry);
  }

  void _mergeIntoPrevious(int index) {
    if (index <= 0 || index >= _entries.length) {
      return;
    }
    // 硬件键盘在行首退格走的是这条路，没有外层的 [_beginMutation]。
    if (!_mutationOpen) {
      _pushUndoNow();
    }
    _BlockEntry? target;
    for (var i = index - 1; i >= 0; i--) {
      if (_entries[i].block is TextBlock) {
        target = _entries[i];
        break;
      }
    }

    final removed = _entries[index];
    final controller = removed.controller;
    final node = removed.focus;
    final removedText = controller?.text ?? '';
    final wasFocused =
        identical(_focusedEntry, removed) || (removed.focus?.hasFocus ?? false);
    setState(() {
      _entries.removeAt(index);
      // 被合并掉的块如果正拿着焦点，必须把焦点交给上一块 —— 否则这一块
      // 不再是 TextField，静默失去焦点：键盘收起、光标消失，用户被踢出编辑
      // （实测：退格删掉「4. 」这种空列表项时必现）。
      if (wasFocused) {
        _focusedEntry = target;
      }
    });

    // 不能在 controller 自己的通知回调里同步 dispose，推到微任务里做。
    scheduleMicrotask(() {
      controller?.dispose();
      node?.dispose();
    });

    final targetController = target?.controller;
    if (target != null && targetController != null) {
      // 真的把内容并进上一块：硬件键盘在行首按退格时，之前直接丢掉整块
      // 文本（数据丢失）。块之间本来就是一个换行，合并时补回来。
      final base = targetController.text;
      final String merged;
      if (removedText.isEmpty) {
        merged = base;
      } else if (base.isEmpty) {
        merged = removedText;
      } else {
        merged = '$base\n$removedText';
      }
      _applyProgrammatic(
        target,
        merged,
        selection: TextSelection.collapsed(offset: base.length),
      );
      if (wasFocused) {
        _requestFocus(target);
      }
    }
    _renumberOrderedLists();
    _scheduleSave();
    _endMutation();
  }

  /// 保证文末永远有一个可以打字的文本块（否则最后一块是图片就无处输入）。
  void _ensureTrailingTextBlock() {
    if (_entries.isEmpty) {
      _entries.add(_createTextEntry(''));
      return;
    }
    if (_entries.last.block is! TextBlock) {
      _entries.add(_createTextEntry(''));
    }
  }

  /// 当前聚焦的文本块下标。
  int _focusedTextIndex() {
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (entry.block is TextBlock && (entry.focus?.hasFocus ?? false)) {
        return i;
      }
    }
    // 焦点被弹层或气泡拿走时，用最后聚焦的块 —— 直接退到文末会把命令
    // 打到另一个段落上（打开标题面板后就改错行，是很容易漏掉的 bug）。
    final last = _lastFocused;
    if (last != null) {
      final index = _entries.indexOf(last);
      if (index >= 0) {
        return index;
      }
    }
    for (var i = _entries.length - 1; i >= 0; i--) {
      if (_entries[i].block is TextBlock) {
        return i;
      }
    }
    return _entries.length - 1;
  }

  _BlockEntry? _focusedTextEntry() {
    final index = _focusedTextIndex();
    if (index < 0 || index >= _entries.length) {
      return null;
    }
    final entry = _entries[index];
    return entry.block is TextBlock ? entry : null;
  }

  /// 保证**光标那一行**在可视区里（不是整块）。
  ///
  /// 为什么不能用块的矩形：磁盘上的笔记通常只有一个大 TextBlock（几十行
  /// 都在同一块里），它比视口还高 —— 块顶永远在视口上方。按「块顶要可见」
  /// 去滚，每次请求焦点都会把页面一路滚到这块的开头，用户看到的就是
  /// 「删掉列表里的一行 / 点一下正文，页面跳到最上面」（实测 rect 从 -320
  /// 开始、topLimit 56，一次滚 -376）。
  ///
  /// 所以只看光标：光标已经在可视区里就一点不滚（这点很重要，任何
  /// 「顺手校正一下」都会让正在看的位置漂移）；只有被键盘/工具栏挡住、
  /// 或被顶栏压住时，才滚最小距离。
  void _ensureVisible(_BlockEntry entry) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      final node = entry.focus;
      final fieldContext = entry.fieldKey.currentContext;
      if (node == null || fieldContext == null || !fieldContext.mounted) {
        return;
      }
      final media = MediaQuery.of(context);
      final keyboardInset = media.viewInsets.bottom;
      final visibleBottom = media.size.height -
          keyboardInset -
          (keyboardInset > 0 ? _toolbarHeight : 0) -
          media.padding.bottom -
          12;
      final topLimit = media.padding.top + _headerHeight + 8;

      final caret = _caretRectInGlobal(entry, fieldContext);
      final double delta;
      if (caret != null) {
        if (caret.bottom > visibleBottom) {
          delta = caret.bottom - visibleBottom;
        } else if (caret.top < topLimit) {
          delta = caret.top - topLimit;
        } else {
          return;
        }
      } else {
        // 拿不到光标矩形（罕见的时序）：只在**整块完全不可见**时兜底。
        // 块部分可见就算可见 —— 大块场景下退回块级判断会重现跳顶。
        final renderObject = node.context?.findRenderObject();
        if (renderObject is! RenderBox || !renderObject.attached) {
          return;
        }
        final rect =
            renderObject.localToGlobal(Offset.zero) & renderObject.size;
        if (rect.top > visibleBottom) {
          delta = rect.top - visibleBottom;
        } else if (rect.bottom < topLimit) {
          delta = rect.bottom - topLimit;
        } else {
          return;
        }
      }

      final position = _scrollController.position;
      final next = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((next - position.pixels).abs() < 1) {
        return;
      }
      _scrollController.animateTo(
        next,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  /// 光标在当前块里的全局矩形；拿不到渲染对象时返回 null。
  Rect? _caretRectInGlobal(_BlockEntry entry, BuildContext fieldContext) {
    final editable = _findRenderEditable(fieldContext.findRenderObject());
    final controller = entry.controller;
    if (editable == null || !editable.attached || controller == null) {
      return null;
    }
    final selection = controller.selection;
    final offset =
        (selection.isValid ? selection.extentOffset : controller.text.length)
            .clamp(0, editable.plainText.length);
    final local = editable.getLocalRectForCaret(TextPosition(offset: offset));
    final origin = editable.localToGlobal(local.topLeft);
    return Rect.fromLTWH(origin.dx, origin.dy, local.width, local.height);
  }

  // ---------------------------------------------------------------------------
  // 撤销 / 重做
  // ---------------------------------------------------------------------------

  _EditorSnapshot _captureSnapshot() {
    final blocks = <_BlockSnapshot>[];
    var ordinal = -1;
    var caret = 0;
    var textIndex = 0;
    for (final entry in _entries) {
      final block = entry.block;
      if (block is TextBlock) {
        blocks.add(_BlockSnapshot.text(entry.controller?.text ?? block.text));
        if (identical(entry, _focusedEntry)) {
          ordinal = textIndex;
          final selection = entry.controller?.selection;
          caret = (selection != null && selection.isValid)
              ? selection.baseOffset
              : (entry.controller?.text.length ?? 0);
        }
        textIndex++;
      } else if (block is ImageBlock) {
        blocks.add(_BlockSnapshot.image(
          path: block.path,
          alt: block.alt,
          trailing: block.trailing,
        ));
      } else if (block is FileBlock) {
        blocks.add(_BlockSnapshot.file(
          name: block.name,
          path: block.path,
          trailing: block.trailing,
        ));
      }
    }
    return _EditorSnapshot(
      blocks: blocks,
      focusedTextOrdinal: ordinal,
      caret: caret,
    );
  }

  /// 一次改动开始：把「改动前」的快照压进撤销栈。
  ///
  /// [force] 用于结构性改动（回车拆块、合并、格式命令）——这些必须各占一步历史；
  /// 普通打字则按 [_undoCoalesce] 合并成一步，否则撤销会变成一个字一个字地退。
  void _beginMutation({bool force = false}) {
    _mutationOpen = true;
    final pending = _pendingSnapshot;
    if (pending == null) {
      return;
    }
    final now = DateTime.now();
    final coalesce = !force &&
        !_coalesceBlocked &&
        _undoStack.isNotEmpty &&
        now.difference(_lastUndoAt) < _undoCoalesce;
    if (!coalesce) {
      _undoStack.add(pending);
      if (_undoStack.length > _undoLimit) {
        _undoStack.removeAt(0);
      }
      _lastUndoAt = now;
      // 结构改动自成一步，后面的打字另起一步。
      _coalesceBlocked = force;
    }
    _redoStack.clear();
    _syncHistoryButtons();
  }

  /// 一次改动结束：刷新「改动后」的快照，供下一次撤销使用。
  void _endMutation() {
    _mutationOpen = false;
    _pendingSnapshot = _captureSnapshot();
    _syncHistoryButtons();
  }

  /// 同步性命令（格式、插图、删除块）用这个：先存快照再动数据，最准确。
  void _pushUndoNow() {
    _undoStack.add(_captureSnapshot());
    if (_undoStack.length > _undoLimit) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
    _lastUndoAt = DateTime.fromMillisecondsSinceEpoch(0);
    _coalesceBlocked = true;
    _syncHistoryButtons();
  }

  void _syncHistoryButtons() {
    final undoable = _undoStack.isNotEmpty;
    final redoable = _redoStack.isNotEmpty;
    if (_canUndo.value != undoable) {
      _canUndo.value = undoable;
    }
    if (_canRedo.value != redoable) {
      _canRedo.value = redoable;
    }
  }

  void _undo() {
    if (_undoStack.isEmpty) {
      return;
    }
    _redoStack.add(_captureSnapshot());
    _restoreSnapshot(_undoStack.removeLast());
    // 撤销之后的输入要另起一步历史，不能并进刚撤销的那一段。
    _lastUndoAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  void _redo() {
    if (_redoStack.isEmpty) {
      return;
    }
    _undoStack.add(_captureSnapshot());
    _restoreSnapshot(_redoStack.removeLast());
    _lastUndoAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// 按快照重建整篇内容。
  ///
  /// 控制器不能当场销毁：它们可能正在自己的通知回调栈里（比如撤销由键盘
  /// 快捷键触发），同步 dispose 会踩到 use-after-dispose。统一推到微任务。
  void _restoreSnapshot(_EditorSnapshot snapshot) {
    // 撤销可能回到「用户还没点进来」的那一帧（快照里没有聚焦块）。
    // 这时不要把正在编辑的人踢回浏览态 —— 停在他现在这一块继续编。
    var ordinal = snapshot.focusedTextOrdinal;
    var caret = snapshot.caret;
    if (ordinal < 0 && _focusedEntry != null) {
      var index = 0;
      for (final entry in _entries) {
        if (entry.block is! TextBlock) {
          continue;
        }
        if (identical(entry, _focusedEntry)) {
          ordinal = index;
          break;
        }
        index++;
      }
      caret = -1; // 标记：落到该块末尾
    }

    final oldEntries = List<_BlockEntry>.of(_entries);
    _entries.clear();
    for (final snap in snapshot.blocks) {
      _entries.add(_entryFor(snap.toBlock()));
    }
    _ensureTrailingTextBlock();

    _BlockEntry? focusTarget;
    final textEntries = _entries
        .where((_BlockEntry entry) => entry.block is TextBlock)
        .toList(growable: false);
    if (ordinal >= 0 && textEntries.isNotEmpty) {
      // 撤销后块数可能变少（拆开的块被合并回去），下标要夹住。
      final index =
          ordinal >= textEntries.length ? textEntries.length - 1 : ordinal;
      focusTarget = textEntries[index];
      final controller = focusTarget.controller!;
      controller.selection = TextSelection.collapsed(
        offset: caret < 0
            ? controller.text.length
            : caret.clamp(0, controller.text.length),
      );
    }

    setState(() {
      _focusedEntry = focusTarget;
      if (focusTarget != null) {
        _lastFocused = focusTarget;
      }
    });

    scheduleMicrotask(() {
      for (final entry in oldEntries) {
        entry.controller?.dispose();
        entry.focus?.dispose();
      }
    });

    if (focusTarget != null) {
      _requestFocus(focusTarget);
    }
    _refreshActiveCommands();
    _scheduleSave();
    _endMutation();
  }

  // ---------------------------------------------------------------------------
  // 落盘
  // ---------------------------------------------------------------------------

  String _serialize() {
    final blocks = <Block>[];
    for (final entry in _entries) {
      final controller = entry.controller;
      final block = entry.block;
      if (block is TextBlock && controller != null) {
        block.text = controller.text;
      }
      blocks.add(block);
    }
    return serializeBlocks(blocks);
  }

  /// 生成要落盘的 Note；如果按规则不该落盘则返回 null。
  ///
  /// [updatedOverride] 只给「退出补写」用：防抖持久化路径自己在 [_persist] 里
  /// 刷新 `updated`，不需要外部传。
  /// 正文里有没有「真东西」。
  ///
  /// 不能只看 `body.trim().isEmpty`：用户点了「标题」就退出，正文会是 `## `，
  /// trim 之后非空，于是列表里多出一条只有时间、没有文字的记录。
  /// 所以剥掉记号再看，同时图片/附件本身就算内容。
  bool _hasContent(String body) {
    if (body.trim().isEmpty) {
      return false;
    }
    if (plainSummary(body).trim().isNotEmpty) {
      return true;
    }
    return parseBlocks(body).any((Block block) => block is! TextBlock);
  }

  Note? _buildSnapshot({DateTime? updatedOverride}) {
    if (_discarded) {
      return null;
    }
    final body = _serialize();
    if (!_hasContent(body) && !_persisted) {
      // 空内容的新笔记不落盘：用户点进来又退出，不该在列表里留一条空壳。
      return null;
    }
    return Note(
      id: _id,
      created: _created,
      updated: updatedOverride ?? _updated,
      tags: _tags,
      pinned: _pinned,
      body: body,
    );
  }

  void _scheduleSave() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _persist);
  }

  Future<void> _persist() async {
    if (_discarded) {
      return;
    }
    final body = _serialize();
    if (!_hasContent(body) && !_persisted) {
      return;
    }
    _updated = DateTime.now();
    _headerTime = _updated;
    _persisted = true;
    await widget.repository.upsert(
      Note(
        id: _id,
        created: _created,
        updated: _updated,
        tags: _tags,
        pinned: _pinned,
        body: body,
      ),
    );
    _dirty = false;
  }

  // ---------------------------------------------------------------------------
  // 工具条命令
  // ---------------------------------------------------------------------------

  void _handleCommand(MarkdownCommand command) {
    switch (command) {
      case MarkdownCommand.paragraph:
        _setHeading(0);
        break;
      case MarkdownCommand.h1:
        _setHeading(1);
        break;
      case MarkdownCommand.h2:
        _setHeading(2);
        break;
      case MarkdownCommand.h3:
        _setHeading(3);
        break;
      case MarkdownCommand.bold:
        _applyWrap('**', '**');
        break;
      case MarkdownCommand.italic:
        _applyWrap('*', '*');
        break;
      case MarkdownCommand.strike:
        _applyWrap('~~', '~~');
        break;
      case MarkdownCommand.code:
        _applyWrap('`', '`');
        break;
      case MarkdownCommand.todo:
        _applyPrefix('- [ ] ');
        break;
      case MarkdownCommand.bullet:
        _applyPrefix('- ');
        break;
      case MarkdownCommand.ordered:
        _applyPrefix('1. ');
        break;
      case MarkdownCommand.quote:
        _applyPrefix('> ');
        break;
      case MarkdownCommand.link:
        _applyLink();
        break;
      case MarkdownCommand.codeBlock:
        _insertCodeBlock();
        break;
      case MarkdownCommand.divider:
        _insertDivider();
        break;
      case MarkdownCommand.indent:
        _indentCurrentLine(2);
        break;
      case MarkdownCommand.outdent:
        _indentCurrentLine(-2);
        break;
    }
  }

  /// 把当前行设成某一级标题（0 = 正文）。
  ///
  /// 和「循环切换」的区别：面板里点「标题 2」就直接是标题 2，不管原来是几级。
  /// 循环切换在只有三级时要点三次才轮到想要的那一级，是面板化之前的妥协。
  void _setHeading(int level) {
    final entry = _focusedTextEntry();
    final controller = entry?.controller;
    if (entry == null || controller == null) {
      return;
    }
    _pushUndoNow();
    final text = controller.text;
    final selection = controller.selection;
    final raw = selection.baseOffset < 0
        ? text.length
        : selection.baseOffset.clamp(0, text.length);
    final searchStart = raw - 1;
    final lineStart =
        searchStart < 0 ? 0 : text.lastIndexOf('\n', searchStart) + 1;
    final breakIndex = text.indexOf('\n', raw);
    final lineEnd = breakIndex < 0 ? text.length : breakIndex;
    final line = text.substring(lineStart, lineEnd);

    // 设成标题时把列表/引用的记号一并剥掉：块类型是互斥的，
    // 「## > 21. 内容」这种堆叠既不好看，阅读态也只会渲染出外层那一个。
    // 但「正文」只取消标题本身 —— 一行本来是列表项，点「正文」不该顺手
    // 把它的减号也删了。
    final headingMatch = RegExp(r'^#{1,6}\s+').firstMatch(line);
    final String content;
    if (level == 0) {
      content = headingMatch == null ? line : line.substring(headingMatch.end);
    } else {
      content = _stripBlockPrefixes(line);
    }
    final replaced = level == 0 ? content : '${'#' * level} $content';

    final newText = text.replaceRange(lineStart, lineEnd, replaced);
    final caret = (raw + replaced.length - line.length)
        .clamp(lineStart, lineStart + replaced.length)
        .toInt();
    _applyProgrammatic(
      entry,
      newText,
      selection: TextSelection.collapsed(offset: caret),
      focus: true,
    );
    _scheduleSave();
    _endMutation();
  }

  /// 根据当前焦点块的选区，算出哪些格式按钮该高亮。
  Set<MarkdownCommand> _computeActiveCommands() {
    final entry = _focusedTextEntry();
    final controller = entry?.controller;
    if (controller == null) {
      return <MarkdownCommand>{};
    }
    final text = controller.text;
    final selection = controller.selection;
    if (!selection.isValid) {
      return <MarkdownCommand>{};
    }
    final offset = selection.baseOffset.clamp(0, text.length);
    final searchStart = offset - 1;
    final lineStart =
        searchStart < 0 ? 0 : text.lastIndexOf('\n', searchStart) + 1;
    final breakIndex = text.indexOf('\n', offset);
    final line = text.substring(
      lineStart,
      breakIndex < 0 ? text.length : breakIndex,
    );

    final result = <MarkdownCommand>{};
    final headingMatch = RegExp(r'^(#{1,6})\s').firstMatch(line);
    if (headingMatch != null) {
      // H4 以上没有面板入口，按 H3 显示，避免出现「亮了但点不到」的状态。
      final level = headingMatch.group(1)!.length;
      result.add(switch (level) {
        1 => MarkdownCommand.h1,
        2 => MarkdownCommand.h2,
        _ => MarkdownCommand.h3,
      });
    }
    if (RegExp(r'^\s*[-*+]\s\[[ xX]\]').hasMatch(line)) {
      result.add(MarkdownCommand.todo);
    } else if (RegExp(r'^\s*[-*+]\s').hasMatch(line)) {
      result.add(MarkdownCommand.bullet);
    }
    if (RegExp(r'^\s*\d+[.)]\s').hasMatch(line)) {
      result.add(MarkdownCommand.ordered);
    }
    if (RegExp(r'^\s*>\s?').hasMatch(line)) {
      result.add(MarkdownCommand.quote);
    }

    // 行内格式只能靠「选区两侧是否正好是标记」判断，
    // 折叠光标下不做猜测 —— 猜错比不亮更让人困惑。
    if (!selection.isCollapsed) {
      final before = text.substring(0, selection.start);
      final after = text.substring(selection.end);
      if (before.endsWith('**') && after.startsWith('**')) {
        result.add(MarkdownCommand.bold);
      }
      if (before.endsWith('~~') && after.startsWith('~~')) {
        result.add(MarkdownCommand.strike);
      }
      if (before.endsWith('`') && after.startsWith('`')) {
        result.add(MarkdownCommand.code);
      }
      if (!result.contains(MarkdownCommand.bold) &&
          before.endsWith('*') &&
          after.startsWith('*') &&
          !before.endsWith('**') &&
          !after.startsWith('**')) {
        result.add(MarkdownCommand.italic);
      }
    }
    return result;
  }

  void _refreshActiveCommands() {
    final next = _computeActiveCommands();
    // 先更新光标字号再判断集合是否变化：同一标题级内的移动不会改集合，
    // 但字号仍需保持正确（H4-H6 在激活态里都映射为 H3）。
    _updateCursorFontSize();
    if (setEquals(_activeCommands.value, next)) {
      return;
    }
    _activeCommands.value = next;
  }

  /// 光标所在行的字号：普通行 = 正文字号；标题行按级别放大
  /// （与 buildTextSpan 的渲染一致）。随选区移动即时更新。
  void _updateCursorFontSize() {
    final entry = _focusedTextEntry();
    final controller = entry?.controller;
    var size = MarkdownEditingController.baseFontSize;
    if (controller != null) {
      final text = controller.text;
      final selection = controller.selection;
      if (selection.isValid) {
        final offset = selection.baseOffset.clamp(0, text.length);
        final searchStart = offset - 1;
        final lineStart =
            searchStart < 0 ? 0 : text.lastIndexOf('\n', searchStart) + 1;
        final lineEnd = text.indexOf('\n', offset);
        final line = text.substring(
          lineStart,
          lineEnd < 0 ? text.length : lineEnd,
        );
        final match = RegExp(r'^(#{1,6})\s').firstMatch(line);
        if (match != null) {
          final level = match.group(1)!.length;
          size = MarkdownEditingController.baseFontSize *
              MarkdownEditingController.headingScale(level);
        }
      }
    }
    if (_cursorFontSize.value != size) {
      _cursorFontSize.value = size;
    }
  }

  /// 行首前缀（标题 / 待办 / 列表 / 引用）。
  ///
  /// 同一个按钮点第二次就是取消 —— 用户不需要知道「怎么删掉那个减号」。
  void _applyPrefix(String marker) {
    final entry = _focusedTextEntry();
    final controller = entry?.controller;
    if (entry == null || controller == null) {
      return;
    }
    _pushUndoNow();

    final text = controller.text;
    final selection = controller.selection;
    final rawOffset = selection.baseOffset < 0
        ? text.length
        : selection.baseOffset.clamp(0, text.length);
    // lastIndexOf 的 start 传负数行为不明确，这里显式收敛到 0。
    final searchStart = rawOffset - 1;
    final lineStart =
        searchStart < 0 ? 0 : text.lastIndexOf('\n', searchStart) + 1;
    final lineBreak = text.indexOf('\n', rawOffset);
    final lineEnd = lineBreak < 0 ? text.length : lineBreak;

    final line = text.substring(lineStart, lineEnd);
    // 先把已有的块级记号全部剥掉，再按目标类型重新加一个 ——
    // 叠着加会得到 `-> ` / `## > ` 这类残渣（用户实测）。
    final content = _stripBlockPrefixes(line);
    // 已经是同类：再点一次就是取消（用户不需要知道怎么删那个减号）。
    final replaced =
        _hasBlockPrefixOfKind(line, marker) ? content : '$marker$content';

    final newText = text.replaceRange(lineStart, lineEnd, replaced);
    final delta = replaced.length - line.length;
    final newOffset = (rawOffset + delta).clamp(
      lineStart,
      lineStart + replaced.length,
    );

    _applyProgrammatic(
      entry,
      newText,
      selection: TextSelection.collapsed(offset: newOffset),
      focus: true,
    );
    _scheduleSave();
    _endMutation();
  }

  /// 包裹型（粗体 / 斜体 / 行内码）。空选区时插入配对符号并把光标夹在中间。
  void _applyWrap(String open, String close) {
    final entry = _focusedTextEntry();
    final controller = entry?.controller;
    if (entry == null || controller == null) {
      return;
    }
    _pushUndoNow();

    final text = controller.text;
    var selection = controller.selection;
    if (!selection.isValid) {
      selection = TextSelection.collapsed(offset: text.length);
    }
    final start = selection.start.clamp(0, text.length);
    final end = selection.end.clamp(0, text.length);
    final selected = text.substring(start, end);

    final inserted = '$open$selected$close';
    final newText = text.replaceRange(start, end, inserted);
    // 空选区：插入配对符号，光标必须夹在中间 —— 用户下一步就是打字。
    // 之前统一算到符号组末尾，点加粗后光标落在 **** 后面，
    // 看起来就是「点了格式但光标没过来」。
    final caret = selected.isEmpty
        ? start + open.length
        : start + open.length + selected.length + close.length;

    _applyProgrammatic(
      entry,
      newText,
      selection: TextSelection.collapsed(offset: caret),
      focus: true,
    );
    _scheduleSave();
    _endMutation();
  }

  /// 在光标处插入成对代码围栏，光标落到中间空行 —— 下一步就是写代码。
  void _insertCodeBlock() {
    final entry = _focusedTextEntry();
    final controller = entry?.controller;
    if (entry == null || controller == null) {
      return;
    }
    _pushUndoNow();
    final text = controller.text;
    final selection = controller.selection;
    final offset = selection.isValid
        ? selection.baseOffset.clamp(0, text.length)
        : text.length;
    // 围栏必须独占一行：光标在行中/行尾时先补一个换行，否则
    // 「code```」这种拼在一起的行不会被渲染器认成围栏开头。
    final lineStart = offset <= 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;
    final emptyLine = text.substring(lineStart, offset).trim().isEmpty;
    final snippet = emptyLine ? '```\n\n```' : '\n```\n\n```';
    final caretInSnippet = emptyLine ? 4 : 5;
    final newText = text.replaceRange(offset, offset, snippet);
    _applyProgrammatic(
      entry,
      newText,
      selection: TextSelection.collapsed(offset: offset + caretInSnippet),
      focus: true,
    );
    _scheduleSave();
    _endMutation();
  }

  /// 在光标所在行的下一行插入 `---`（分隔线必须独占一行）。
  void _insertDivider() {
    final entry = _focusedTextEntry();
    final controller = entry?.controller;
    if (entry == null || controller == null) {
      return;
    }
    _pushUndoNow();
    final text = controller.text;
    final selection = controller.selection;
    final raw = selection.isValid
        ? selection.baseOffset.clamp(0, text.length)
        : text.length;
    final lineEnd = text.indexOf('\n', raw);
    final insertAt = lineEnd < 0 ? text.length : lineEnd;
    final newText = text.replaceRange(insertAt, insertAt, '\n---');
    _applyProgrammatic(
      entry,
      newText,
      selection: TextSelection.collapsed(offset: insertAt + 4),
      focus: true,
    );
    _scheduleSave();
    _endMutation();
  }

  /// 当前行整体缩进 / 反缩进（嵌套列表的规范写法是行首两个空格）。
  ///
  /// 列表行缩进后渲染器按嵌套渲染；有序列表缩进后成为**子列表**，编号
  /// 从 1 重开（语雀语义），父级与后续兄弟项的编号由 [_renumberOrderedLists]
  /// 按层级接续。减少缩进最多删到行首，弹回的编号同样自动接回父级。
  void _indentCurrentLine(int delta) {
    final entry = _focusedTextEntry();
    final controller = entry?.controller;
    if (entry == null || controller == null || delta == 0) {
      return;
    }
    _pushUndoNow();
    final text = controller.text;
    final selection = controller.selection;
    final raw = selection.isValid
        ? selection.baseOffset.clamp(0, text.length)
        : text.length;
    final lineStart = raw <= 0 ? 0 : text.lastIndexOf('\n', raw - 1) + 1;
    final line = text.substring(
      lineStart,
      text.indexOf('\n', raw) < 0 ? text.length : text.indexOf('\n', raw),
    );

    String newLine;
    var caretDelta = 0;
    if (delta > 0) {
      newLine = '  $line';
      caretDelta = 2;
      // 有序列表项缩进 = 转为子列表首项，编号重开为 1。编号长度可能变化
      // （「10.」→「1.」），光标偏移一起修正。
      final ordered =
          RegExp(r'^(\s*)(\d+)([.)])(\s.*)$').firstMatch(line);
      if (ordered != null) {
        newLine =
            '${ordered.group(1)}  1${ordered.group(3)}${ordered.group(4)}';
        caretDelta = 2 - (ordered.group(2)!.length - 1);
      }
    } else {
      final leading = RegExp(r'^ {1,2}').firstMatch(line);
      if (leading == null) {
        // 已经顶格： nothing to outdent，撤销点也别留。
        _undoStack.removeLast();
        _syncHistoryButtons();
        _endMutation();
        return;
      }
      newLine = line.substring(leading.end);
      caretDelta = -leading.end;
    }

    final newText = text.replaceRange(lineStart, lineStart + line.length, newLine);
    final newCaret = (raw + caretDelta).clamp(lineStart, newText.length);
    _applyProgrammatic(
      entry,
      newText,
      selection: TextSelection.collapsed(offset: newCaret),
      focus: true,
    );
    // 缩进/反缩进改变了层级：父级与兄弟项的编号按层级栈接续重排。
    _renumberOrderedLists();
    _scheduleSave();
    _endMutation();
  }

  /// 插入链接，并把 url 部分选中，方便用户直接粘贴覆盖。
  void _applyLink() {
    final entry = _focusedTextEntry();
    final controller = entry?.controller;
    if (entry == null || controller == null) {
      return;
    }
    _pushUndoNow();

    final text = controller.text;
    var selection = controller.selection;
    if (!selection.isValid) {
      selection = TextSelection.collapsed(offset: text.length);
    }
    final start = selection.start.clamp(0, text.length);
    final end = selection.end.clamp(0, text.length);
    final selected = text.substring(start, end);
    final label = selected.isEmpty ? '文字' : selected;

    final inserted = '[$label](url)';
    final newText = text.replaceRange(start, end, inserted);
    final urlStart = start + 1 + label.length + 2;

    _applyProgrammatic(
      entry,
      newText,
      selection: TextSelection(
        baseOffset: urlStart,
        extentOffset: urlStart + 3,
      ),
      focus: true,
    );
    _scheduleSave();
    _endMutation();
  }

  // ---------------------------------------------------------------------------
  // 附件
  // ---------------------------------------------------------------------------

  /// 附件面板选中动作（面板由工具条就地展开，与 Aa 一致）。
  Future<void> _runAttachAction(MarkdownAttachAction action) async {
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

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? file = await _imagePicker.pickImage(
        source: source,
        imageQuality: 92,
      );
      if (file == null) {
        return;
      }
      final relative = await _store.importAttachment(
        noteId: _id,
        sourcePath: file.path,
      );
      if (!mounted) {
        return;
      }
      _insertImageBlock(relative);
    } catch (error) {
      _showMessage('插入图片失败：$error');
    }
  }

  Future<void> _pickFile() async {
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) {
        return;
      }
      final picked = result.files.single;
      final path = picked.path;
      if (path == null) {
        return;
      }
      final name = picked.name;
      final relative = await _store.importAttachment(
        noteId: _id,
        sourcePath: path,
      );
      if (!mounted) {
        return;
      }
      _insertFileBlock(relative, name);
    } catch (error) {
      _showMessage('插入附件失败：$error');
    }
  }

  void _insertImageBlock(String relativePath) {
    _pushUndoNow();
    final anchor = _focusedTextIndex();
    final insertAt = anchor + 1;
    // 后面紧跟一个空文本块时复用它，避免图片之间堆出一串空行。
    final canReuse = insertAt < _entries.length &&
        _entries[insertAt].block is TextBlock &&
        (_entries[insertAt].block as TextBlock).text.isEmpty;

    final imageEntry = _BlockEntry(ImageBlock(alt: '', path: relativePath));
    final textEntry = canReuse ? null : _createTextEntry('');
    late final _BlockEntry focusEntry;

    setState(() {
      _entries.insert(insertAt, imageEntry);
      if (textEntry != null) {
        _entries.insert(insertAt + 1, textEntry);
        focusEntry = textEntry;
      } else {
        focusEntry = _entries[insertAt + 1];
      }
      // 焦点必须一并交给新文本块：只 requestFocus 而不同步 _focusedEntry 的话，
      // 那一块仍按渲染态呈现（不是 TextField），焦点无处落地 —— 输完图键盘就收、
      // 光标消失（和退格合并块同一个坑）。
      _focusedEntry = focusEntry;
      _lastFocused = focusEntry;
    });

    _requestFocus(focusEntry);
    _scheduleSave();
    _endMutation();
  }

  void _insertFileBlock(String relativePath, String name) {
    _pushUndoNow();
    final anchor = _focusedTextIndex();
    final insertAt = anchor + 1;
    final canReuse = insertAt < _entries.length &&
        _entries[insertAt].block is TextBlock &&
        (_entries[insertAt].block as TextBlock).text.isEmpty;

    final fileEntry = _BlockEntry(FileBlock(name: name, path: relativePath));
    final textEntry = canReuse ? null : _createTextEntry('');
    late final _BlockEntry focusEntry;

    setState(() {
      _entries.insert(insertAt, fileEntry);
      if (textEntry != null) {
        _entries.insert(insertAt + 1, textEntry);
        focusEntry = textEntry;
      } else {
        focusEntry = _entries[insertAt + 1];
      }
      _focusedEntry = focusEntry;
      _lastFocused = focusEntry;
    });

    _requestFocus(focusEntry);
    _scheduleSave();
    _endMutation();
  }

  // ---------------------------------------------------------------------------
  // 头部动作
  // ---------------------------------------------------------------------------

  Future<void> _togglePin() async {
    setState(() {
      _pinned = !_pinned;
    });
    await _persist();
  }

  Future<void> _editTags() async {
    // 已有的标签作为候选：小记的标签是「少数几个反复用」，
    // 每次手打一遍既慢又容易打出「读书 / 读书 」这种近义词。
    final candidates = widget.repository.tags.take(12).toList();
    // 输入文本提升到弹层局部变量：候选 chips 与保存按钮都读它。
    // TextEditingController 归 _TagInputField 自己管（见该类注释）——
    // 之前在 pop 返回后立刻 dispose，而 bottom sheet 的 pop Future 在
    // 退场动画开始前就完成，TextField 挂着已销毁的控制器播完退场，
    // debug 包触发 InheritedElement 断言崩溃（_dependents.isEmpty）。
    final syncText = ValueNotifier<String>(_tags.join(', '));
    var tagsText = _tags.join(', ');
    final result = await showXiaojiSheet<List<String>>(
      context: context,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            final colors = AppColors.of(context);
            final selected = Note.parseTags(tagsText);
            return Padding(
              // 键盘是系统层，压得住 bottom sheet；让出 viewInsets 后
              // 输入框才会浮在键盘上沿。
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '标签',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: AppWeight.medium,
                          color: colors.text,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _TagInputField(
                        initialText: tagsText,
                        external: syncText,
                        onChanged: (String value) {
                          tagsText = value;
                          setSheetState(() {});
                        },
                      ),
                      if (candidates.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 10),
                        Text(
                          '已有标签',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: colors.tertiary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: <Widget>[
                            for (final tag in candidates)
                              _TagCandidateChip(
                                label: tag,
                                selected: selected.contains(tag),
                                onTap: () {
                                  final next = Note.parseTags(tagsText);
                                  if (next.contains(tag)) {
                                    next.remove(tag);
                                  } else {
                                    next.add(tag);
                                  }
                                  tagsText = next.join(', ');
                                  // 回填输入框：光标始终移到末尾，接着打字顺理成章。
                                  syncText.value = tagsText;
                                  setSheetState(() {});
                                },
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 20),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Material(
                              color: colors.surface2,
                              borderRadius: BorderRadius.circular(10),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () => Navigator.of(sheetContext).pop(),
                                child: Container(
                                  height: 52,
                                  alignment: Alignment.center,
                                  child: Text(
                                    '取消',
                                    style: TextStyle(
                                      fontSize: 16,
                                      height: 1,
                                      fontWeight: AppWeight.medium,
                                      color: colors.secondary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Material(
                              color: colors.accent,
                              borderRadius: BorderRadius.circular(10),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () => Navigator.of(sheetContext)
                                    .pop(Note.parseTags(tagsText)),
                                child: Container(
                                  height: 52,
                                  alignment: Alignment.center,
                                  child: Text(
                                    '保存',
                                    style: TextStyle(
                                      fontSize: 16,
                                      height: 1,
                                      fontWeight: AppWeight.medium,
                                      color: colors.page,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    if (result == null || !mounted) {
      return;
    }
    setState(() {
      _tags = result;
    });
    await _persist();
  }

  Future<void> _handleMenu(_EditorMenu menu) async {
    switch (menu) {
      case _EditorMenu.copy:
        await Clipboard.setData(ClipboardData(text: _serialize()));
        _showMessage('已复制到剪贴板');
        break;
      case _EditorMenu.tags:
        await _editTags();
        break;
      case _EditorMenu.pin:
        await _togglePin();
        break;
      case _EditorMenu.delete:
        await _confirmDelete();
        break;
    }
  }

  /// 右上角「···」菜单（原 PopupMenuButton）。
  Future<void> _showEditorMenu() async {
    final action = await showXiaojiSheet<_EditorMenu>(
      context: context,
      builder: (BuildContext sheetContext) {
        final colors = AppColors.of(sheetContext);
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _menuTile(
                sheetContext,
                _pinned ? Icons.push_pin : Icons.push_pin_outlined,
                _pinned ? '取消置顶' : '置顶',
                _EditorMenu.pin,
              ),
              _menuTile(
                sheetContext,
                Icons.content_copy,
                '复制文本',
                _EditorMenu.copy,
              ),
              _menuTile(
                sheetContext,
                Icons.label_outline,
                '编辑标签',
                _EditorMenu.tags,
              ),
              _menuTile(
                sheetContext,
                Icons.delete_outline,
                '删除',
                _EditorMenu.delete,
                foreground: colors.danger,
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (action == null || !mounted) {
      return;
    }
    await _handleMenu(action);
  }

  Widget _menuTile(
    BuildContext sheetContext,
    IconData icon,
    String label,
    _EditorMenu value, {
    Color? foreground,
  }) {
    final colors = AppColors.of(sheetContext);
    return InkWell(
      onTap: () => Navigator.of(sheetContext).pop(value),
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        alignment: Alignment.centerLeft,
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20, color: foreground ?? colors.text),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                color: foreground ?? colors.text,
              ),
            ),
          ],
        ),
      ),
    );
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
    if (_persisted) {
      await widget.repository.remove(
        Note(
          id: _id,
          created: _created,
          updated: _updated,
          tags: _tags,
          pinned: _pinned,
          body: _serialize(),
        ),
      );
    }
    _discarded = true;
    _saveTimer?.cancel();
    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    final colors = AppColors.of(context);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: colors.text,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final media = MediaQuery.of(context);
    final keyboardInset = media.viewInsets.bottom;
    final safeBottom = media.padding.bottom;

    return Scaffold(
      backgroundColor: colors.page,
      // 键盘避让交还 Scaffold：视口真正缩短之后，EditableText 的
      // scrollPadding（相对视口底部）语义才是对的。之前视口全高 + 键盘
      // 浮层的组合里，scrollPadding 只能写成「键盘 + 工具条」，而光标
      // 距视口底动辄小于这个值 —— 每次聚焦都被系统推到接近视口顶部，
      // 用户看到的就是「弹输入法内容页往上滚」（用户实测）。
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: <Widget>[
            Column(
              children: <Widget>[
                _buildHeader(colors),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      // 平板/折叠屏上限宽，写字区域拉满全宽反而难读
                      constraints: const BoxConstraints(maxWidth: 640),
                      // 单态：浏览与编辑是同一个块列表，聚焦块显示输入框，
                      // 其余块保持渲染。
                      child: _buildBlockList(colors),
                    ),
                  ),
                ),
                // 标签栏高度恒定：键盘弹出时随 body 底边上移到键盘上沿，
                // 被浮层工具条（52 高 > 40）整个盖住，视觉与交互都不受影响。
                _buildBottomTags(colors, safeBottom),
              ],
            ),
            // 工具条是浮层：贴在键盘上沿，不参与 Column 布局。
            _buildToolbar(colors, keyboardInset),
          ],
        ),
      ),
    );
  }

  /// 工具条：贴在键盘上沿的浮层，键盘收起时滑出屏幕。
  ///
  /// 不再用 AnimatedSize/ClipRect 做占位收缩：它是 Positioned 浮层，
  /// 高度不参与布局，内容区因此不会随键盘变化而重排。
  Widget _buildToolbar(AppColors colors, double keyboardInset) {
    final keyboardVisible = keyboardInset > 0;
    return Positioned(
      left: 0,
      right: 0,
      // Scaffold 已把 body 缩到键盘上沿，Stack 底边就是键盘顶 ——
      // 工具条贴底即可。之前 bottom: keyboardInset 是「body 不避让」
      // 时代的写法，避让后会在键盘高度之上再抬一截，工具条跑到屏幕中部。
      bottom: 0,
      child: IgnorePointer(
        // 透明且不响应点击，防止「看不见但点得到」。
        ignoring: !keyboardVisible,
        // 工具条是浮层，按钮之间有空隙。空隙不吞事件的话，点工具栏会
        // **穿透到正文**，把光标挪到那一行，接着的命令就改错了行
        // （实测：光标在第 21 行，点「列表」面板后变成第 19 行）。
        // 用 Listener 而不是 GestureDetector：它不进手势竞技场，
        // 不会和按钮自己的 tap 抢。
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) {},
          child: AnimatedSlide(
            offset: keyboardVisible ? Offset.zero : const Offset(0, 1),
            duration: _toolbarAnimation,
            curve: Curves.easeOut,
            child: AnimatedOpacity(
              opacity: keyboardVisible ? 1 : 0,
              duration: _toolbarAnimation,
              curve: Curves.easeOut,
              child: AnimatedBuilder(
                // 激活态变化只重建工具条这一行，不重建整个块列表。
                animation: _activeCommands,
                builder: (BuildContext context, Widget? _) {
                  return MarkdownToolbar(
                    onCommand: _handleCommand,
                    onAttachAction: _runAttachAction,
                    onHideKeyboard: _hideKeyboard,
                    active: _activeCommands.value,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 收起软键盘但不退出编辑态。
  ///
  /// 用 TextInput.hide 而不是 unfocus：unfocus 会销毁 input connection，
  /// 之后再想弹键盘，Android 11+ 对没有活跃连接的 show 请求一律拒绝
  /// （模拟器实测 mInputShown 恒 false）。hide 只收 IME，焦点和连接都保留，
  /// 与系统返回键收键盘同语义 —— 这也是「收键盘但光标还在」的标准做法。
  /// 光标保持可见，编辑态不变；工具栏的显示条件是 keyboardInset>0，照常消失。
  /// 收起键盘并回到浏览：聚焦块转回渲染态，内容以最终效果呈现。
  ///
  /// 单态下这就是「退出编辑」—— 没有独立的阅读态，自动保存一直在跑。
  /// 之前双态时这里只 TextInput.hide 不 unfocus（为了保住 input connection
  /// 唤回键盘）；单态里点正文会重新聚焦建新连接，不需要保连接了。
  void _hideKeyboard() {
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    FocusScope.of(context).unfocus();
    if (mounted && _focusedEntry != null) {
      setState(() => _focusedEntry = null);
    }
  }

  /// 底部常驻标签栏。
  ///
  /// - 有标签：`#标签` chips，横滑，点任意 chip 打开标签编辑弹层；
  /// - 无标签：「＋ 标签」占位，保证添加入口可发现。
  ///
  /// 高度恒定（含安全区），不随键盘变化 —— 否则键盘一弹列表视口就变矮，
  /// 内容整体上移。键盘弹出时这一条本来就在键盘下方看不见。
  Widget _buildBottomTags(AppColors colors, double safeBottom) {
    return SizedBox(
      height: _tagBarHeight + safeBottom,
      child: Padding(
        padding: EdgeInsets.only(bottom: safeBottom),
        child: SizedBox(
          height: _tagBarHeight,
          child: ListView(
            scrollDirection: Axis.horizontal,
            // 用 ListView 而不是 SingleChildScrollView：后者在内容窄于视口时
            //（尤其无标签时只有「＋ 标签」一个占位）会把内容摆到中间，
            // 需求是贴左下角；ListView 的条目从滚动原点（左端）排布，
            // 天然左对齐，超宽时照样横滑。
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
            children: <Widget>[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (_tags.isEmpty)
                    InkWell(
                      onTap: _editTags,
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                      child: Container(
                        height: 26,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        alignment: Alignment.center,
                        child: Container(
                          height: 26,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            // 占位用描边而不是裸 tertiary 文字：浅灰小字在白纸上
                            // 几乎隐形，用户根本发现不了这里能加标签。
                            borderRadius: BorderRadius.circular(AppRadius.chip),
                            border: Border.all(
                                color: colors.chipBorder, width: 0.8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(Icons.add,
                                  size: 14, color: colors.secondary),
                              const SizedBox(width: 4),
                              Text(
                                '标签',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1,
                                  color: colors.secondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    for (var i = 0; i < _tags.length; i++) ...<Widget>[
                      if (i > 0) const SizedBox(width: 8),
                      _BottomTagChip(label: _tags[i], onTap: _editTags),
                    ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AppColors colors) {
    // 时间必须**绝对居中**：之前用 Expanded+Center，但左右两侧宽度不等
    // （左返回 48 / 右撤销重做+菜单 122），Center 只在 Expanded 内居中，
    // 视觉上整体偏左。改 Stack 三层叠放，中轴与屏幕中线重合。
    return SizedBox(
      height: 48,
      child: Stack(
        children: <Widget>[
          Center(
            child: Text(
              formatEditorTime(_headerTime),
              style: AppText.meta.copyWith(color: colors.secondary),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: SizedBox(
              width: 48,
              child: InkWell(
                onTap: () => Navigator.of(context).maybePop(),
                child: Icon(
                  Icons.arrow_back_ios_new,
                  size: 22,
                  color: colors.secondary,
                ),
              ),
            ),
          ),
          // 撤销 / 重做常驻右上角：编辑器的高频动作不该藏在工具栏里，
          // 无历史时置灰但保留占位，顶栏不抖动。
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: AnimatedBuilder(
              animation: Listenable.merge(<Listenable>[_canUndo, _canRedo]),
              builder: (BuildContext context, Widget? _) {
                final canUndo = _canUndo.value;
                final canRedo = _canRedo.value;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(
                      width: 40,
                      child: InkWell(
                        onTap: canUndo ? _undo : null,
                        child: Icon(
                          // 弧形箭头（rotate_left/right）是国内主流编辑器
                          // 撤销/重做的样式；Icons.undo 的折角箭头太「工程感」。
                          Icons.rotate_left,
                          size: 21,
                          color: canUndo ? colors.text : colors.tertiary,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: InkWell(
                        onTap: canRedo ? _redo : null,
                        child: Icon(
                          Icons.rotate_right,
                          size: 21,
                          color: canRedo ? colors.text : colors.tertiary,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 42,
                      child: InkWell(
                        onTap: _showEditorMenu,
                        child: Icon(
                          Icons.more_horiz,
                          size: 21,
                          color: colors.secondary,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 阅读态勾选/取消第 [todoIndex] 个待办：直接翻转块文本里的
  /// `[ ]`/`[x]` 记号，不进编辑态（此前点勾选框会被「点正文进编辑」
  /// 手势吃掉，用户只能进编辑手改记号）。
  void _toggleTodoAt(_BlockEntry entry, int todoIndex) {
    final block = entry.block;
    if (block is! TextBlock) {
      return;
    }
    final lines = block.text.split('\n');
    final todoPattern = RegExp(r'^(\s*[-*+]\s\[)([ xX])(\].*)$');
    var seen = 0;
    for (var i = 0; i < lines.length; i++) {
      final match = todoPattern.firstMatch(lines[i]);
      if (match == null) {
        continue;
      }
      if (seen == todoIndex) {
        final checked = match.group(2)!.toLowerCase() == 'x';
        lines[i] = '${match.group(1)}${checked ? ' ' : 'x'}${match.group(3)}';
        final newText = lines.join('\n');
        setState(() {
          _applyProgrammatic(entry, newText);
        });
        _scheduleSave();
        return;
      }
      seen++;
    }
    _endMutation();
  }

  /// 从阅读态进入编辑态，并把光标落到被点的那一块末尾。
  /// 聚焦某个块进入编辑（单态里唯一的「进编辑」动作）。
  ///
  /// [tapPosition] 是渲染态点击时的全局坐标：光标应落在手指点的那句话
  /// 附近，而不是块尾 —— 落块尾会让用户觉得光标跑到了奇怪的地方。
  /// 已经聚焦在这块时直接返回，块内点击由 TextField 自己定位。
  void _focusEntry(_BlockEntry entry, {Offset? tapPosition}) {
    if (identical(_focusedEntry, entry)) {
      return;
    }
    setState(() => _focusedEntry = entry);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_focusedEntry, entry)) {
        return;
      }
      final controller = entry.controller;
      if (controller != null) {
        var offset = controller.text.length;
        final positioned =
            tapPosition != null ? _caretOffsetAt(entry, tapPosition) : null;
        if (positioned != null) {
          offset = positioned.clamp(0, controller.text.length);
        }
        controller.selection = TextSelection.collapsed(offset: offset);
      }
      final node = entry.focus;
      if (node != null) {
        // 走 FocusScope 而不是 node.requestFocus()：换块那一帧新旧
        // TextField 同时存在，直接 requestFocus 偶尔双光标（历史教训）。
        FocusScope.of(context).requestFocus(node);
        _ensureVisible(entry);
      }
      _refreshActiveCommands();
    });
  }

  /// 把全局坐标换算成块内光标偏移；拿不到 RenderEditable（罕见时序）就
  /// 返回 null，调用方回退到「块尾」。
  int? _caretOffsetAt(_BlockEntry entry, Offset globalPosition) {
    final fieldContext = entry.fieldKey.currentContext;
    if (fieldContext == null) {
      return null;
    }
    final editable = _findRenderEditable(fieldContext.findRenderObject());
    if (editable == null || !editable.attached) {
      return null;
    }
    return editable.getPositionForPoint(globalPosition).offset;
  }

  /// 在 TextField 的渲染树里找 [RenderEditable]：TextField 本身的
  /// renderObject 是装饰层，真正的文本渲染对象在其后代里。
  static RenderEditable? _findRenderEditable(RenderObject? object) {
    if (object is RenderEditable) {
      return object;
    }
    RenderEditable? found;
    void visitor(RenderObject child) {
      if (found != null) {
        return;
      }
      if (child is RenderEditable) {
        found = child;
        return;
      }
      child.visitChildren(visitor);
    }

    object?.visitChildren(visitor);
    return found;
  }

  /// 单态块列表：聚焦的文本块是 TextField，其余全部按渲染态呈现
  /// （记号剔除、待办可点选）—— 语雀「浏览即内容、点哪编哪」的核心。
  Widget _buildBlockList(AppColors colors) {
    final onlyEmptyBlock = _entries.length == 1 &&
        _entries.first.block is TextBlock &&
        (_entries.first.block as TextBlock).text.isEmpty;
    // 底部 padding 必须是**常量**（覆盖两种最坏情况取大：键盘收起时
    // 标签栏 40 + 呼吸；键盘弹出时工具条 52 + 呼吸）。
    //
    // 曾经按键盘可见性在 180/68 之间切换 —— 键盘一升内容高度骤减 112，
    // 用户停在笔记底部时 offset > 新 maxScrollExtent，布局期直接把滚动
    // 位置 clamp 回去（不经过任何滚动监听），表现为「弹工具栏内容被
    // 顶动一截」。改为常量后键盘起落不改变内容高度，滚动位置纹丝不动
    // （探针实测：长文/短文、聚焦/不聚焦全部零移动）。
    final bottomInset =
        MediaQuery.paddingOf(context).bottom + 84;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // 点正文以外的空白：聚焦最后一个文本块，光标放到点击位置附近。
      onTapUp: (TapUpDetails details) {
        for (var i = _entries.length - 1; i >= 0; i--) {
          if (_entries[i].block is TextBlock) {
            _focusEntry(_entries[i], tapPosition: details.globalPosition);
            return;
          }
        }
      },
      child: ListView.builder(
        controller: _scrollController,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: EdgeInsets.fromLTRB(
          AppSpace.page,
          AppSpace.xs,
          AppSpace.page,
          bottomInset,
        ),
        itemCount: _entries.length,
        itemBuilder: (BuildContext context, int index) {
          final entry = _entries[index];
          final block = entry.block;

          Widget child;
          if (block is TextBlock) {
            if (identical(entry, _focusedEntry)) {
              child = _buildFocusedField(
                entry,
                colors,
                onlyEmptyBlock: onlyEmptyBlock,
              );
            } else {
              // 未聚焦：渲染态（记号剔除、待办可点选）。点正文聚焦该块
              // 并把光标放到点击位置。空行块渲染成 Typora 式段距
              // （0 高度会让「空白行塌掉」，用户实测）。
              if (block.text.trim().isEmpty) {
                child = const SizedBox(
                  height: MarkdownEditingController.baseFontSize * 0.9,
                );
              } else {
                child = MarkdownBlockView(
                  text: block.text,
                  baseSize: MarkdownEditingController.baseFontSize,
                  onTap: (Offset globalPosition) =>
                      _focusEntry(entry, tapPosition: globalPosition),
                  // 待办在浏览时直接勾选（语雀/Notion 同款），不必先进编辑。
                  onToggleTodo: (int todoIndex) =>
                      _toggleTodoAt(entry, todoIndex),
                );
              }
            }
          } else if (block is ImageBlock) {
            // Builder 捕获图片块的 context：打开大图时用它取缩略图的
            // 全局矩形，微信式「从缩略图位置展开」。
            child = Builder(
              builder: (BuildContext blockContext) => ImageBlockView(
                block: block,
                absolutePath: _store.absoluteAssetPath(block.path),
                onTap: () => _openImage(block, blockContext),
                onLongPress: () => _showImageActions(block),
              ),
            );
          } else {
            final fileBlock = block as FileBlock;
            child = FileBlockView(
              block: fileBlock,
              absolutePath: _store.absoluteAssetPath(fileBlock.path),
              onTap: () => _showMessage(
                '文件位于：${_store.absoluteAssetPath(fileBlock.path)}',
              ),
              onLongPress: () => _confirmRemoveBlock(entry),
            );
          }

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
            child: child,
          );
        },
      ),
    );
  }

  /// 聚焦块的输入框：只有这一块以 markdown 源码形态存在
  /// （记号淡显），其余内容都是渲染态。
  Widget _buildFocusedField(
    _BlockEntry entry,
    AppColors colors, {
    required bool onlyEmptyBlock,
  }) {
    // 光标高度跟随光标所在行的字号（标题行放大、正文行还原），
    // 用 notifier 而不是 setState：随选区变化只重建这一个输入框。
    return ValueListenableBuilder<double>(
      valueListenable: _cursorFontSize,
      builder: (BuildContext context, double cursorFontSize, _) {
        return TextField(
          key: entry.fieldKey,
          controller: entry.controller,
          focusNode: entry.focus,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          autofocus: false,
          // 输入即转换（`[] ` → `- [ ] `、`* ` → `- `）走 IME 管线的 formatter，
          // 见 markdown_shortcut_formatter.dart 里的说明。
          inputFormatters: const <TextInputFormatter>[
            MarkdownShortcutFormatter(),
          ],
          cursorColor: colors.accent,
          // 光标高度按行字号校准（真机 BMP 像素测量）：
          // - 正文行 0.95×字号：光标与中文字形等高居中（round 17 校准）；
          // - 标题行 1.10×字号：Flutter 光标的垂直中心由 strut 字体度量
          //   决定、与高度无关，真机上标题行中心固定偏下 ~12px，调高度
          //   移不动中心 —— 只能让光标变长到「顶部对齐文字顶、轻微下探」，
          //   视觉上与标题文字贴合（中文/Latin 都验证过）。
          cursorHeight: cursorFontSize *
              (cursorFontSize > MarkdownEditingController.baseFontSize + 0.1
                  ? 1.10
                  : 0.95),
          cursorWidth: cursorFontSize > 20 ? 1.8 : 1.5,
          // scrollPadding 恒定小值：视口已由 Scaffold 缩到键盘上沿，
          // 「光标距视口底 ≥ 12」就等于「贴在键盘上方」，语义恢复正确。
          // 之前视口全高时把它写成键盘+工具条的高度，光标距视口底动辄
          // 小于它 → 每次聚焦都被推到接近视口顶部（内容页上滚的根因）。
          scrollPadding: const EdgeInsets.only(bottom: 12),
          style: TextStyle(
            fontSize: MarkdownEditingController.baseFontSize,
            height: 1.72,
            color: colors.text,
            fontWeight: AppWeight.regular,
          ),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.zero,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            hintText: onlyEmptyBlock ? '记点什么…' : null,
            hintStyle: TextStyle(
              fontSize: MarkdownEditingController.baseFontSize,
              color: colors.tertiary,
            ),
          ),
          // 长按菜单用**系统样式**（平台外观 + 本地化文案，用户明确要求），
          // 只把「粘贴」换成 markdown 识别粘贴 —— 系统默认粘贴不解析块结构。
          contextMenuBuilder: (
            BuildContext menuContext,
            EditableTextState state,
          ) {
            final items = state.contextMenuButtonItems.map(
              (ContextMenuButtonItem item) {
                if (item.type != ContextMenuButtonType.paste) {
                  return item;
                }
                return ContextMenuButtonItem(
                  label: item.label,
                  type: item.type,
                  onPressed: () {
                    state.hideToolbar();
                    _pasteMarkdownInto(entry);
                  },
                );
              },
            ).toList();
            return AdaptiveTextSelectionToolbar.buttonItems(
              anchors: state.contextMenuAnchors,
              buttonItems: items,
            );
          },
        );
      },
    );
  }

  /// 粘贴：识别 markdown 块结构（语雀粘贴同款）。
  ///
  /// 剪贴板文本先过 [parseBlocks]：图片/附件行会独立成块。
  /// - 纯文本（绝大多数粘贴）：并入当前块光标处，行内语法交给
  ///   记号淡显与阅读渲染，快速路径不折腾块列表；
  /// - 含图片/附件行：文本头并入当前块，媒体行依次插入为独立块，
  ///   光标落到粘贴内容之后的文本块上（贴完接着写）。
  Future<void> _pasteMarkdownInto(_BlockEntry entry) async {
    final data = await Clipboard.getData('text/plain');
    final raw = data?.text;
    final controller = entry.controller;
    if (raw == null || raw.isEmpty || controller == null) {
      return;
    }
    _pushUndoNow();
    final pasted = parseBlocks(raw);
    final hasMedia = pasted.any((Block block) => block is! TextBlock);
    final selection = controller.selection;
    final start =
        selection.start < 0 ? controller.text.length : selection.start;
    final end = selection.end < 0 ? start : selection.end;

    if (!hasMedia) {
      final newText = controller.text.replaceRange(start, end, raw);
      _applyProgrammatic(
        entry,
        newText,
        selection: TextSelection.collapsed(offset: start + raw.length),
      );
      _scheduleSave();
      _endMutation();
      return;
    }

    final head =
        pasted.first is TextBlock ? (pasted.first as TextBlock).text : '';
    final newText = controller.text.replaceRange(start, end, head);
    _applyProgrammatic(
      entry,
      newText,
      selection: TextSelection.collapsed(offset: start + head.length),
    );

    final index = _entries.indexOf(entry);
    final rest = (head.isEmpty ? pasted : pasted.sublist(1))
        .where(
            (Block block) => !(block is TextBlock && block.text.trim().isEmpty))
        .toList();
    if (rest.isEmpty) {
      _scheduleSave();
      _endMutation();
      return;
    }
    final inserted = <_BlockEntry>[
      for (final Block block in rest) _entryFor(block),
    ];
    setState(() {
      _entries.insertAll(index + 1, inserted);
    });
    // 光标落到粘贴内容之后的最后一个文本块。
    for (final _BlockEntry e in inserted.reversed) {
      if (e.block is TextBlock) {
        _focusEntry(e);
        break;
      }
    }
    _scheduleSave();
    _endMutation();
  }

  /// 打开大图：捕获缩略图当前的全局矩形，微信式「从缩略图展开」。
  void _openImage(ImageBlock block, BuildContext blockContext) {
    Rect sourceRect = Rect.zero;
    final RenderObject? renderObject = blockContext.findRenderObject();
    if (renderObject is RenderBox &&
        renderObject.attached &&
        renderObject.hasSize) {
      sourceRect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    }
    Navigator.of(context).push(
      buildImageViewerRoute(
        sourceRect: sourceRect,
        absolutePath: _store.absoluteAssetPath(block.path),
        alt: block.alt,
        // 查看器长按删除：确认后 pop 回来再删块。
        onDelete: () {
          _removeImageBlock(block);
        },
      ),
    );
  }

  Future<void> _showImageActions(ImageBlock block) async {
    final action = await showXiaojiSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) {
        final colors = AppColors.of(sheetContext);
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              InkWell(
                onTap: () => Navigator.of(sheetContext).pop('replace'),
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.swap_horiz, size: 20, color: colors.text),
                      const SizedBox(width: 14),
                      Text(
                        '替换图片',
                        style: TextStyle(fontSize: 16, color: colors.text),
                      ),
                    ],
                  ),
                ),
              ),
              InkWell(
                onTap: () => Navigator.of(sheetContext).pop('delete'),
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.delete_outline,
                          size: 20, color: colors.danger),
                      const SizedBox(width: 14),
                      Text(
                        '删除图片',
                        style: TextStyle(fontSize: 16, color: colors.danger),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
    if (action == null || !mounted) {
      return;
    }
    if (action == 'replace') {
      await _replaceImage(block);
    } else if (action == 'delete') {
      await _removeImageBlock(block);
    }
  }

  Future<void> _replaceImage(ImageBlock block) async {
    try {
      final XFile? file = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 92,
      );
      if (file == null) {
        return;
      }
      final relative = await _store.importAttachment(
        noteId: _id,
        sourcePath: file.path,
      );
      // 旧文件不主动删：它还可能在别的笔记里被引用（比如复制粘贴过来的块）。
      // 换成新路径即可，占空间但绝不误删用户数据。
      setState(() {
        block.path = relative;
      });
      await _persist();
    } catch (error) {
      _showMessage('替换图片失败：$error');
    }
  }

  Future<void> _removeImageBlock(ImageBlock block) async {
    _pushUndoNow();
    setState(() {
      _entries.removeWhere((item) => identical(item.block, block));
    });
    // 附件文件本身保留：用户可能只是不想在正文里显示这张图。
    if (!mounted) {
      return;
    }
    if (!_entries.any((item) => item.block is TextBlock)) {
      setState(() {
        _entries.add(_createTextEntry(''));
      });
    }
    await _persist();
    _endMutation();
  }

  Future<void> _confirmRemoveBlock(_BlockEntry entry) async {
    final confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '从正文移除这个附件？',
      message: '文件仍会留在 Xiaoji/assets 目录里。',
      confirmLabel: '移除',
    );
    if (confirmed != true || !mounted) {
      return;
    }
    _pushUndoNow();
    setState(() {
      _entries.remove(entry);
    });
    if (!_entries.any((item) => item.block is TextBlock)) {
      setState(() {
        _entries.add(_createTextEntry(''));
      });
    }
    await _persist();
    _endMutation();
  }
}
