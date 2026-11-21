import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/memory_entry.dart';
import '../../../core/providers/memory_provider_v2.dart';
import '../../../core/services/memory/memory_forgetting_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import 'memory_ui.dart';

/// Preview and apply automatic forgetting for the current memory set.
///
/// Labels intentionally reuse existing generic strings until dedicated
/// forgetting strings are added through the localization workflow.
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
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _apply() async {
    final report = _report;
    if (report == null || report.archiveIds.isEmpty || _applying) return;
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final candidates = _candidates;
    final busy = _loading || _applying;
    return AlertDialog(
      title: Text(l10n.memoryEntryActionArchive),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            : _error != null
            ? Text('$_error')
            : candidates.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Icon(Lucide.CheckCircle, size: 36, color: cs.primary),
                ),
              )
            : ConstrainedBox(
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
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : _preview,
          child: Text(l10n.assistantEditPreviewTitle),
        ),
        TextButton(
          onPressed: busy || candidates.isEmpty ? null : _apply,
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
