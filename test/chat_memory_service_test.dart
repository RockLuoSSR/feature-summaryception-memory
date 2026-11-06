import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_inn/models/chat_memory.dart';
import 'package:pocket_inn/services/chat_database_service.dart';
import 'package:pocket_inn/services/chat_memory_service.dart';

import 'helpers/test_env.dart';

MemorySnippet _snippet({
  required String id,
  int layer = 0,
  int order = 0,
  List<String> sourceMessageIds = const [],
  List<String> parentSnippetIds = const [],
  String content = 'summary',
}) {
  return MemorySnippet(
    id: id,
    sessionId: 's1',
    layer: layer,
    content: content,
    sourceMessageIds: sourceMessageIds,
    parentSnippetIds: parentSnippetIds,
    order: order,
    createdAt: DateTime(2026),
  );
}

void main() {
  group('selectValidSnippets', () {
    test('只保留源消息全部位于当前分支祖先路径的片段', () {
      final all = [
        _snippet(id: 'a', sourceMessageIds: ['m1', 'm2']),
        _snippet(id: 'b', sourceMessageIds: ['m2', 'x1']),
      ];
      final valid = ChatMemoryService.selectValidSnippets(
        all: all,
        pathMessageIds: ['m1', 'm2', 'm3'],
      );
      expect(valid.map((s) => s.id), ['a']);
    });

    test('路径为空时不返回任何片段', () {
      expect(
        ChatMemoryService.selectValidSnippets(
          all: [_snippet(id: 'a', sourceMessageIds: ['m1'])],
          pathMessageIds: const [],
        ),
        isEmpty,
      );
    });
  });

  group('selectTopSnippets', () {
    test('被更高层片段引用的下层片段不再作为顶层片段', () {
      final all = [
        _snippet(id: 'a', sourceMessageIds: ['m1']),
        _snippet(id: 'b', sourceMessageIds: ['m2']),
        _snippet(
          id: 'c',
          layer: 1,
          sourceMessageIds: ['m1', 'm2'],
          parentSnippetIds: ['a', 'b'],
        ),
      ];
      final tops = ChatMemoryService.selectTopSnippets(all);
      expect(tops.map((s) => s.id), ['c']);
    });

    test('另一分支独有的合并片段不会遮蔽本分支的下层片段', () {
      final validOnCurrentBranch = [
        _snippet(id: 'a', sourceMessageIds: ['m1']),
        _snippet(id: 'b', sourceMessageIds: ['m2']),
      ];
      final tops = ChatMemoryService.selectTopSnippets(validOnCurrentBranch);
      expect(tops.map((s) => s.id), ['a', 'b']);
    });
  });

  group('orderedForInjection', () {
    test('高层摘要在前，第 0 层在后，层内按时间升序', () {
      final snippets = [
        _snippet(id: 'l0-1', layer: 0, order: 1),
        _snippet(id: 'l0-2', layer: 0, order: 2),
        _snippet(id: 'l2-1', layer: 2, order: 3),
        _snippet(id: 'l1-1', layer: 1, order: 4),
      ];
      final ordered = ChatMemoryService.orderedForInjection(snippets);
      expect(
        ordered.map((s) => s.id),
        ['l2-1', 'l1-1', 'l0-1', 'l0-2'],
      );
    });
  });

  group('formatMemoryContext', () {
    test('空列表返回空字符串', () {
      expect(ChatMemoryService.formatMemoryContext(const []), '');
    });

    test('包含引导语与 XML 包裹，片段之间用空行分隔', () {
      final text = ChatMemoryService.formatMemoryContext(['一', '二']);
      expect(text, contains(ChatMemoryService.defaultInjectionHeader));
      expect(text, contains('<auto_injected_historical_context>'));
      expect(text, contains('一\n\n二'));
    });
  });

  group('formatMemoryList', () {
    test('纯列表形式不包含 XML 包裹', () {
      final text = ChatMemoryService.formatMemoryList(['一', '二']);
      expect(text, '- 一\n- 二');
      expect(text, isNot(contains('auto_injected_historical_context')));
    });
  });

  group('记忆写入的变更广播', () {
    late Directory tempDir;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tempDir = setUpPathProviderMocks();
      await ChatDatabaseService.instance.initialize();
    });

    tearDownAll(() async {
      await ChatDatabaseService.instance.deleteDatabaseFiles();
      tearDownPathProviderMocks(tempDir);
    });

    setUp(() async {
      await ChatDatabaseService.instance.clearAllData();
    });

    test('记忆写入不触发聊天数据广播，只广播记忆变更', () async {
      final db = ChatDatabaseService.instance;
      final session = await db.createSession(
        characterId: 'char-1',
        openingAssistantMessages: ['开场白'],
      );

      // 基线取在会话创建之后：只断言记忆操作本身不广播。
      final chatNotifyBefore = db.changeNotifier.value;
      final memoryNotifyBefore = db.memoryChangeNotifier.value;

      final snippet = MemorySnippet(
        id: 'snip-1',
        sessionId: session.id,
        layer: 0,
        content: '喜欢雨天',
        sourceMessageIds: [session.currentLeafMessageId ?? ''],
        order: 0,
        createdAt: DateTime(2026),
      );
      await db.insertSnippet(snippet);
      expect(
        db.changeNotifier.value,
        chatNotifyBefore,
        reason: '新增记忆不应触发聊天页重载',
      );
      expect(db.memoryChangeNotifier.value, memoryNotifyBefore + 1);

      await db.updateSnippetContent(
        snippetId: 'snip-1',
        content: '讨厌雨天',
      );
      expect(
        db.changeNotifier.value,
        chatNotifyBefore,
        reason: '编辑记忆不应触发聊天页重载',
      );

      // 空批量写入什么都不改，不应广播。
      final memoryNotifyAfterEdit = db.memoryChangeNotifier.value;
      await db.insertSnippetsInTx(const []);
      expect(db.memoryChangeNotifier.value, memoryNotifyAfterEdit);
    });
  });
}
