import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/ui/note_actions.dart';

/// 列表长按与详情「更多」共用 [buildNoteActions]，这里锁住两边的一致性：
/// 以后加动作只改一处，测试会提醒不要在两处各写一套。
void main() {
  Note note({bool pinned = false, bool locked = false}) => Note(
    id: 'n1',
    created: DateTime(2026, 11, 1),
    updated: DateTime(2026, 11, 2),
    pinned: pinned,
    locked: locked,
    body: '正文',
  );

  test('列表菜单：未锁定为 置顶/标签/分享图/锁定/删除', () {
    final actions = buildNoteActions(note());
    expect(
      actions.map((action) => action.value).toList(),
      <String>['pin', 'tags', 'shareImage', 'lock', 'delete'],
    );
    expect(actions.last.destructive, isTrue);
    expect(actions.first.selected, isFalse);
  });

  test('列表菜单：锁定笔记不提供分享图', () {
    final actions = buildNoteActions(note(locked: true));
    expect(
      actions.map((action) => action.value).toList(),
      <String>['pin', 'tags', 'lock', 'delete'],
    );
    expect(
      actions.firstWhere((action) => action.value == 'lock').label,
      '取消锁定',
    );
  });

  test('详情菜单是列表菜单的超集，顺序一致', () {
    final list = buildNoteActions(note(pinned: true));
    final detail = buildNoteActions(note(pinned: true), detail: true);

    expect(
      detail.map((action) => action.value).toList(),
      <String>['pin', 'tags', 'shareImage', 'copy', 'history', 'lock', 'delete'],
    );
    expect(list.first.label, '取消置顶');
    final List<String> detailValues = detail
        .map((action) => action.value)
        .toList();
    for (final String value in list.map((action) => action.value)) {
      expect(detailValues, contains(value));
    }
  });
}
