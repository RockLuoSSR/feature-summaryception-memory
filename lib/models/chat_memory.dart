import 'package:freezed_annotation/freezed_annotation.dart';

part 'chat_memory.freezed.dart';

/// 一条分层摘要片段。
///
/// [layer] 为所在层（0 为最细粒度）：层内片段积累到阈值后会向上合并。
/// [sourceMessageIds] 记录该片段覆盖的原始消息，用于判断它是否属于当前分支。
/// [parentSnippetIds] 记录它合并了哪些下层片段，用于避免重复注入。
@freezed
abstract class MemorySnippet with _$MemorySnippet {
  const factory MemorySnippet({
    required String id,
    required String sessionId,
    required int layer,
    required String content,
    @Default([]) List<String> sourceMessageIds,
    @Default([]) List<String> parentSnippetIds,
    @Default(false) bool isSeed,
    @Default('') String createdOnLeafId,
    required int order,
    required DateTime createdAt,
  }) = _MemorySnippet;
}

@freezed
abstract class MemoryExtractionConfig with _$MemoryExtractionConfig {
  const MemoryExtractionConfig._();

  const factory MemoryExtractionConfig({
    @Default(false) bool enabled,
    /// 始终保留为逐字上下文的最近助手回复轮数。
    @Default(10) int verbatimTurns,
    /// 每次摘要覆盖的助手回复轮数。
    @Default(3) int turnsPerSummary,
    /// 单层最多保留的片段数，超出后向上合并。
    @Default(20) int snippetsPerLayer,
    /// 向上合并时一次合并的片段数。
    @Default(3) int promotionBatch,
    /// 最大层数（含第 0 层）。
    @Default(5) int maxLayers,
    /// 摘要任务使用的模型；为空时回退到当前聊天模型。
    @Default('') String summaryModelId,
    @Default('') String customSummarizerSystemPrompt,
    @Default('') String customSummarizerUserPrompt,
    @Default('') String customInjectionPrompt,
  }) = _MemoryExtractionConfig;

  bool get hasCustomSummarizerSystemPrompt =>
      customSummarizerSystemPrompt.trim().isNotEmpty;

  bool get hasCustomSummarizerUserPrompt =>
      customSummarizerUserPrompt.trim().isNotEmpty;

  bool get hasCustomInjectionPrompt => customInjectionPrompt.trim().isNotEmpty;
}
