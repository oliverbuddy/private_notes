import 'package:flutter/material.dart';

import '../models/note.dart';
import 'action_sheet.dart';

/// 笔记动作菜单的唯一来源。
///
/// 列表长按与详情页「更多」共用这份定义，保证两处的图标、文案、顺序
/// 永远一致；执行逻辑仍留在各自页面（列表没有正文，做不了复制/历史）。
///
/// 规则：
/// - 高频动作在前，删除固定最后且为危险色；
/// - 锁定笔记不提供「分享为图片」（正文在当前页面不可用）；
/// - [detail] 为 true 时追加只有详情页才成立的「复制文本」「历史版本」。
List<SheetAction<String>> buildNoteActions(
  Note note, {
  bool detail = false,
}) {
  return <SheetAction<String>>[
    // 「已置顶」靠 selected 的主色 + 勾选表达，不混用实心图钉，
    // 否则同一张菜单里深浅轻重不一致。
    SheetAction<String>(
      value: 'pin',
      label: note.pinned ? '取消置顶' : '置顶',
      icon: Icons.push_pin_outlined,
      selected: note.pinned,
    ),
    // 加标签是唯一的组织动作，列表里也必须能直接完成。
    const SheetAction<String>(
      value: 'tags',
      label: '编辑标签',
      icon: Icons.sell_outlined,
    ),
    if (!note.locked)
      const SheetAction<String>(
        value: 'shareImage',
        label: '分享为图片',
        icon: Icons.share_outlined,
      ),
    if (detail) ...<SheetAction<String>>[
      const SheetAction<String>(
        value: 'copy',
        label: '复制文本',
        icon: Icons.content_copy_outlined,
      ),
      const SheetAction<String>(
        value: 'history',
        label: '历史版本',
        icon: Icons.history_rounded,
      ),
    ],
    SheetAction<String>(
      value: 'lock',
      label: note.locked ? '取消锁定' : '锁定笔记',
      icon: note.locked ? Icons.lock_open_outlined : Icons.lock_outline_rounded,
    ),
    const SheetAction<String>(
      value: 'delete',
      label: '删除',
      icon: Icons.delete_outline_rounded,
      destructive: true,
    ),
  ];
}
