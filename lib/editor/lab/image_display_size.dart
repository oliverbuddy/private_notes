/// 图片在正文里的显示尺寸。
///
/// 「小图」只是显示宽度减半，原图不裁剪；「大图」是通栏。
///
/// 存储不引入新语法：在 markdown 图片语法 `![alt](url)` 的 URL 末尾追加
/// 一个锚点标记（`#xiaoji-small`）—— 仍是合法图片语法，旧渲染器/导出
/// 会把它当普通 URL，读取真实文件路径时统一用 [imageFilePath] 去掉标记。
enum ImageDisplaySize { large, small }

/// 小图标记（URL 片段）。选一个不太可能和真实文件冲突的名字。
const String _smallMarker = '#xiaoji-small';

/// 从存储的 URL 判断显示尺寸。
ImageDisplaySize imageDisplaySizeOf(String url) =>
    url.endsWith(_smallMarker)
        ? ImageDisplaySize.small
        : ImageDisplaySize.large;

/// 按目标尺寸重写 URL（保留原路径、只在末尾增删标记）。
///
/// 幂等：对同一个 URL 重复调用结果不变，可安全用于切换命令。
String imageUrlWithSize(String url, ImageDisplaySize size) {
  final String base = imageFilePath(url);
  return size == ImageDisplaySize.small ? '$base$_smallMarker' : base;
}

/// 去掉尺寸标记，得到真实文件路径（相对或绝对都适用）。
String imageFilePath(String url) {
  if (url.endsWith(_smallMarker)) {
    return url.substring(0, url.length - _smallMarker.length);
  }
  return url;
}
