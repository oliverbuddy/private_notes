import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 工具条能发出的命令。
///
/// 受控模式（小记详情页）下全部收在 **Aa 面板**，按四组排列：
/// - 标题（[paragraph] / [h1] / [h2] / [h3]）；
/// - 段落（[todo] / [bullet] / [ordered] / [quote]）；
/// - 文字（[bold] / [italic] / [strike] / [code] / [link]）；
/// - 结构（[divider] / [codeBlock] / [indent] / [outdent]）。
///
/// 底栏只留 ＋（媒体）、Aa、标签、撤销、还原、收键盘 —— 高频入口一屏可见，
/// 低频格式都进 Aa 一层，不用横滑（横滑没有视觉暗示，用户找不到）。
/// 非受控模式（旧编辑器）仍按原样把块级命令放在底栏，不受影响。
enum MarkdownCommand {
  paragraph,
  h1,
  h2,
  h3,
  todo,
  bullet,
  ordered,
  quote,
  bold,
  italic,
  strike,
  code,
  link,
  codeBlock,
  divider,
  indent,
  outdent,
}

/// 工具条下方的二级面板（语雀式的「就地展开」，不是弹层）。
///
/// 之前 Aa / 插入都是 modal 底部弹层：点一次样式就关掉、要连点两次加粗+斜体
/// 就得反复开关；弹层还会抢走编辑器焦点，命令执行前得先恢复选区（一整条
/// 状态机）。改成铺在原键盘区域的就地面板后：
///  - 键盘与光标不动，命令直接作用在当前选区；
///  - Aa 面板保持展开，可以连续点多个样式，再点 Aa 或收起键盘关闭；
///  - ＋ 面板选完即收起（插入媒体是「一次性」动作，和语雀一致）。
enum MarkdownToolbarPanel { none, textStyle, insert, attach }

/// 附件面板里的动作。
enum MarkdownAttachAction { camera, gallery, file }

/// 贴在键盘上方的编辑工具条。
///
/// 新版（受控模式，小记详情页）分三组：＋添加 / Aa 字体样式 / 标签
/// ｜撤销 / 还原｜收起键盘 —— 对齐滴答清单/语雀的「高频入口一屏可见」。
/// 待办/列表/引用/代码块/分隔线/缩进这些低频格式全部收进 Aa 面板，
/// ＋ 只负责媒体（相册/拍照/文件），内容与排版二分。
/// 旧版（非受控模式）保持原有五按钮布局，旧编辑器不受影响。
class MarkdownToolbar extends StatefulWidget {
  const MarkdownToolbar({
    super.key,
    required this.onCommand,
    required this.onAttachAction,
    required this.onHideKeyboard,
    this.onPanelOpening,
    this.panelHeight,
    this.active = const <MarkdownCommand>{},
    this.panel,
    this.onPanelToggle,
    this.onEditTags,
    this.onUndo,
    this.onRedo,
    this.canUndo = false,
    this.canRedo = false,
  });

  final ValueChanged<MarkdownCommand> onCommand;

  /// 附件面板里选了某个动作（拍照/相册/文件）。
  final ValueChanged<MarkdownAttachAction> onAttachAction;

  /// 收起键盘并回到浏览态（自动保存照常进行）。
  final VoidCallback onHideKeyboard;

  /// 弹层即将打开时回调（showXiaojiSheet 之前）。
  ///
  /// modal 一打开焦点就转移，编辑器选区会被折叠成末尾光标；调用方
  /// 必须在这一刻冻结选区快照，关闭后才能恢复出「用户原本选中的一段」。
  final VoidCallback? onPanelOpening;

  /// 二级面板展开时的高度（0 = 未展开）。
  ///
  /// 非受控模式下：面板叠在工具条上方，页面拿这个值给正文底部预留空间，
  /// 避免面板盖住最后几行。受控模式由页面自己排版面板，不会写这个值。
  final ValueNotifier<double>? panelHeight;

  /// 当前光标所处行的块级格式，用于按钮激活态。
  final Set<MarkdownCommand> active;

  /// 受控模式的当前子菜单（null/未传 = 非受控，保持旧行为）。
  ///
  /// 受控模式下工具条只画按钮行，面板由页面自己渲染在**工具条下方**
  /// （语雀的做法：隐藏输入法，面板铺在原键盘区域，工具条位置不动）。
  final MarkdownToolbarPanel? panel;

  /// 受控模式的子菜单开关回调。
  final ValueChanged<MarkdownToolbarPanel>? onPanelToggle;

  /// 点「标签」：打开标签编辑弹层（仅受控模式显示）。
  final VoidCallback? onEditTags;

  /// 撤销 / 还原。
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;

  /// 撤销 / 还原是否可用（无历史时置灰但保留占位）。
  final bool canUndo;
  final bool canRedo;

  @override
  State<MarkdownToolbar> createState() => _MarkdownToolbarState();
}

class _MarkdownToolbarState extends State<MarkdownToolbar> {
  MarkdownToolbarPanel _panel = MarkdownToolbarPanel.none;

  Set<MarkdownCommand> get active => widget.active;

  /// 是否由页面托管面板（此时本组件不渲染面板、不写 panelHeight）。
  bool get _controlled => widget.onPanelToggle != null;

  MarkdownToolbarPanel get _effectivePanel =>
      _controlled ? (widget.panel ?? MarkdownToolbarPanel.none) : _panel;

  void _setPanel(MarkdownToolbarPanel panel) {
    if (_controlled) {
      if (_effectivePanel != panel) {
        widget.onPanelToggle!(panel);
      }
      return;
    }
    if (_panel == panel) {
      return;
    }
    setState(() => _panel = panel);
    widget.panelHeight?.value = switch (panel) {
      MarkdownToolbarPanel.none => 0,
      MarkdownToolbarPanel.textStyle => MarkdownTextStylePanel.height,
      MarkdownToolbarPanel.insert => MarkdownInsertPanel.height,
      MarkdownToolbarPanel.attach => MarkdownAttachPanel.height,
    };
  }

  bool _isHeadingActive() {
    return active.contains(MarkdownCommand.h1) ||
        active.contains(MarkdownCommand.h2) ||
        active.contains(MarkdownCommand.h3);
  }

  /// 格式区：空间够时图标均匀分布（语雀的陈列逻辑），窄屏退回横滑兜底。
  ///
  /// 陈列对齐语雀：底栏只放**块级插入**（图片/待办/列表/引用），
  /// 文字样式（粗斜删/行内码/链接）收进「Aa」面板 —— 和语雀一样，
  /// 底栏一屏可见、Aa 一层兜住所有样式。加粗不再占底栏位置。
  Widget _formatArea(BuildContext context) {
    final buttons = <Widget>[
      _ToolButton(
        // 「+」而不是图片图标：这一层是「添加内容」的总入口（拍照/相册/
        // 文件），用图片图标会让人以为只能插图（用户反馈）。
        icon: _effectivePanel == MarkdownToolbarPanel.attach
            ? Icons.close
            : Icons.add,
        selected: _effectivePanel == MarkdownToolbarPanel.attach,
        onTap: () => _setPanel(
          _effectivePanel == MarkdownToolbarPanel.attach
              ? MarkdownToolbarPanel.none
              : MarkdownToolbarPanel.attach,
        ),
      ),
      _ToolButton(
        icon: Icons.check_box_outlined,
        selected: active.contains(MarkdownCommand.todo),
        onTap: () => widget.onCommand(MarkdownCommand.todo),
      ),
      _ToolButton(
        // 展开时变成「×」：再点一下就是关闭当前子菜单（用户反馈的交互）。
        icon: _effectivePanel == MarkdownToolbarPanel.insert
            ? Icons.close
            : Icons.format_list_bulleted,
        selected: active.contains(MarkdownCommand.bullet) ||
            active.contains(MarkdownCommand.ordered) ||
            _effectivePanel == MarkdownToolbarPanel.insert,
        onTap: () => _setPanel(
          _effectivePanel == MarkdownToolbarPanel.insert
              ? MarkdownToolbarPanel.none
              : MarkdownToolbarPanel.insert,
        ),
      ),
      _ToolButton(
        icon: Icons.format_quote_rounded,
        selected: active.contains(MarkdownCommand.quote),
        onTap: () => widget.onCommand(MarkdownCommand.quote),
      ),
      // 「Aa」用文字不用图标：语雀的做法，比任何图标都直观。
      // 面板展开时同样变成「×」，与另外两个入口一致。
      _TextToolButton(
        selected:
            _isHeadingActive() || _effectivePanel == MarkdownToolbarPanel.textStyle,
        showClose: _effectivePanel == MarkdownToolbarPanel.textStyle,
        onTap: () => _setPanel(
          _effectivePanel == MarkdownToolbarPanel.textStyle
              ? MarkdownToolbarPanel.none
              : MarkdownToolbarPanel.textStyle,
        ),
      ),
    ];

    return Expanded(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 5 个 40dp 按钮 + 两侧最小呼吸边距。低于这个宽度（罕见的老设备）
          // 才启用横滑；正常机型 spaceEvenly 铺满，与语雀一致。
          const minWidth = 5 * 40 + 8;
          if (constraints.maxWidth >= minWidth) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: buttons,
            );
          }
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: Row(children: buttons),
          );
        },
      ),
    );
  }

  /// 受控模式（详情页）的按钮行：内容组（＋ / Aa / 标签）+ 历史组 + 收键盘。
  ///
  /// 分组依据是**语义**而不是「凑一行」：
  ///  - 左侧内容组：往正文里加东西（插入、排版、标签），拇指最容易够到；
  ///  - 中间历史组：撤销/还原，紧邻右侧、不与插入混在一起；
  ///  - 右侧收键盘：退出编辑的唯一出口，永远在最外侧。
  /// 每组内部 8dp 等距，组间用 0.5dp 竖线分隔，视觉上是三块而不是一排。
  Widget _controlledToolbarRow(BuildContext context, AppColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: <Widget>[
          _ToolButton(
            icon: _effectivePanel == MarkdownToolbarPanel.attach
                ? Icons.close
                : Icons.add,
            selected: _effectivePanel == MarkdownToolbarPanel.attach,
            onTap: () => _setPanel(
              _effectivePanel == MarkdownToolbarPanel.attach
                  ? MarkdownToolbarPanel.none
                  : MarkdownToolbarPanel.attach,
            ),
          ),
          const SizedBox(width: 8),
          _TextToolButton(
            selected: _isHeadingActive() ||
                _effectivePanel == MarkdownToolbarPanel.textStyle,
            showClose: _effectivePanel == MarkdownToolbarPanel.textStyle,
            onTap: () => _setPanel(
              _effectivePanel == MarkdownToolbarPanel.textStyle
                  ? MarkdownToolbarPanel.none
                  : MarkdownToolbarPanel.textStyle,
            ),
          ),
          const SizedBox(width: 8),
          _ToolButton(
            icon: Icons.sell_outlined,
            onTap: widget.onEditTags ?? () {},
          ),
          // 中间弹性空白：内容组贴左（拇指区），历史组贴右，
          // 两侧各占一块，不再把五个按钮均匀撒满整条。
          const Spacer(),
          _FixedButton(
            icon: Icons.undo,
            enabled: widget.canUndo,
            onTap: widget.onUndo,
          ),
          _FixedButton(
            icon: Icons.redo,
            enabled: widget.canRedo,
            onTap: widget.onRedo,
          ),
          _GroupDivider(color: colors.divider),
          _FixedButton(
            icon: Icons.keyboard_hide_outlined,
            onTap: widget.onHideKeyboard,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    final Widget toolbarRow = Container(
      decoration: BoxDecoration(
        color: colors.page,
        border: Border(top: BorderSide(color: colors.divider, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          // 受控模式按语义分三组（见 [_controlledToolbarRow]）；
          // 非受控模式保持旧陈列（格式区均匀分布 + 收键盘）。
          child: _controlled
              ? _controlledToolbarRow(context, colors)
              : Row(
                  children: <Widget>[
                    _formatArea(context),
                    _GroupDivider(color: colors.divider),
                    _FixedButton(
                      icon: Icons.keyboard_hide_outlined,
                      onTap: widget.onHideKeyboard,
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
        ),
      ),
    );

    // 受控模式（小记详情页）：面板由页面渲染在工具条**下方**（原键盘
    // 区域），这里只返回按钮行，保证工具条位置不随面板移动。
    if (_controlled) {
      return toolbarRow;
    }

    // 非受控模式（旧编辑器）：二级面板叠在工具条上方，整列底部对齐，
    // 面板向上展开，不改变工具条本身的高度（它始终是页面底部的一条浮层）。
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (_panel == MarkdownToolbarPanel.textStyle)
          MarkdownTextStylePanel(
            active: active,
            onPick: widget.onCommand,
          )
        else if (_panel == MarkdownToolbarPanel.insert)
          MarkdownInsertPanel(
            active: active,
            onPick: (MarkdownCommand command) {
              // 插入是一次性动作：选完即收起（语雀同款）。
              _setPanel(MarkdownToolbarPanel.none);
              widget.onCommand(command);
            },
          )
        else if (_panel == MarkdownToolbarPanel.attach)
          MarkdownAttachPanel(
            onPick: (MarkdownAttachAction action) {
              // 选完即收起面板，再把系统选择器打开。
              _setPanel(MarkdownToolbarPanel.none);
              // 系统选择器会抢焦点：先冻结当前选区，选完才能插回原位。
              widget.onPanelOpening?.call();
              widget.onAttachAction(action);
            },
          ),
        toolbarRow,
      ],
    );
  }
}

/// 「＋」添加面板：只承载媒体入口（相册 / 拍照 / 文件）。
///
/// 用户确认的分工：**内容与排版二分**
///  - ＋：往正文里插入媒体（图片、拍照、文件）；
///  - Aa：全部 Markdown 排版（标题 / 段落 / 文字 / 结构）。
/// 分隔线、代码块、缩进属于排版结构，不再混在「添加」里。
///
/// 只有三项时用三张**均分整宽的大卡**（图标 26 + 文字 13，高 104），
/// 三项铺满一行，不会像小图标那样缩在角落、下面留一大片空白。
class MarkdownAttachPanel extends StatelessWidget {
  const MarkdownAttachPanel({
    super.key,
    required this.onPick,
    this.showTopDivider = true,
  });

  /// 面板高度：上下留白 8×2 + 单行大卡 104。
  static const double height = 120;

  final ValueChanged<MarkdownAttachAction> onPick;

  /// 是否画顶部分隔线。
  ///
  /// 非受控模式下面板叠在工具条**上方**，需要一条线把它和正文分开；
  /// 受控模式（小记详情页）下面板铺在工具条下方的键盘区域里，本身已经
  /// 是独立的一块白面，再画一条线就变成「工具栏下面多出一道横线」。
  final bool showTopDivider;

  static const List<(MarkdownAttachAction, IconData, String)> _mediaItems =
      <(MarkdownAttachAction, IconData, String)>[
    (MarkdownAttachAction.gallery, Icons.photo_library_outlined, '相册'),
    (MarkdownAttachAction.camera, Icons.photo_camera_outlined, '拍照'),
    (MarkdownAttachAction.file, Icons.attach_file, '文件'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      height: height,
      // 面板与工具条同用 page 底色，视觉上是一条连续的白面；卡片用
      // pageAlt（浅暖灰）承担「可按压」的表面层级，选中才换主色浅底。
      decoration: BoxDecoration(
        color: colors.page,
        border: showTopDivider
            ? Border(top: BorderSide(color: colors.divider, width: 0.5))
            : null,
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      // 与 Aa 面板共用同一套「左侧分组名 + 右侧卡片行」结构：
      // 两边只有卡片高度不同（这里是大卡），分组名、页边距、卡片表面
      // 与圆角完全一致，切换面板时不会像换了一套控件。
      child: _PanelGroupRow(
        label: '插入',
        height: 104,
        child: Row(
          children: <Widget>[
            for (var i = 0; i < _mediaItems.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: _MediaCard(
                  icon: _mediaItems[i].$2,
                  label: _mediaItems[i].$3,
                  onTap: () => onPick(_mediaItems[i].$1),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// ＋ 面板里的大卡：与 Aa 动作卡同一套表面（pageAlt / 12 圆角）。
class _MediaCard extends StatelessWidget {
  const _MediaCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Material(
      // 浅暖灰卡面：与 Aa 面板的动作卡共用同一层表面色，两套子菜单
      // 看起来是同一套控件语言（而不是「白卡 + 无底图标」两种风格）。
      color: colors.pageAlt,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 104,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                icon,
                size: 24,
                color: colors.text.withValues(alpha: 0.78),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  height: 1,
                  letterSpacing: 0.2,
                  color: colors.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Aa 面板：全部 Markdown 排版，按「标题 / 段落 / 文字 / 结构」四组。
///
/// 用户确认的组织方式：**左侧分组标签 + 右侧单行动作**。
/// 相比「上下分组标题 + 卡片行」，四组只占 4×48dp，一屏放下不用滚动，
/// 也不会像键盘格一样铺满；分组名固定成一条左对齐的窄列，视线从上到
/// 下一扫就能找到目标类别。
class MarkdownTextStylePanel extends StatelessWidget {
  const MarkdownTextStylePanel({
    super.key,
    required this.active,
    required this.onPick,
    this.showTopDivider = true,
  });

  /// 面板固定高度：4 行 × 56 + 上下留白 8×2。
  static const double height = 240;

  final Set<MarkdownCommand> active;
  final ValueChanged<MarkdownCommand> onPick;

  /// 见 [MarkdownAttachPanel.showTopDivider]。
  final bool showTopDivider;

  /// 段落格式：待办 / 无序 / 有序 / 引用。
  static const List<(MarkdownCommand, IconData, String)> _blockItems =
      <(MarkdownCommand, IconData, String)>[
    (MarkdownCommand.todo, Icons.check_box_outlined, '待办'),
    (MarkdownCommand.bullet, Icons.format_list_bulleted, '无序'),
    (MarkdownCommand.ordered, Icons.format_list_numbered, '有序'),
    (MarkdownCommand.quote, Icons.format_quote_rounded, '引用'),
  ];

  /// 行内样式：加粗 / 斜体 / 删除线 / 行内码 / 链接。
  static const List<(MarkdownCommand, IconData, String)> _inlineItems =
      <(MarkdownCommand, IconData, String)>[
    (MarkdownCommand.bold, Icons.format_bold, '加粗'),
    (MarkdownCommand.italic, Icons.format_italic, '斜体'),
    (MarkdownCommand.strike, Icons.strikethrough_s, '删除线'),
    (MarkdownCommand.code, Icons.code, '行内码'),
    (MarkdownCommand.link, Icons.link, '链接'),
  ];

  /// 结构：分隔线 / 代码块 / 缩进 / 减少缩进（原「＋ → 插入块」）。
  static const List<(MarkdownCommand, IconData, String)> _structureItems =
      <(MarkdownCommand, IconData, String)>[
    (MarkdownCommand.divider, Icons.horizontal_rule, '分隔线'),
    (MarkdownCommand.codeBlock, Icons.code_rounded, '代码块'),
    (MarkdownCommand.indent, Icons.format_indent_increase, '缩进'),
    (MarkdownCommand.outdent, Icons.format_indent_decrease, '减少缩进'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colors.page,
        border: showTopDivider
            ? Border(top: BorderSide(color: colors.divider, width: 0.5))
            : null,
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      // 小屏 / 横屏的键盘区域可能比面板矮：允许纵向滚动，避免溢出。
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _PanelGroupRow(
              label: '标题',
              child: _HeadingRow(active: active, onPicked: onPick),
            ),
            _PanelGroupRow(
              label: '段落',
              child: _ActionRow(
                items: _blockItems,
                active: active,
                onPicked: onPick,
              ),
            ),
            _PanelGroupRow(
              label: '文字',
              child: _ActionRow(
                items: _inlineItems,
                active: active,
                onPicked: onPick,
              ),
            ),
            _PanelGroupRow(
              label: '结构',
              child: _ActionRow(
                items: _structureItems,
                active: active,
                onPicked: onPick,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分组行：左侧固定宽度的分组名 + 右侧单行动作。
class _PanelGroupRow extends StatelessWidget {
  const _PanelGroupRow({
    required this.label,
    required this.child,
    this.height = 56,
  });

  /// 分组名栏宽：两个字（12px）加一点余量，全部左缘对齐。
  static const double labelWidth = 36;

  final String label;
  final Widget child;

  /// 行高：Aa 面板 56（48 卡片 + 呼吸），＋ 面板传 104（大卡）。
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return SizedBox(
      height: height,
      child: Row(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 10),
            child: SizedBox(
              width: labelWidth,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  height: 1,
                  letterSpacing: 0.4,
                  fontWeight: AppWeight.medium,
                  color: colors.secondary,
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// 四列动作卡一行（块格式 / 插入），与 Aa 面板其它行的卡片同一规格。
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.items,
    required this.active,
    required this.onPicked,
  });

  final List<(MarkdownCommand, IconData, String)> items;
  final Set<MarkdownCommand> active;
  final ValueChanged<MarkdownCommand> onPicked;

  @override
  Widget build(BuildContext context) {
    // 等宽卡片：四/五列都用同一套网格，行与行、组与组之间对齐，
    // 而不是「图标挤在左边、右边一大片空白」。
    return Row(
      children: <Widget>[
        for (var i = 0; i < items.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: _ActionCell(
              icon: items[i].$2,
              label: items[i].$3,
              selected: active.contains(items[i].$1),
              onTap: () => onPicked(items[i].$1),
            ),
          ),
        ],
      ],
    );
  }
}

/// 插入面板：无序/有序/分隔线/代码块/缩进/减少缩进，两行三列。
class MarkdownInsertPanel extends StatelessWidget {
  const MarkdownInsertPanel({
    super.key,
    required this.active,
    required this.onPick,
    this.showTopDivider = true,
  });

  /// 面板固定高度（与 [MarkdownTextStylePanel] 同源，用于正文预留）。
  /// 上下 8 + 两行 44 + 间隔 8 + 0.5 顶部分隔线（留足余量）。
  static const double height = 130;

  final Set<MarkdownCommand> active;
  final ValueChanged<MarkdownCommand> onPick;

  /// 见 [MarkdownAttachPanel.showTopDivider]。
  final bool showTopDivider;

  static const List<(MarkdownCommand, IconData, String)> _items =
      <(MarkdownCommand, IconData, String)>[
    (MarkdownCommand.bullet, Icons.format_list_bulleted, '无序'),
    (MarkdownCommand.ordered, Icons.format_list_numbered, '有序'),
    (MarkdownCommand.divider, Icons.horizontal_rule, '分隔线'),
    (MarkdownCommand.codeBlock, Icons.code_rounded, '代码块'),
    (MarkdownCommand.indent, Icons.format_indent_increase, '缩进'),
    (MarkdownCommand.outdent, Icons.format_indent_decrease, '减少缩进'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    Widget row(List<(MarkdownCommand, IconData, String)> rowItems) {
      return Row(
        children: <Widget>[
          for (var i = 0; i < rowItems.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: _ActionCell(
                icon: rowItems[i].$2,
                label: rowItems[i].$3,
                selected: active.contains(rowItems[i].$1),
                onTap: () => onPick(rowItems[i].$1),
              ),
            ),
          ],
        ],
      );
    }

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colors.page,
        border: showTopDivider
            ? Border(top: BorderSide(color: colors.divider, width: 0.5))
            : null,
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          row(_items.sublist(0, 3)),
          const SizedBox(height: 8),
          row(_items.sublist(3)),
        ],
      ),
    );
  }
}

/// 块级样式横排：`正文 / H1 / H2 / H3`，各按真实字号与字重渲染。
///
/// 用户习惯用 H1/H2/H3 称呼标题（和桌面编辑器一致），横排一行的信息密度
/// 也比纵列高 —— 面板总高度从 5 行降到 2 行。
class _HeadingRow extends StatelessWidget {
  const _HeadingRow({required this.active, required this.onPicked});

  final Set<MarkdownCommand> active;
  final ValueChanged<MarkdownCommand> onPicked;

  static const List<(String, double, bool, MarkdownCommand)> _items =
      <(String, double, bool, MarkdownCommand)>[
    ('正文', 15, false, MarkdownCommand.paragraph),
    ('H1', 17, true, MarkdownCommand.h1),
    ('H2', 16, true, MarkdownCommand.h2),
    ('H3', 15, true, MarkdownCommand.h3),
  ];

  @override
  Widget build(BuildContext context) {
    // 外层 [_PanelGroupRow] 已负责左右页边距。等宽四列，与其它行同一网格。
    return Row(
      children: <Widget>[
        for (var i = 0; i < _items.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: _HeadingCell(
              label: _items[i].$1,
              fontSize: _items[i].$2,
              bold: _items[i].$3,
              selected: _items[i].$4 == MarkdownCommand.paragraph
                  ? !active.any(
                      (MarkdownCommand c) =>
                          c == MarkdownCommand.h1 ||
                          c == MarkdownCommand.h2 ||
                          c == MarkdownCommand.h3,
                    )
                  : active.contains(_items[i].$4),
              onTap: () => onPicked(_items[i].$4),
            ),
          ),
        ],
      ],
    );
  }
}

class _HeadingCell extends StatelessWidget {
  const _HeadingCell({
    required this.label,
    required this.fontSize,
    required this.bold,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final double fontSize;
  final bool bold;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        // 与动作卡同高同宽：标题行也落在同一套网格里，不再「文字大小
        // 各占一块、和下面的图标行对不齐」。
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        // 未选中铺一层浅暖灰卡面，选中换主色浅底：整行读起来是一组
        // 可按压的分段控件，而不是几段孤立的文字。
        decoration: BoxDecoration(
          color: selected ? colors.accentBg : colors.pageAlt,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: fontSize,
            height: 1.1,
            fontWeight: bold ? AppWeight.semibold : AppWeight.regular,
            color: selected ? colors.accent : colors.text,
          ),
        ),
      ),
    );
  }
}

/// 插入弹层里的动作卡：图标 + 小字标签，规格与 [_HeadingCell] 一致
/// （同高度、同描边、同选中色），两个弹层看起来是同一套控件。
class _ActionCell extends StatelessWidget {
  const _ActionCell({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // 未选中用「正文色的弱化版」而不是 secondary：secondary 在浅底上
    // 太淡，整组按钮看起来像禁用。弱化正文色仍保留可点的暗示。
    final foreground =
        selected ? colors.accent : colors.text.withValues(alpha: 0.78);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        // 与标题卡同高同宽：图标行与标题行完全对齐。
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? colors.accentBg : colors.pageAlt,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 20, color: foreground),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                height: 1,
                letterSpacing: 0.2,
                color: foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「Aa」按钮：文字比图标直观，激活态用 accentBg 底。
/// 面板展开时显示「×」（关闭入口），与列表/加号按钮的展开态一致。
class _TextToolButton extends StatelessWidget {
  const _TextToolButton({
    required this.selected,
    required this.onTap,
    this.showClose = false,
  });

  final bool selected;
  final VoidCallback onTap;
  final bool showClose;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? colors.accentBg : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: showClose
            ? Icon(Icons.close, size: 20, color: colors.accent)
            : Text(
                'Aa',
                style: TextStyle(
                  fontSize: 15,
                  height: 1,
                  fontWeight: AppWeight.semibold,
                  color: selected
                      ? colors.accent
                      : colors.text.withValues(alpha: 0.78),
                ),
              ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: selected ? colors.accentBg : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          size: 20,
          // 未选中用弱化正文色：纯黑太重，secondary 又像禁用，
          // 主色只留给「当前生效」的状态。
          color: selected
              ? colors.accent
              : colors.text.withValues(alpha: 0.72),
        ),
      ),
    );
  }
}

/// 工具条分组分隔线（0.5dp 竖线，高度 22）。
class _GroupDivider extends StatelessWidget {
  const _GroupDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Container(width: 0.5, height: 22, color: color),
    );
  }
}

/// 固定动作按钮（收起键盘 / 撤销 / 还原）：不做切换态。
///
/// [enabled] 为 false 时置灰且不响应点击（撤销/还原无历史时保留占位，
/// 避免按钮行左右抖动）。
class _FixedButton extends StatelessWidget {
  const _FixedButton({
    required this.icon,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 20,
          color: enabled ? colors.text.withValues(alpha: 0.72) : colors.tertiary,
        ),
      ),
    );
  }
}
