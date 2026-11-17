import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../theme/app_theme.dart';
import '../util/attachment_viewer.dart';

/// 应用内附件预览页：PDF（pdfrx）+ 纯文本（txt/csv/json/xml/html/log）。
///
/// 为什么需要它：手机装 PDF 查看器并不是理所当然的事，国产 ROM 精简后
/// 常常一个能接 `application/pdf` 的应用都没有，走系统 Intent 只会失败。
/// PDF 用 pdfrx（PDFium）在应用内直接渲染；纯文本直接读成文字展示。
/// Office / 压缩包这类无法用内置能力渲染的格式，仍交给系统查看器。
///
/// 这个页面只负责查看：顶栏不显示标题、不放外跳入口；只有文件打不开
/// （加密/损坏/不是文本）时，错误态才给一次「用其他应用打开」的兜底。
class AttachmentPreviewPage extends StatelessWidget {
  const AttachmentPreviewPage({
    super.key,
    required this.fileName,
    required this.path,
  });

  /// 应用内直接读成文字的格式：体积小、没有解析依赖，打开即读。
  static const Set<String> textExtensions = <String>{
    'txt',
    'csv',
    'json',
    'xml',
    'html',
    'htm',
    'log',
  };

  final String fileName;
  final String path;

  static String _extensionOf(String path) {
    final int dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }

  /// 是否有应用内预览器。路由与测试共用这一处判断。
  static bool supports(String path) {
    final String extension = _extensionOf(path);
    return extension == 'pdf' || textExtensions.contains(extension);
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
      ),
      body: _isPdf
          ? _buildPdfViewer(context, colors)
          : _TextPreview(
              path: path,
              fileName: fileName,
              colors: colors,
              onOpenExternally: () => _openExternally(context),
            ),
    );
  }

  bool get _isPdf => _extensionOf(path) == 'pdf';

  /// PDF 阅读区：深色下 pageAlt 是纯黑（PDF 白页在深色阅读器里就该配深底），
  /// 浅色下则是浅灰，白页不会和页面糊在一起。
  Widget _buildPdfViewer(BuildContext context, AppColors colors) {
    return PdfViewer.file(
      path,
      params: PdfViewerParams(
        backgroundColor: colors.pageAlt,
        margin: 12,
        pageDropShadow: BoxShadow(
          color: Colors.black.withValues(
            alpha: Theme.of(context).brightness == Brightness.dark ? 0.6 : 0.14,
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
            fileName: fileName,
            onOpenExternally: () => _openExternally(context),
          );
        },
      ),
    );
  }
}

/// 纯文本预览：直接读成字符串，长文本可滚动、可选中复制。
///
/// 体积上限 2MB：再大就不是「看一眼」的场景，读进内存也容易卡顿，
/// 这里明确引导用户改用其他应用。
class _TextPreview extends StatefulWidget {
  const _TextPreview({
    required this.path,
    required this.fileName,
    required this.colors,
    required this.onOpenExternally,
  });

  static const int maxBytes = 2 * 1024 * 1024;

  final String path;
  final String fileName;
  final AppColors colors;
  final VoidCallback onOpenExternally;

  @override
  State<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<_TextPreview> {
  late final Future<String> _content = _load();
  final ScrollController _scrollController = ScrollController();

  Future<String> _load() async {
    final File file = File(widget.path);
    if (!await file.exists()) {
      throw const FileSystemException('文件不存在');
    }
    if (await file.length() > _TextPreview.maxBytes) {
      throw const _FileTooLargeException();
    }
    final List<int> bytes = await file.readAsBytes();
    // allowMalformed：GBK 等非 UTF-8 文本也能尽量显示，而不是整页报错。
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _content,
      builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(
            child: CircularProgressIndicator(color: widget.colors.accent),
          );
        }
        if (snapshot.hasError) {
          final bool tooLarge = snapshot.error is _FileTooLargeException;
          return _PreviewError(
            colors: widget.colors,
            fileName: widget.fileName,
            message: tooLarge
                ? '文件过大，试试用其他应用打开。'
                : '文件可能已损坏，试试用其他应用打开。',
            onOpenExternally: widget.onOpenExternally,
          );
        }
        return Scrollbar(
          controller: _scrollController,
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.all(AppSpace.page),
            child: SelectableText(
              snapshot.data ?? '',
              style: TextStyle(
                fontSize: AppFontSize.body,
                height: 1.6,
                color: widget.colors.text,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 文本超过 [_TextPreview] 的读取上限：单独一个类型，避免用错误文案判断。
class _FileTooLargeException implements Exception {
  const _FileTooLargeException();

  @override
  String toString() => '文件过大';
}

/// 打不开的文件：加密 / 损坏 / 引擎异常，统一给一条可走的路。
class _PreviewError extends StatelessWidget {
  const _PreviewError({
    required this.colors,
    required this.fileName,
    required this.onOpenExternally,
    this.message = '文件可能已加密或损坏，试试用其他应用打开。',
  });

  final AppColors colors;

  /// 预览页不显示标题，失败时用它告诉用户是哪个文件打不开。
  final String fileName;

  final String message;

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
              '无法预览「$fileName」',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppFontSize.body,
                fontWeight: AppWeight.medium,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
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
