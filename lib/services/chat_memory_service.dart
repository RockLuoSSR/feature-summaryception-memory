import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/api_configs.dart';
import '../models/api_config.dart';
import '../models/chat_memory.dart';
import '../models/chat_message.dart';
import 'api_request_log_service.dart';
import 'chat_database_service.dart';
import 'openai_compatible_api_service.dart';
import 'storage_service.dart';

/// Summaryception 风格的分层递归记忆。
///
/// 最近 [MemoryExtractionConfig.verbatimTurns] 条助手回复保留原文，更早的对话
/// 按 [MemoryExtractionConfig.turnsPerSummary] 条一批压缩成第 0 层摘要；某一层
/// 的片段超过 [MemoryExtractionConfig.snippetsPerLayer] 后，按
/// [MemoryExtractionConfig.promotionBatch] 条合并到更高层。
///
/// 片段用 [MemorySnippet.sourceMessageIds] 标记覆盖的原始消息，因此可以按当前
/// 分支祖先路径筛出真正可用的摘要，分支之间不会串记忆。
class ChatMemoryService {
  ChatMemoryService._();

  static final ChatMemoryService instance = ChatMemoryService._();

  static const String defaultSummarizerSystemPrompt = '''
你是一部长篇角色扮演对话的「叙事状态记录员」。
你的任务是压缩对话，而不是续写或润色。只记录对后续剧情有影响的信息：
- 事件与剧情推进
- 人物关系、态度与情绪变化
- 承诺、秘密、决定、约定
- 地点、物品、身份、状态变化
- 尚未解决的伏笔与目标

规则：
1. 用第三人称、过去时陈述，不写对话原文，不做文学描写。
2. 只输出「叙事增量」：不要重复已有摘要里已经写过的事件。
3. 内容必须具体（谁、做了什么、结果如何），不要写空泛评价。
4. 输出 2-6 句，尽量不超过 400 字；只输出摘要正文。
''';

  static const String defaultSummarizerUserPrompt = '''
以下是对更早剧情的已有摘要，仅用于避免重复：
{{context}}

=== 本次需要压缩的对话 ===
{{conversation}}

请输出这段对话的叙事增量摘要。只输出摘要正文，不要标题、不要解释。
''';

  /// 注入到主 Prompt 的历史摘要表头。
  static const String defaultInjectionHeader =
      '以下是你记得的、发生在此前对话中的历史（分层摘要）：';

  static const String _injectionOpenTag = '<auto_injected_historical_context>';
  static const String _injectionCloseTag = '</auto_injected_historical_context>';

  static final Random _random = Random();
  static int _idSequence = 0;

  String get _systemPrompt {
    final custom = memoryExtractionNotifier.value
        .customSummarizerSystemPrompt
        .trim();
    return custom.isNotEmpty ? custom : defaultSummarizerSystemPrompt;
  }

  String get _userPrompt {
    final custom = memoryExtractionNotifier.value.customSummarizerUserPrompt
        .trim();
    return custom.isNotEmpty ? custom : defaultSummarizerUserPrompt;
  }

  /// 将摘要片段格式化为注入文本（含表头与 XML 包裹）。
  ///
  /// 同时服务 Prompt 段 `longTermMemory` 与宏 `{{memory}}`。
  static String formatMemoryContext(List<String> memories) {
    if (memories.isEmpty) return '';
    final config = memoryExtractionNotifier.value;
    final header = config.hasCustomInjectionPrompt
        ? config.customInjectionPrompt.trim()
        : defaultInjectionHeader;
    final body = memories.where((m) => m.trim().isNotEmpty).join('\n\n');
    if (body.isEmpty) return '';
    return '$header\n$_injectionOpenTag\n$body\n$_injectionCloseTag';
  }

  /// 纯列表形式（不含引导语表头），供 `{{memory}}` 宏的紧凑渲染使用。
  static String formatMemoryList(List<String> memories) {
    if (memories.isEmpty) return '';
    return memories.map((m) => '- $m').join('\n');
  }

  ResolvedApiConfig? get _summaryConfig {
    final configs = apiConfigsNotifier.value;
    final summaryModelId = memoryExtractionNotifier.value.summaryModelId;
    ApiConfig? provider;
    ApiModel? model;
    if (summaryModelId.isNotEmpty) {
      outer:
      for (final c in configs) {
        for (final m in c.models) {
          if (m.id == summaryModelId) {
            provider = c;
            model = m;
            break outer;
          }
        }
      }
    }
    if (provider == null || model == null) {
      final tuple = selectedApiModelTuple;
      if (tuple == null) return null;
      provider = tuple.provider;
      model = tuple.model;
    }
    return provider.resolve(model);
  }

  // ==================== 查询与分支过滤 ====================

  Future<List<MemorySnippet>> loadAllSnippets(String sessionId) {
    return ChatDatabaseService.instance.loadSessionSnippets(sessionId);
  }

  /// 当前分支可用（祖先路径覆盖）的片段。
  static List<MemorySnippet> selectValidSnippets({
    required List<MemorySnippet> all,
    required List<String> pathMessageIds,
  }) {
    if (all.isEmpty || pathMessageIds.isEmpty) return const [];
    final pathSet = pathMessageIds.toSet();
    return all
        .where(
          (snippet) =>
              snippet.sourceMessageIds.isNotEmpty &&
              snippet.sourceMessageIds.every(pathSet.contains),
        )
        .toList(growable: false);
  }

  /// 未被更高层片段合并的「顶层片段」。
  static List<MemorySnippet> selectTopSnippets(
    List<MemorySnippet> validSnippets,
  ) {
    if (validSnippets.isEmpty) return const [];
    final referenced = <String>{};
    for (final snippet in validSnippets) {
      referenced.addAll(snippet.parentSnippetIds);
    }
    return validSnippets
        .where((snippet) => !referenced.contains(snippet.id))
        .toList(growable: false);
  }

  /// 注入顺序：先高层（更久远、更压缩），再第 0 层（较近、更详细）。
  static List<MemorySnippet> orderedForInjection(List<MemorySnippet> tops) {
    final sorted = [...tops]..sort((a, b) => a.order.compareTo(b.order));
    final byLayer = <int, List<MemorySnippet>>{};
    for (final snippet in sorted) {
      byLayer.putIfAbsent(snippet.layer, () => <MemorySnippet>[]).add(snippet);
    }
    final layers = byLayer.keys.toList()..sort();
    final result = <MemorySnippet>[];
    for (final layer in layers.reversed) {
      if (layer == 0) continue;
      result.addAll(byLayer[layer]!);
    }
    result.addAll(byLayer[0] ?? const <MemorySnippet>[]);
    return result;
  }

  Future<Set<String>> ghostedMessageIds({
    required String sessionId,
    required List<String> pathMessageIds,
  }) async {
    if (!memoryExtractionNotifier.value.enabled) return const {};
    final all = await loadAllSnippets(sessionId);
    final valid = selectValidSnippets(
      all: all,
      pathMessageIds: pathMessageIds,
    );
    if (valid.isEmpty) return const {};
    return valid
        .expand((snippet) => snippet.sourceMessageIds)
        .toSet();
  }

  Future<List<String>> buildSummaryContext({
    required String sessionId,
    required List<String> pathMessageIds,
  }) async {
    if (!memoryExtractionNotifier.value.enabled) return const [];
    final all = await loadAllSnippets(sessionId);
    final tops = selectTopSnippets(
      selectValidSnippets(all: all, pathMessageIds: pathMessageIds),
    );
    return orderedForInjection(tops)
        .map((snippet) => snippet.content.trim())
        .where((text) => text.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<MemorySnippet>> buildVisibleSnippets({
    required String sessionId,
    required List<String> pathMessageIds,
  }) async {
    final all = await loadAllSnippets(sessionId);
    final tops = selectTopSnippets(
      selectValidSnippets(all: all, pathMessageIds: pathMessageIds),
    );
    return orderedForInjection(tops);
  }

  // ==================== 摘要处理 ====================

  /// 处理当前分支的积压对话。
  ///
  /// [maxBatches] 限制本次最多调用多少次摘要模型。普通消息触发用较小值，
  /// 用户点「立即整理」时可传大值补齐历史。
  Future<int> summarizeIfNeeded({
    required String sessionId,
    required String branchLeafId,
    required String characterName,
    required String userName,
    int maxBatches = 3,
    Future<void> Function()? beforeCommit,
  }) async {
    final config = memoryExtractionNotifier.value;
    if (!config.enabled) return 0;

    var path = await ChatDatabaseService.instance.loadActivePathMessages(
      sessionId,
    );
    if (path.isEmpty) return 0;
    if (path.last.id != branchLeafId) {
      // 调度任务已过期（用户切换分支或继续生成），放弃本次处理。
      return 0;
    }

    var processed = 0;
    for (var i = 0; i < maxBatches; i++) {
      final pathIds = path
          .where((message) => message.id != null)
          .map((message) => message.id!)
          .toList(growable: false);
      final all = await loadAllSnippets(sessionId);
      final valid = selectValidSnippets(
        all: all,
        pathMessageIds: pathIds,
      );
      final ghosted = valid
          .expand((snippet) => snippet.sourceMessageIds)
          .toSet();

      final assistants = <({int index, ChatMessage message})>[];
      for (var index = 0; index < path.length; index++) {
        final message = path[index];
        if (message.isMe || message.id == null || message.text.trim().isEmpty) {
          continue;
        }
        if (ghosted.contains(message.id)) continue;
        assistants.add((index: index, message: message));
      }
      if (assistants.length <= config.verbatimTurns) break;

      final allowed = assistants.length - config.verbatimTurns;
      final batchSize = min(config.turnsPerSummary, allowed);
      if (batchSize <= 0) break;
      final batch = assistants.take(batchSize).toList(growable: false);
      final batchEndIndex = batch.last.index;

      // 从上一条已摘要消息之后开始，把用户消息一并纳入片段。
      var passageStart = 0;
      for (var index = path.length - 1; index >= 0; index--) {
        final id = path[index].id;
        if (id != null && ghosted.contains(id)) {
          passageStart = index + 1;
          break;
        }
      }
      if (passageStart > batchEndIndex) {
        passageStart = batch.first.index;
      }

      final passage = path
          .sublist(passageStart, batchEndIndex + 1)
          .where(
            (message) =>
                message.id != null && message.text.trim().isNotEmpty,
          )
          .toList(growable: false);
      if (passage.isEmpty) break;

      final sourceIds = passage.map((message) => message.id!).toList();
      final conversation = passage
          .map(
            (message) =>
                '${message.isMe ? userName : characterName}: ${_limitText(message.text, 4000)}',
          )
          .join('\n');
      final context = orderedForInjection(
        selectTopSnippets(valid),
      ).map((snippet) => snippet.content.trim()).join('\n\n');

      final summary = await _requestSummary(
        context: context,
        conversation: conversation,
      );
      if (summary == null) break;

      if (beforeCommit != null) await beforeCommit();
      final order = await ChatDatabaseService.instance.nextSnippetOrder(
        sessionId,
      );
      await ChatDatabaseService.instance.insertSnippet(
        MemorySnippet(
          id: _generateId(),
          sessionId: sessionId,
          layer: 0,
          content: summary,
          sourceMessageIds: sourceIds,
          createdOnLeafId: branchLeafId,
          order: order,
          createdAt: DateTime.now(),
        ),
      );
      processed++;
      path = await ChatDatabaseService.instance.loadActivePathMessages(
        sessionId,
      );
      if (path.isEmpty || path.last.id != branchLeafId) break;

      await _promoteLayers(
        sessionId: sessionId,
        pathIds: pathIds,
        branchLeafId: branchLeafId,
        beforeCommit: beforeCommit,
      );
    }
    return processed;
  }

  Future<void> _promoteLayers({
    required String sessionId,
    required List<String> pathIds,
    required String branchLeafId,
    Future<void> Function()? beforeCommit,
  }) async {
    final config = memoryExtractionNotifier.value;
    for (var guard = 0; guard < 50; guard++) {
      final all = await loadAllSnippets(sessionId);
      final tops = selectTopSnippets(
        selectValidSnippets(all: all, pathMessageIds: pathIds),
      );
      final byLayer = <int, List<MemorySnippet>>{};
      for (final snippet in tops) {
        byLayer.putIfAbsent(snippet.layer, () => []).add(snippet);
      }
      for (final list in byLayer.values) {
        list.sort((a, b) => a.order.compareTo(b.order));
      }

      int? promoteLayer;
      final layers = byLayer.keys.toList()..sort();
      for (final layer in layers) {
        if (byLayer[layer]!.length > config.snippetsPerLayer &&
            layer + 1 < config.maxLayers) {
          promoteLayer = layer;
          break;
        }
      }
      if (promoteLayer == null) return;

      final candidates = byLayer[promoteLayer]!;
      final destination =
          byLayer[promoteLayer + 1] ?? const <MemorySnippet>[];
      final destLayer = promoteLayer + 1;

      if (destination.isEmpty) {
        // 目标层为空时先「种子提升」：直接复制最旧的一条，不调用模型。
        final seed = candidates.first;
        if (beforeCommit != null) await beforeCommit();
        await ChatDatabaseService.instance.insertSnippet(
          MemorySnippet(
            id: _generateId(),
            sessionId: sessionId,
            layer: destLayer,
            content: seed.content,
            sourceMessageIds: seed.sourceMessageIds,
            parentSnippetIds: [seed.id],
            isSeed: true,
            createdOnLeafId: branchLeafId,
            order: await ChatDatabaseService.instance.nextSnippetOrder(
              sessionId,
            ),
            createdAt: DateTime.now(),
          ),
        );
        continue;
      }

      final batch = candidates
          .take(min(config.promotionBatch, candidates.length))
          .toList(growable: false);
      final context = [
        ...destination,
        ...tops.where((snippet) => snippet.layer > destLayer),
      ]
          .map((snippet) => snippet.content.trim())
          .where((text) => text.isNotEmpty)
          .join('\n\n');
      final conversation = batch
          .map((snippet) => '· ${snippet.content.trim()}')
          .join('\n\n');
      final summary = await _requestSummary(
        context: context,
        conversation: conversation,
      );
      if (summary == null) return;

      if (beforeCommit != null) await beforeCommit();
      final sources = <String>{};
      for (final snippet in batch) {
        sources.addAll(snippet.sourceMessageIds);
      }
      await ChatDatabaseService.instance.insertSnippet(
        MemorySnippet(
          id: _generateId(),
          sessionId: sessionId,
          layer: destLayer,
          content: summary,
          sourceMessageIds: sources.toList(growable: false),
          parentSnippetIds: batch
              .map((snippet) => snippet.id)
              .toList(growable: false),
          createdOnLeafId: branchLeafId,
          order: await ChatDatabaseService.instance.nextSnippetOrder(sessionId),
          createdAt: DateTime.now(),
        ),
      );
    }
  }

  Future<String?> _requestSummary({
    required String context,
    required String conversation,
  }) async {
    final config = _summaryConfig;
    if (config == null) return null;

    final system = _systemPrompt;
    final userTemplate = _userPrompt;
    final user = userTemplate
        .replaceAll('{{context}}', context.trim().isEmpty ? '（无）' : context)
        .replaceAll('{{conversation}}', conversation)
        .replaceAll('{{memory}}', context);
    final requestMessages = [
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': user},
    ];

    for (var attempt = 0; attempt < 2; attempt++) {
      final stopwatch = Stopwatch()..start();
      try {
        final result = await OpenAICompatibleApiService.instance
            .createChatCompletion(config, messages: requestMessages);
        stopwatch.stop();
        final cleaned = _cleanSummary(result.text);
        return cleaned.isEmpty ? null : cleaned;
      } catch (error, stack) {
        stopwatch.stop();
        debugPrint('summarize chat failed: $error\n$stack');
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          continue;
        }
        unawaited(
          ApiRequestLogService.appendExtractionFailure(
            label: '对话摘要失败',
            configName: config.name,
            model: config.model,
            baseUrl: config.baseUrl,
            error: error,
            durationMs: stopwatch.elapsedMilliseconds,
          ),
        );
        return null;
      }
    }
    return null;
  }

  static String _cleanSummary(String raw) {
    var text = raw.trim();
    text = text.replaceAll(RegExp(r'^```[a-zA-Z]*\n?'), '');
    text = text.replaceAll(RegExp(r'\n?```$'), '');
    text = text.replaceFirst(
      RegExp(r'^(摘要|总结|summary)\s*[:：]\s*', caseSensitive: false),
      '',
    );
    text = text.replaceAll(RegExp(r'^\s*[-*]\s+'), '');
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    return _limitText(text.trim(), 2000);
  }

  static String _limitText(String text, int maxChars) {
    final trimmed = text.trim();
    if (trimmed.length <= maxChars) return trimmed;
    return trimmed.substring(0, maxChars);
  }

  static String _generateId() {
    final micros = DateTime.now().microsecondsSinceEpoch;
    final seq = _idSequence++;
    final rand = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return 'ms-$micros-$seq-$rand';
  }

  // ==================== 管理操作 ====================

  Future<List<MemorySnippet>> loadSessionSnippets(String sessionId) {
    return ChatDatabaseService.instance.loadSessionSnippets(sessionId);
  }

  Future<void> summarizeNow({
    required String sessionId,
    required String branchLeafId,
    required String characterName,
    required String userName,
    int maxBatches = 40,
  }) async {
    await summarizeIfNeeded(
      sessionId: sessionId,
      branchLeafId: branchLeafId,
      characterName: characterName,
      userName: userName,
      maxBatches: maxBatches,
    );
  }

  Future<void> clearSession(String sessionId) {
    return ChatDatabaseService.instance.deleteSessionSnippets(sessionId);
  }

  Future<void> deleteSnippet({
    required String sessionId,
    required String snippetId,
  }) {
    return ChatDatabaseService.instance.deleteSnippetCascade(
      sessionId: sessionId,
      snippetId: snippetId,
    );
  }

  Future<void> updateSnippetContent({
    required String snippetId,
    required String content,
  }) {
    return ChatDatabaseService.instance.updateSnippetContent(
      snippetId: snippetId,
      content: content,
    );
  }
}

ValueNotifier<MemoryExtractionConfig> memoryExtractionNotifier = ValueNotifier(
  const MemoryExtractionConfig(),
);

const Object _unset = Object();

void updateMemoryExtractionConfig({
  bool? enabled,
  int? verbatimTurns,
  int? turnsPerSummary,
  int? snippetsPerLayer,
  int? promotionBatch,
  int? maxLayers,
  Object? summaryModelId = _unset,
  String? customSummarizerSystemPrompt,
  String? customSummarizerUserPrompt,
  String? customInjectionPrompt,
}) {
  final current = memoryExtractionNotifier.value;
  final next = current.copyWith(
    enabled: enabled ?? current.enabled,
    verbatimTurns: verbatimTurns ?? current.verbatimTurns,
    turnsPerSummary: turnsPerSummary ?? current.turnsPerSummary,
    snippetsPerLayer: snippetsPerLayer ?? current.snippetsPerLayer,
    promotionBatch: promotionBatch ?? current.promotionBatch,
    maxLayers: maxLayers ?? current.maxLayers,
    summaryModelId: summaryModelId == _unset
        ? current.summaryModelId
        : (summaryModelId as String? ?? ''),
    customSummarizerSystemPrompt:
        customSummarizerSystemPrompt ?? current.customSummarizerSystemPrompt,
    customSummarizerUserPrompt:
        customSummarizerUserPrompt ?? current.customSummarizerUserPrompt,
    customInjectionPrompt:
        customInjectionPrompt ?? current.customInjectionPrompt,
  );
  memoryExtractionNotifier.value = next;
  _persistMemoryConfig(next);
}

Future<void> initializeMemoryConfig() async {
  final storage = StorageService.instance;
  memoryExtractionNotifier.value = MemoryExtractionConfig(
    enabled: storage.getBool('memory_enabled') ?? false,
    verbatimTurns: storage.getInt('memory_verbatim_turns') ?? 10,
    turnsPerSummary: storage.getInt('memory_turns_per_summary') ?? 3,
    snippetsPerLayer: storage.getInt('memory_snippets_per_layer') ?? 20,
    promotionBatch: storage.getInt('memory_promotion_batch') ?? 3,
    maxLayers: storage.getInt('memory_max_layers') ?? 5,
    summaryModelId: storage.getString('memory_summary_model_id') ?? '',
    customSummarizerSystemPrompt:
        storage.getString('memory_custom_summarizer_system_prompt') ?? '',
    customSummarizerUserPrompt:
        storage.getString('memory_custom_summarizer_user_prompt') ?? '',
    customInjectionPrompt:
        storage.getString('memory_custom_injection_prompt') ?? '',
  );
}

void _persistMemoryConfig(MemoryExtractionConfig config) {
  final storage = StorageService.instance;
  unawaited(storage.setBool('memory_enabled', config.enabled));
  unawaited(storage.setInt('memory_verbatim_turns', config.verbatimTurns));
  unawaited(storage.setInt('memory_turns_per_summary', config.turnsPerSummary));
  unawaited(
    storage.setInt('memory_snippets_per_layer', config.snippetsPerLayer),
  );
  unawaited(storage.setInt('memory_promotion_batch', config.promotionBatch));
  unawaited(storage.setInt('memory_max_layers', config.maxLayers));
  if (config.summaryModelId.isNotEmpty) {
    unawaited(
      storage.setString('memory_summary_model_id', config.summaryModelId),
    );
  } else {
    unawaited(storage.remove('memory_summary_model_id'));
  }
  if (config.customSummarizerSystemPrompt.trim().isNotEmpty) {
    unawaited(
      storage.setString(
        'memory_custom_summarizer_system_prompt',
        config.customSummarizerSystemPrompt,
      ),
    );
  } else {
    unawaited(storage.remove('memory_custom_summarizer_system_prompt'));
  }
  if (config.customSummarizerUserPrompt.trim().isNotEmpty) {
    unawaited(
      storage.setString(
        'memory_custom_summarizer_user_prompt',
        config.customSummarizerUserPrompt,
      ),
    );
  } else {
    unawaited(storage.remove('memory_custom_summarizer_user_prompt'));
  }
  if (config.customInjectionPrompt.trim().isNotEmpty) {
    unawaited(
      storage.setString(
        'memory_custom_injection_prompt',
        config.customInjectionPrompt,
      ),
    );
  } else {
    unawaited(storage.remove('memory_custom_injection_prompt'));
  }
}
