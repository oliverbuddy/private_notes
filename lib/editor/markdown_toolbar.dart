import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 工具条能发出的命令。
///
/// 分两类，和入口位置一一对应：
/// - 块级（[paragraph] 到 [quote]）：改变整行结构，放在**底栏**；
/// - 行内（[bold] 到 [link]）：只作用于选中文字，收在 **Aa 面板**里。
///
/// 之所以要分家：底栏横排十二个图标一屏放不下，只能靠横滑，而横滑没有任何
/// 视觉暗示；语雀把行内格式收进 Aa 一层后，底栏只剩五个，全部一屏可见。
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

/// 工具条上方的二级面板（语雀式的「就地展开」，不是弹层）。
///
/// 之前 Aa / 插入都是 modal 底部弹层：点一次样式就关掉、要连点两次加粗+斜体
/// 就得反复开关；弹层还会抢走编辑器焦点，命令执行前得先恢复选区（一整条
/// 状态机）。改成贴在工具条上方的就地面板后：
///  - 键盘与光标不动，命令直接作用在当前选区；
///  - Aa 面板保持展开，可以连续点多个样式，再点 Aa 或收起键盘关闭；
///  - 插入面板选完即收起（插入是「一次性」动作，和语雀一致）。
enum MarkdownToolbarPanel { none, textStyle, insert, attach }

/// 附件面板里的动作。
enum MarkdownAttachAction { camera, gallery, file }

/// 贴在键盘上方的编辑工具条。
///
/// 结构对齐语雀小记：Aa（文字样式）、图片、待办、列表、引用五个高频入口
/// 均匀铺满，右侧「收起键盘」。没有「完成」按钮 —— 单态编辑器自动保存常驻，
/// 收起键盘即回到浏览，不存在要「提交」的状态。
/// 代码块、分隔线、缩进是低频插入，收进「列表」弹层 —— 底栏只留高频，
/// 这是 2026-11 排布调研（语雀/Notion/飞书）后的定案。
/// 撤销 / 重做不在这里：它们是文档级动作，放在详情页右上角。
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
          // 陈列逻辑对齐语雀：左边格式区均匀分布，细分隔线分组，
          // 右边是文档级动作（撤销 / 重做 / 收键盘）。
          child: Row(
            children: <Widget>[
              _formatArea(context),
              // 分组分隔线：格式区与动作区在视觉上分成两组。
              Container(
                width: 0.5,
                height: 24,
                color: colors.divider,
              ),
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

/// 附件面板：拍照 / 相册 / 文件 三个入口，一行三列。
///
/// 和 Aa / 插入同一套语言：就地展开、不抢焦点、不关键盘；选完即收起并
/// 打开系统选择器（这一步系统必然会切走焦点，属于预期）。
class MarkdownAttachPanel extends StatelessWidget {
  const MarkdownAttachPanel({super.key, required this.onPick});

  /// 面板高度：外层按它给正文预留空间。
  static const double height = 88;

  final ValueChanged<MarkdownAttachAction> onPick;

  static const List<(MarkdownAttachAction, IconData, String)> _items =
      <(MarkdownAttachAction, IconData, String)>[
    (MarkdownAttachAction.camera, Icons.photo_camera_outlined, '拍照'),
    (MarkdownAttachAction.gallery, Icons.photo_library_outlined, '相册'),
    (MarkdownAttachAction.file, Icons.attach_file, '文件'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colors.page,
        border: Border(top: BorderSide(color: colors.divider, width: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < _items.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: _ActionCell(
                icon: _items[i].$2,
                label: _items[i].$3,
                selected: false,
                onTap: () => onPick(_items[i].$1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Aa 面板：块级样式（真实字号预览）+ 行内格式一行 toggle。
///
/// 就地展开在工具条上方（不抢焦点、不关键盘），点样式立即生效；
/// 面板保持展开，可以连续点「加粗 + 斜体」。
class MarkdownTextStylePanel extends StatelessWidget {
  const MarkdownTextStylePanel({
    super.key,
    required this.active,
    required this.onPick,
  });

  /// 面板固定高度：外层按它给正文预留空间，避免面板盖住最后几行。
  /// 内容实测 118.5（标题行 66 + 分隔线 0.5 + 行内行 52），留 1.5 余量。
  static const double height = 122;

  final Set<MarkdownCommand> active;
  final ValueChanged<MarkdownCommand> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colors.page,
        border: Border(top: BorderSide(color: colors.divider, width: 0.5)),
      ),
      child: Column(
        children: <Widget>[
          _HeadingRow(active: active, onPicked: onPick),
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 20),
            child: Container(height: 0.5, color: colors.divider),
          ),
          _InlineFormatRow(active: active, onPicked: onPick),
        ],
      ),
    );
  }
}

/// 插入面板：无序/有序/分隔线/代码块/缩进/减少缩进，两行三列。
class MarkdownInsertPanel extends StatelessWidget {
  const MarkdownInsertPanel({
    super.key,
    required this.active,
    required this.onPick,
  });

  /// 面板固定高度（与 [MarkdownTextStylePanel] 同源，用于正文预留）。
  /// 内容实测 136（上下 8 + 两行 56 + 间隔 8），留 2 余量。
  static const double height = 138;

  final Set<MarkdownCommand> active;
  final ValueChanged<MarkdownCommand> onPick;

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
        border: Border(top: BorderSide(color: colors.divider, width: 0.5)),
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
    ('正文', 16, false, MarkdownCommand.paragraph),
    ('H1', 20, true, MarkdownCommand.h1),
    ('H2', 18, true, MarkdownCommand.h2),
    ('H3', 16.5, true, MarkdownCommand.h3),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          for (final (label, fontSize, bold, command) in _items)
            _HeadingCell(
              label: label,
              fontSize: fontSize,
              bold: bold,
              selected: command == MarkdownCommand.paragraph
                  ? !active.any(
                      (MarkdownCommand c) =>
                          c == MarkdownCommand.h1 ||
                          c == MarkdownCommand.h2 ||
                          c == MarkdownCommand.h3,
                    )
                  : active.contains(command),
              onTap: () => onPicked(command),
            ),
        ],
      ),
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
      borderRadius: BorderRadius.circular(10),
      child: Container(
        // H1 的 21px 是最高的，行高按它撑起，其余居中。
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? colors.accentBg : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? colors.chipBorderSelected : colors.chipBorder,
            width: 0.5,
          ),
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
    final foreground = selected ? colors.accent : colors.text;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        // 与 Aa 面板的标题卡同高，两个面板叠起来切换时不会跳。
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? colors.accentBg : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? colors.chipBorderSelected : colors.chipBorder,
            width: 0.5,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 20, color: foreground),
            const SizedBox(height: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
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
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? colors.accentBg : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: showClose
            ? Icon(Icons.close, size: 20, color: colors.accent)
            : Text(
                'Aa',
                style: TextStyle(
                  fontSize: 15,
                  height: 1,
                  fontWeight: AppWeight.semibold,
                  color: selected ? colors.accent : colors.text,
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
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: selected ? colors.accentBg : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 21,
          color: selected ? colors.accent : colors.text,
        ),
      ),
    );
  }
}

/// 固定动作按钮（收起键盘）：不做切换态，用次要色和格式按钮区分开。
class _FixedButton extends StatelessWidget {
  const _FixedButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        child: Icon(icon, size: 21, color: colors.secondary),
      ),
    );
  }
}

/// Aa 面板里的行内格式一行：粗体 / 斜体 / 删除线 / 行内码 / 链接。
///
/// 从底栏和已废弃的选区气泡迁到这里 —— 语雀把所有文字样式收在 Aa 一层。
/// 激活态只在「选区两侧正好是记号」时点亮（光标折叠不猜，猜错比不亮困惑）。
class _InlineFormatRow extends StatelessWidget {
  const _InlineFormatRow({required this.active, required this.onPicked});

  final Set<MarkdownCommand> active;
  final ValueChanged<MarkdownCommand> onPicked;

  static const List<(MarkdownCommand, IconData)> _items =
      <(MarkdownCommand, IconData)>[
    (MarkdownCommand.bold, Icons.format_bold),
    (MarkdownCommand.italic, Icons.format_italic),
    (MarkdownCommand.strike, Icons.strikethrough_s),
    (MarkdownCommand.code, Icons.code),
    (MarkdownCommand.link, Icons.link),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          for (final (command, icon) in _items)
            InkWell(
              onTap: () => onPicked(command),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: active.contains(command)
                      ? colors.accentBg
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: active.contains(command)
                      ? colors.accent
                      : colors.text,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
