import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../theme/app_theme.dart';
import '../util/attachment_viewer.dart';

/// 应用内附件预览页（P1 覆盖 PDF）。
///
/// 为什么需要它：手机装 PDF 查看器并不是理所当然的事，国产 ROM 精简后
/// 常常一个能接 `application/pdf` 的应用都没有，走系统 Intent 只会失败。
/// 这里用 pdfrx（PDFium）在应用内直接渲染，点开就能看；右上角仍保留
/// 「用其他应用打开」，需要标注/打印时再外跳。
class AttachmentPreviewPage extends StatelessWidget {
  const AttachmentPreviewPage({
    super.key,
    required this.fileName,
    required this.path,
  });

  final String fileName;
  final String path;

  /// 是否有应用内预览器。路由与测试共用这一处判断。
  static bool supports(String path) {
    final int dot = path.lastIndexOf('.');
    if (dot < 0) {
      return false;
    }
    return path.substring(dot + 1).toLowerCase() == 'pdf';
  }

  Future<void> _openExternally(BuildContext context) async {
    String? failure;
    try {
      final bool handled = await openAttachmentWithSystemViewer(path);
      if (!handled) {
        failure = '当前平台不支持打开附件';
      }
    } on PlatformException catch (error) {
      if (error.code == 'no_viewer') {
        // 没有查看器时退回系统分享：至少能把文件发到能看的设备/应用上。
        try {
          await shareAttachmentWithSystem(path);
          return;
        } on PlatformException catch (shareError) {
          failure = shareError.message ?? '分享失败';
        } on MissingPluginException {
          failure = '当前平台不支持分享附件';
        }
      } else {
        failure = error.message ?? '没有可打开此文件的应用';
      }
    } on MissingPluginException {
      failure = '当前平台不支持打开附件';
    } catch (error) {
      failure = '打开失败：$error';
    }
    if (failure == null || !context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(failure), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: colors.page,
      appBar: AppBar(
        backgroundColor: colors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.text,
        titleSpacing: 0,
        title: Text(
          fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppFontSize.subtitle,
            fontWeight: AppWeight.medium,
            color: colors.text,
          ),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '用其他应用打开',
            icon: const Icon(Icons.open_in_new_rounded),
            onPressed: () => _openExternally(context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      // 深色下 pageAlt 是纯黑：PDF 白页在深色阅读器里就该配深底，
      // 浅色下则是浅灰，白页不会和页面糊在一起。
      body: PdfViewer.file(
        path,
        params: PdfViewerParams(
          backgroundColor: colors.pageAlt,
          margin: 12,
          pageDropShadow: BoxShadow(
            color: Colors.black.withValues(
              alpha: Theme.of(context).brightness == Brightness.dark
                  ? 0.6
                  : 0.14,
            ),
            blurRadius: 6,
            spreadRadius: 1,
            offset: const Offset(0, 2),
          ),
          loadingBannerBuilder: (
            BuildContext context,
            int bytesDownloaded,
            int? totalBytes,
          ) {
            return Center(
              child: CircularProgressIndicator(color: colors.accent),
            );
          },
          errorBannerBuilder: (
            BuildContext context,
            Object error,
            StackTrace? stackTrace,
            PdfDocumentRef documentRef,
          ) {
            return _PreviewError(
              colors: colors,
              onOpenExternally: () => _openExternally(context),
            );
          },
        ),
      ),
    );
  }
}

/// 打不开的 PDF：加密 / 损坏 / 引擎异常，统一给一条可走的路。
class _PreviewError extends StatelessWidget {
  const _PreviewError({required this.colors, required this.onOpenExternally});

  final AppColors colors;
  final VoidCallback onOpenExternally;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.page),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.description_outlined,
              size: 40,
              color: colors.tertiary,
            ),
            const SizedBox(height: 12),
            Text(
              '无法预览这个文件',
              style: TextStyle(
                fontSize: AppFontSize.body,
                fontWeight: AppWeight.medium,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '文件可能已加密或损坏，试试用其他应用打开。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppFontSize.meta,
                height: 1.5,
                color: colors.secondary,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onOpenExternally,
              child: const Text('用其他应用打开'),
            ),
          ],
        ),
      ),
    );
  }
}
