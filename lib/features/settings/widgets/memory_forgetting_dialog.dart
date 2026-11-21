import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/memory_entry.dart';
import '../../../core/providers/memory_provider_v2.dart';
import '../../../core/services/memory/memory_forgetting_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import 'memory_ui.dart';

bool _isZh(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh';

String memoryForgettingLabel(BuildContext context) =>
    _isZh(context) ? '自动遗忘' : 'Automatic forgetting';

String _emptyLabel(BuildContext context) =>
    _isZh(context) ? '没有需要遗忘的记忆' : 'Nothing to forget';

String _candidateHint(BuildContext context) => _isZh(context)
    ? '以下记忆会因强度过低被归档，正文保留，可恢复。'
    : 'These memories will be archived for low strength. Content is kept and restorable.';

String _baselineHint(BuildContext context, int count) => _isZh(context)
    ? '有 $count 条旧记忆还没有衰减起点。'
    : '$count legacy memories have no decay baseline yet.';

String _applyConfirm(BuildContext context, int count) => _isZh(context)
    ? '将归档 $count 条记忆，正文会保留，可恢复。'
    : 'Archive $count memories? Their content is kept and can be restored.';

String _baselineConfirm(BuildContext context, int count) => _isZh(context)
    ? '从当前时间开始计算这 $count 条旧记忆的衰减？不会立即归档。'
    : 'Start decay for $count legacy memories from now? Nothing is archived.';

String _baselineLabel(BuildContext context) =>
    _isZh(context) ? '初始化衰减' : 'Initialize decay';

/// Preview and apply automatic forgetting for the current memory set.
Future<void> showMemoryForgettingDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _MemoryForgettingDialog(),
  );
}

class _MemoryForgettingDialog extends StatefulWidget {
  const _MemoryForgettingDialog();

  @override
  State<_MemoryForgettingDialog> createState() =>
      _MemoryForgettingDialogState();
}

class _MemoryForgettingDialogState extends State<_MemoryForgettingDialog> {
  MemoryForgettingReport? _report;
  Map<String, MemoryEntry> _entries = const {};
  bool _loading = true;
  bool _applying = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _preview();
  }

  List<MemoryEntry> get _candidates => (_report?.archiveIds ?? const <String>[])
      .map((id) => _entries[id])
      .whereType<MemoryEntry>()
      .toList(growable: false);

  Future<void> _preview() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final provider = context.read<MemoryProviderV2>();
      final report = await provider.forgetting.preview();
      final all = await provider.repository.readAll();
      if (!mounted) return;
      setState(() {
        _report = report;
        _entries = {for (final entry in all) entry.id: entry};
        _loading = false;
        _applying = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
        _applying = false;
      });
    }
  }

  Future<void> _applyCandidates() async {
    final report = _report;
    if (report == null || report.archiveIds.isEmpty || _applying) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(memoryForgettingLabel(context)),
        content: Text(_applyConfirm(context, report.archiveIds.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppLocalizations.of(context)!.settingsSearchCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              AppLocalizations.of(context)!.statsPageCustomRangeApply,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _applying = true);
    try {
      final provider = context.read<MemoryProviderV2>();
      final service = MemoryForgettingService(
        repository: provider.repository,
        dryRun: false,
      );
      await service.apply(onlyIds: report.archiveIds.toSet());
      await provider.refreshAll();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _applying = false;
      });
    }
  }

  Future<void> _initializeBaseline() async {
    final report = _report;
    if (report == null ||
        report.baselineCount == 0 ||
        report.archiveIds.isNotEmpty ||
        _applying) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(memoryForgettingLabel(context)),
        content: Text(_baselineConfirm(context, report.baselineCount)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppLocalizations.of(context)!.settingsSearchCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              AppLocalizations.of(context)!.statsPageCustomRangeApply,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _applying = true);
    try {
      final provider = context.read<MemoryProviderV2>();
      final service = MemoryForgettingService(
        repository: provider.repository,
        dryRun: false,
      );
      await service.apply();
      await provider.refreshAll();
      if (!mounted) return;
      await _preview();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _applying = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final candidates = _candidates;
    final report = _report;
    final busy = _loading || _applying;
    return AlertDialog(
      title: Text(memoryForgettingLabel(context)),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            : _error != null
            ? Text('$_error')
            : candidates.isNotEmpty
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _candidateHint(context),
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.35,
                      color: cs.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 360),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: candidates.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 12,
                        color: cs.outlineVariant.withValues(alpha: 0.5),
                      ),
                      itemBuilder: (_, index) =>
                          _CandidateTile(entry: candidates[index]),
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Lucide.CheckCircle, size: 36, color: cs.primary),
                  const SizedBox(height: 8),
                  Text(_emptyLabel(context)),
                  if (report != null && report.baselineCount > 0) ...[
                    const SizedBox(height: 10),
                    Text(
                      _baselineHint(context, report.baselineCount),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: cs.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: busy ? null : _initializeBaseline,
                      child: Text(_baselineLabel(context)),
                    ),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : _preview,
          child: Text(l10n.assistantEditPreviewTitle),
        ),
        TextButton(
          onPressed: busy || candidates.isEmpty ? null : _applyCandidates,
          child: Text(l10n.statsPageCustomRangeApply),
        ),
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({required this.entry});

  final MemoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            MemoryBadge(
              label: memoryTypeLabel(l10n, entry.type),
              color: memoryTypeColor(cs, entry.type),
            ),
            const Spacer(),
            MemoryAffectStats(entry: entry),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          entry.content,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, height: 1.35),
        ),
      ],
    );
  }
}
