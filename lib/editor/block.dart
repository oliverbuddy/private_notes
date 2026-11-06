/// 正文的块模型。
///
/// 为什么需要块：Flutter 的 `TextField` 只能渲染文本，没法在文本流里插图片。
/// 于是把正文按行切成「文本块 / 图片块 / 文件块」，图片和文件由真正的 widget 渲染，
/// 文本块之间才用输入框。
///
/// 硬约束是**往返无损**：`serialize(parse(md)) == md`（只允许末尾换行归一化）。
/// 一旦有损，用户用外部编辑器打开笔记就会看到内容被悄悄改写。
library;

/// 独占一行的图片：`![alt](path)`。
///
/// 行尾容忍空白与 `\r`：笔记文件可能被 Windows 编辑器改过（CRLF），
/// 也可能被复制粘贴带上尾随空格。旧版正则卡死 `\)$`，这类行会退化成文本块，
/// 图片不渲染、列表也没缩略图 —— 内容没丢，但看起来像坏了。
///
/// 行首**不**容忍缩进：带缩进的图片语法通常处在列表/引用等上下文里，
/// 把它抽成独立 widget 反而会切碎那段文本。
final RegExp _imagePattern = RegExp(r'^!\[([^\]]*)\]\(([^)\s]+)\)([ \t\r]*)$');

/// 独占一行的文件链接：`[文件名](path)`，且 path 不是 http(s) 外链。
final RegExp _filePattern = RegExp(r'^\[([^\]]+)\]\(([^)\s]+)\)([ \t\r]*)$');

sealed class Block {
  const Block();

  /// 落盘时的单块文本（不含块间换行）。
  String get serialized;
}

/// 一段连续的行，原样保存 markdown 文本。
final class TextBlock extends Block {
  TextBlock([this.text = '']);

  String text;

  @override
  String get serialized => text;
}

/// 独占一行的图片。
final class ImageBlock extends Block {
  ImageBlock({required this.alt, required this.path, this.trailing = ''});

  String alt;

  /// 相对路径，形如 `assets/20261031-0912-a1b2/1.jpg`。
  /// 存相对路径而不是绝对路径：iOS 沙箱路径每次安装都会变，
  /// 绝对路径会让笔记一升级就全部失效。
  String path;

  /// 原文件里紧跟在 `)` 之后的行尾空白（含 CRLF 残留的 `\r`）。
  ///
  /// 捕获它而不是直接 trim 掉，是为了序列化时能原样吐回去：
  /// 用户在外部编辑器里留下的格式不该被 app 悄悄"修正"。
  final String trailing;

  @override
  String get serialized => '![$alt]($path)$trailing';
}

/// 独占一行的附件链接。
final class FileBlock extends Block {
  FileBlock({required this.name, required this.path, this.trailing = ''});

  String name;
  String path;

  /// 同 [ImageBlock.trailing]。
  final String trailing;

  @override
  String get serialized => '[$name]($path)$trailing';
}

/// 把 markdown 正文切成块。
///
/// 只有「整行恰好是图片/文件语法」才算块。行首带缩进的继续当文本，
/// 行尾的空白/`\r` 会被块记住并原样写回，所以 round-trip 不会被格式差异破坏。
List<Block> parseBlocks(String markdown) {
  final blocks = <Block>[];
  if (markdown.isEmpty) {
    blocks.add(TextBlock(''));
    return blocks;
  }

  final lines = markdown.split('\n');
  final buffer = <String>[];

  void flush() {
    if (buffer.isEmpty) {
      return;
    }
    blocks.add(TextBlock(buffer.join('\n')));
    buffer.clear();
  }

  for (final line in lines) {
    final image = _imagePattern.firstMatch(line);
    if (image != null) {
      flush();
      blocks.add(
        ImageBlock(
          alt: image.group(1)!,
          path: image.group(2)!,
          trailing: image.group(3) ?? '',
        ),
      );
      continue;
    }
    final file = _filePattern.firstMatch(line);
    if (file != null && !_isExternalLink(file.group(2)!)) {
      flush();
      blocks.add(
        FileBlock(
          name: file.group(1)!,
          path: file.group(2)!,
          trailing: file.group(3) ?? '',
        ),
      );
      continue;
    }
    buffer.add(line);
  }
  flush();

  if (blocks.isEmpty) {
    blocks.add(TextBlock(''));
  }
  return blocks;
}

/// 把块拼回 markdown 正文。
///
/// 末尾那个纯空的文本块只是「给用户继续打字用」的占位，不写进文件，
/// 否则每存一次就多一个空行。
String serializeBlocks(List<Block> blocks) {
  final effective = <Block>[...blocks];
  if (effective.length > 1) {
    final last = effective.last;
    if (last is TextBlock && last.text.isEmpty) {
      effective.removeLast();
    }
  }
  return effective.map((block) => block.serialized).join('\n');
}

bool _isExternalLink(String path) {
  final lowered = path.toLowerCase();
  return lowered.startsWith('http://') || lowered.startsWith('https://');
}

/// 从正文里抽有序的图片块，给列表页做缩略图用。
List<ImageBlock> imageBlocksOf(String markdown) {
  return parseBlocks(markdown).whereType<ImageBlock>().toList(growable: false);
}

/// 正文里是否有本地附件（文件块）。紧凑列表用它显示回形针标记。
bool hasLocalAttachment(String markdown) {
  if (markdown.trim().isEmpty) {
    return false;
  }
  return parseBlocks(markdown).any((block) => block is FileBlock);
}

/// 把 markdown 剥成纯文本，用于列表摘要。
///
/// 摘要里出现 `**` `#` 这类符号非常难看，而用户真正想「扫一眼」的是文字，
/// 所以这里做的是有损展示转换 —— 只影响 UI，绝不回写文件。
String plainSummary(String markdown) {
  if (markdown.trim().isEmpty) {
    return '';
  }

  final lines = <String>[];
  for (final rawLine in markdown.split('\n')) {
    var line = rawLine;

    // 代码围栏本身没有信息量，跳过。
    if (line.trimLeft().startsWith('```')) {
      continue;
    }
    // 图片行不产生可读文字。
    if (_imagePattern.hasMatch(line)) {
      continue;
    }
    // 文件块降级成文件名。
    final file = _filePattern.firstMatch(line);
    if (file != null && !_isExternalLink(file.group(2)!)) {
      lines.add(file.group(1)!);
      continue;
    }

    line = line.replaceFirst(RegExp(r'^\s{0,3}#{1,6}\s+'), '');
    line = line.replaceFirst(RegExp(r'^\s{0,3}>\s?'), '');
    line = line.replaceFirst(RegExp(r'^\s*[-*+]\s+\[[ xX]\]\s*'), '');
    line = line.replaceFirst(RegExp(r'^\s*[-*+]\s+'), '');
    line = line.replaceFirst(RegExp(r'^\s*\d+[.)]\s+'), '');
    if (RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line)) {
      continue;
    }

    line = line.replaceAllMapped(
      RegExp(r'!\[[^\]]*\]\([^)]*\)'),
      (_) => '',
    );
    line = line.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]\(([^)]*)\)'),
      (match) => match.group(1) ?? '',
    );
    line = line.replaceAllMapped(
      RegExp(r'\*\*(.+?)\*\*'),
      (match) => match.group(1) ?? '',
    );
    line = line.replaceAllMapped(
      RegExp(r'~~(.+?)~~'),
      (match) => match.group(1) ?? '',
    );
    line = line.replaceAllMapped(
      RegExp(r'\*(.+?)\*'),
      (match) => match.group(1) ?? '',
    );
    line = line.replaceAll('`', '');

    if (line.trim().isEmpty) {
      continue;
    }
    lines.add(line.trim());
  }

  return lines.join('\n');
}


/// 有序列表行：`^\s*(\d+)([.)])\s`。
final RegExp _orderedLinePattern = RegExp(r'^(\s*)(\d+)([.)])(\s)');

/// 一次编号重排的结果。
class OrderedListNumbering {
  const OrderedListNumbering({
    required this.text,
    required this.numberChanges,
  });

  /// 重排后的整段文本。
  final String text;

  /// 行号 → (旧数字长度, 新数字长度)。只包含编号真的变了的行，
  /// 调用方用它把光标从旧文本映射到新文本。
  final Map<int, (int, int)> numberChanges;
}

/// 有序列表编号游标。
///
/// 一个列表可能被回车拆成两个文本块，所以游标要能跨块复用：连续的
/// `N. ` 行视为同一条列表，从首个编号起依次 +1。遇到空行、普通段落或
/// 非文本块就 [reset]，不会去改写远处无关的内容。
///
/// 层级用栈维护：缩进更深的行是子列表，有自己的编号序列；缩进回浅时
/// 弹回父层继续编号（markdown 语义 —— 子列表不打断父列表的编号）。
/// 这样「缩进 / 减少缩进」之后，父级和子级各自接续，不会出现
/// 「1. a / 1. b / 3. c」这类断层。
class OrderedListNumberingCursor {
  final List<_NumberingFrame> _stack = <_NumberingFrame>[];

  /// 当前列表结束（空行 / 非列表行 / 图片或附件块）。
  void reset() {
    _stack.clear();
  }

  /// 重排一个文本块里的列表编号；整块没有变化时返回 null。
  OrderedListNumbering? apply(String text) {
    if (text.isEmpty) {
      reset();
      return null;
    }
    final lines = text.split('\n');
    final changes = <int, (int, int)>{};

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final match = _orderedLinePattern.firstMatch(line);
      if (match == null) {
        // 空行算列表结束：宁可少改，也不要把用户另起的一段编号吃掉。
        reset();
        continue;
      }
      final indent = match.group(1)!;
      final digits = match.group(2)!;
      final delimiter = match.group(3)!;
      final number = int.tryParse(digits) ?? 1;

      // 先弹掉比当前行更深的层：缩进回浅，子列表就此结束。
      while (_stack.isNotEmpty &&
          _stack.last.indent.length > indent.length) {
        _stack.removeLast();
      }
      // 找同层级（同缩进 + 同分隔符）的编号帧；找不到 = 这一层重新开始，
      // 锚定在行自己写的编号上（保留用户故意写的起始号，如「3.」）。
      _NumberingFrame? frame;
      for (final candidate in _stack.reversed) {
        if (candidate.indent == indent && candidate.delimiter == delimiter) {
          frame = candidate;
          break;
        }
      }
      if (frame == null) {
        _stack.add(_NumberingFrame(indent, delimiter, number + 1));
        continue;
      }
      if (number == frame.next) {
        frame.next++;
        continue;
      }

      final start = indent.length;
      final replacement = '${frame.next}';
      lines[i] = line.replaceRange(start, start + digits.length, replacement);
      changes[i] = (digits.length, replacement.length);
      frame.next++;
    }

    if (changes.isEmpty) {
      return null;
    }
    return OrderedListNumbering(
      text: lines.join('\n'),
      numberChanges: changes,
    );
  }
}

/// 一个缩进层级的编号状态：这一层下一项应该写几。
class _NumberingFrame {
  _NumberingFrame(this.indent, this.delimiter, this.next);

  final String indent;
  final String delimiter;
  int next;
}

/// 在块末尾回车时，新块应该继承什么前缀。
///
/// 规则对齐语雀，并补上它没有的一条：
/// - `1. xxx` → `2. `
/// - `- xxx`  → `- `
/// - `- [ ] x`→ `- [ ] `（永远新建未勾选，勾过的不继承）
/// - `> xxx`  → `> `
/// - 空列表项再回车 → 清掉标记，退出列表（语雀要手动删减号）
///
/// 返回的 `strippedBlock` 是当前块回车后应保留的文本（退出列表时会去掉标记）。
({String strippedBlock, String initialText}) continuationFor(String blockText) {
  final newlineIndex = blockText.lastIndexOf('\n');
  final lineStart = newlineIndex + 1;
  final lastLine = blockText.substring(lineStart);
  final head = blockText.substring(0, lineStart);

  final match =
      RegExp(r'^(\s*)([-*+]|(\d+)([.)]))\s+(\[[ xX]\]\s+)?')
          .firstMatch(lastLine);
  if (match == null) {
    if (RegExp(r'^\s*>\s+').hasMatch(lastLine)) {
      return (strippedBlock: blockText, initialText: '> ');
    }
    return (strippedBlock: blockText, initialText: '');
  }

  final indent = match.group(1) ?? '';
  final bullet = match.group(2) ?? '';
  final number = match.group(3);
  final delimiter = match.group(4) ?? '.';
  final checkbox = match.group(5);
  final content = lastLine.substring(match.end);

  // 空项（含空待办）再回车就退出列表。语雀这里是留一个空标记，
  // 用户要自己删掉减号才出得来 —— 那一步没有道理。
  if (content.trim().isEmpty) {
    return (strippedBlock: '$head$indent', initialText: '');
  }

  final String nextMarker;
  if (number != null) {
    final value = (int.tryParse(number) ?? 1) + 1;
    nextMarker = '$value$delimiter ';
  } else if (checkbox != null) {
    nextMarker = '$bullet [ ] ';
  } else {
    nextMarker = '$bullet ';
  }
  return (strippedBlock: blockText, initialText: '$indent$nextMarker');
}
