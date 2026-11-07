import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../theme/app_theme.dart';
import '../../util/date_format.dart';
import '../block.dart';

/// 附件块。
///
/// 刻意不引入 open_file 之类的插件：这类插件在 iOS/Android 上要额外配
/// `queries` / `FileProvider`，很容易因为清单配置漏项而在真机上静默失败；
/// 而附件的真实需求只是「知道它在哪、能删掉」，所以做成就地展示 + 长按删除，
/// 点击给出完整路径提示。
class FileBlockView extends StatelessWidget {
  const FileBlockView({
    super.key,
    required this.block,
    required this.absolutePath,
    required this.onTap,
    required this.onLongPress,
  });

  final FileBlock block;
  final String absolutePath;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final extension = p.extension(block.name).replaceFirst('.', '').toUpperCase();
    final label = extension.isEmpty ? 'FILE' : extension;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: colors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.block),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.page,
                borderRadius: BorderRadius.circular(AppRadius.thumb),
                border: Border.all(color: colors.dividerStrong, width: 0.5),
              ),
              child: Text(
                label.length > 4 ? label.substring(0, 4) : label,
                style: TextStyle(
                  fontSize: AppFontSize.tiny,
                  color: colors.secondary,
                  fontWeight: AppWeight.medium,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    block.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppFontSize.label,
                      height: 1.3,
                      color: colors.text,
                      fontWeight: AppWeight.medium,
                    ),
                  ),
                  const SizedBox(height: 2),
                  FutureBuilder<_SizeResult>(
                    future: _probeSize(absolutePath),
                    builder: (context, snapshot) {
                      final data = snapshot.data;
                      final text = data == null
                          ? '  '
                          : (data.exists ? formatFileSize(data.bytes) : '文件已丢失');
                      return Text(
                        text,
                        style: TextStyle(
                          fontSize: AppFontSize.badge,
                          color: colors.tertiary,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: AppIcon.chevron,
              color: colors.tertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _SizeResult {
  const _SizeResult(this.bytes, this.exists);

  final int bytes;
  final bool exists;
}

/// 读文件大小。抽成独立函数是为了让 `FutureBuilder` 拿到稳定的 Future 类型，
/// 避免在 build 里嵌套 then 造成的泛型混乱。
Future<_SizeResult> _probeSize(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) {
      return const _SizeResult(0, false);
    }
    final length = await file.length();
    return _SizeResult(length, true);
  } catch (_) {
    return const _SizeResult(0, false);
  }
}
