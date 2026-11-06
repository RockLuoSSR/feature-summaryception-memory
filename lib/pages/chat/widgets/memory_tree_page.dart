import 'package:flutter/material.dart';

import '../../../data/mock_user_settings.dart';
import '../../../models/chat_memory.dart';
import '../../../services/chat_character_resolver.dart';
import '../../../services/chat_database_service.dart';
import '../../../services/chat_memory_service.dart';
import '../../subtask_settings_page.dart';

/// 分层记忆管理页。
///
/// 展示当前分支真正生效的「顶层摘要片段」，按层分组；被更高层合并的片段
/// 不再重复展示。所有操作只影响当前会话。
class MemoryTreePage extends StatefulWidget {
  const MemoryTreePage({
    super.key,
    required this.sessionId,
    required this.activeLeafMessageId,
    this.onJumpToMessage,
  });

  final String sessionId;
  final String? activeLeafMessageId;

  /// 兼容旧调用方的跳转回调；分层摘要不绑定单条消息，当前未使用。
  final ValueChanged<String>? onJumpToMessage;

  @override
  State<MemoryTreePage> createState() => _MemoryTreePageState();
}

class _MemoryTreePageState extends State<MemoryTreePage> {
  bool _isLoading = true;
  bool _isSummarizing = false;
  List<MemorySnippet> _visibleSnippets = const [];
  int _allSnippetCount = 0;
  int _ghostedMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _isLoading = true);
    final db = ChatDatabaseService.instance;
    final path = await db.loadActivePathMessages(widget.sessionId);
    if (!mounted) return;
    final pathIds = path
        .where((message) => message.id != null)
        .map((message) => message.id!)
        .toList(growable: false);
    final all = await ChatMemoryService.instance.loadAllSnippets(
      widget.sessionId,
    );
    if (!mounted) return;
    final valid = ChatMemoryService.selectValidSnippets(
      all: all,
      pathMessageIds: pathIds,
    );
    final tops = ChatMemoryService.selectTopSnippets(valid);
    final ordered = ChatMemoryService.orderedForInjection(tops);

    setState(() {
      _visibleSnippets = ordered;
      _allSnippetCount = all.length;
      _ghostedMessageCount = valid
          .expand((snippet) => snippet.sourceMessageIds)
          .toSet()
          .length;
      _isLoading = false;
    });
  }

  Future<void> _summarizeNow() async {
    if (_isSummarizing) return;
    final path = await ChatDatabaseService.instance.loadActivePathMessages(
      widget.sessionId,
    );
    final leafId = path.isNotEmpty ? path.last.id : widget.activeLeafMessageId;
    final session = await ChatDatabaseService.instance.loadSessionById(
      widget.sessionId,
    );
    if (!mounted || leafId == null || session == null) return;

    final character = await ChatCharacterResolver.instance.resolveById(
      session.characterId,
    );
    final settings = userSettingsNotifier.value;
    final selectedId = session.selectedUserSettingId;
    final userSetting = settings.isEmpty
        ? null
        : settings.firstWhere(
            (item) => item.id == selectedId,
            orElse: () => settings.first,
          );

    setState(() => _isSummarizing = true);
    try {
      await ChatMemoryService.instance.summarizeNow(
        sessionId: widget.sessionId,
        branchLeafId: leafId,
        characterName: character?.name ?? '角色',
        userName: userSetting?.name ?? '用户',
      );
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已整理当前分支的积压对话')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('整理失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _isSummarizing = false);
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const SubTaskSettingsPage(
          initialSection: SubTaskSettingsSection.memory,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _deleteSnippet(MemorySnippet snippet) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除摘要片段'),
        content: const Text('该片段及由它合并出的更高层摘要都会被删除，确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ChatMemoryService.instance.deleteSnippet(
      sessionId: widget.sessionId,
      snippetId: snippet.id,
    );
    await _reload();
  }

  Future<void> _editSnippet(MemorySnippet snippet) async {
    final controller = TextEditingController(text: snippet.content);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑摘要'),
        content: TextField(
          controller: controller,
          maxLines: 10,
          minLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty) return;
    await ChatMemoryService.instance.updateSnippetContent(
      snippetId: snippet.id,
      content: result,
    );
    await _reload();
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空分层记忆'),
        content: const Text('将删除当前会话的全部分层摘要，原始聊天记录不受影响。确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ChatMemoryService.instance.clearSession(widget.sessionId);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = memoryExtractionNotifier.value.enabled;
    return Scaffold(
      appBar: AppBar(
        title: const Text('分层记忆'),
        actions: [
          if (enabled)
            _isSummarizing
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : IconButton(
                    tooltip: '立即整理积压对话',
                    onPressed: _summarizeNow,
                    icon: const Icon(Icons.auto_awesome),
                  ),
          IconButton(
            tooltip: '刷新',
            onPressed: _isLoading ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '记忆设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: '清空记忆',
            onPressed: _visibleSnippets.isEmpty && _allSnippetCount == 0
                ? null
                : _clearAll,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _buildSummaryHeader(context, enabled),
                const SizedBox(height: 16),
                if (!enabled)
                  _buildDisabledCard(context)
                else if (_visibleSnippets.isEmpty)
                  _buildEmptyCard(context)
                else
                  ..._buildLayerGroups(context),
              ],
            ),
    );
  }

  Widget _buildSummaryHeader(BuildContext context, bool enabled) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            enabled ? Icons.layers_outlined : Icons.layers_clear_outlined,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  enabled ? '当前分支生效摘要 ${_visibleSnippets.length} 条' : '分层记忆未启用',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '全部片段 $_allSnippetCount 条 · 已摘要消息 $_ghostedMessageCount 条',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDisabledCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text('启用后才能自动压缩旧对话。'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('前往启用'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '当前分支还没有生成摘要。继续聊天后，超出「逐字保留轮数」的旧对话会自动压缩。',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }

  List<Widget> _buildLayerGroups(BuildContext context) {
    final grouped = <int, List<MemorySnippet>>{};
    for (final snippet in _visibleSnippets) {
      grouped.putIfAbsent(snippet.layer, () => []).add(snippet);
    }
    final layers = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    final widgets = <Widget>[];
    for (final layer in layers) {
      final snippets = grouped[layer]!;
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Text(
                layer == 0 ? '第 0 层 · 详细摘要' : '第 $layer 层 · 高层摘要',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(width: 8),
              Text(
                '${snippets.length} 条',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
      for (final snippet in snippets) {
        widgets.add(_buildSnippetCard(context, snippet));
      }
      widgets.add(const SizedBox(height: 12));
    }
    return widgets;
  }

  Widget _buildSnippetCard(BuildContext context, MemorySnippet snippet) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _editSnippet(snippet),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      snippet.content,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${snippet.sourceMessageIds.length} 条源消息'
                      '${snippet.isSeed ? ' · 种子提升' : ''}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '删除',
                onPressed: () => _deleteSnippet(snippet),
                icon: const Icon(Icons.delete_outline, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
