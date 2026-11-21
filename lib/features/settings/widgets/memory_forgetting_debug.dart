import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/memory_entry.dart';
import '../../../core/providers/memory_provider_v2.dart';
import '../../../core/services/memory/memory_forgetting_service.dart';
import '../../../core/services/memory/memory_repository.dart';

/// Debug-only controls for exercising the affect/forgetting layer on a device.
///
/// The entry point is compiled out of release builds by the caller's
/// [kDebugMode] guard.
Future<void> showMemoryForgettingDebugDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _MemoryForgettingDebugDialog(),
  );
}

class _MemoryForgettingDebugDialog extends StatefulWidget {
  const _MemoryForgettingDebugDialog();

  @override
  State<_MemoryForgettingDebugDialog> createState() =>
      _MemoryForgettingDebugDialogState();
}

class _MemoryForgettingDebugDialogState
    extends State<_MemoryForgettingDebugDialog> {
  String _output = 'Ready. Seed test memories, then run Preview or Apply.';
  bool _busy = false;

  Future<void> _run(Future<String> Function() task) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _output = 'Running...';
    });
    try {
      final output = await task();
      if (!mounted) return;
      setState(() => _output = output);
    } catch (error) {
      if (!mounted) return;
      setState(() => _output = 'Error: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _seed() {
    return _run(() async {
      final provider = context.read<MemoryProviderV2>();
      final count = await _seedDebugMemories(provider.repository);
      await provider.refreshAll();
      return 'Seeded $count debug memories.\nTap Preview to inspect.';
    });
  }

  Future<void> _clear() {
    return _run(() async {
      final provider = context.read<MemoryProviderV2>();
      final removed = await _clearDebugMemories(provider.repository);
      await provider.refreshAll();
      return 'Removed $removed debug memories.';
    });
  }

  Future<void> _preview() {
    return _run(() async {
      final provider = context.read<MemoryProviderV2>();
      final report = await provider.forgetting.preview();
      return _formatReport(report);
    });
  }

  Future<void> _apply() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Apply forgetting (all)?'),
        content: const Text(
          'This writes strength/lastDecayAt and archives every candidate in '
          'the local database. Prefer Apply one or Apply debug first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Apply all'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _run(() async {
      final provider = context.read<MemoryProviderV2>();
      final service = MemoryForgettingService(
        repository: provider.repository,
        dryRun: false,
      );
      final report = await service.apply();
      await provider.refreshAll();
      return 'APPLIED ALL\n${_formatReport(report)}';
    });
  }

  Future<void> _applyOne() {
    return _run(() async {
      final provider = context.read<MemoryProviderV2>();
      final preview = await provider.forgetting.preview();
      if (preview.archiveIds.isEmpty) return 'No archive candidates.';
      final id = preview.archiveIds.first;
      final service = MemoryForgettingService(
        repository: provider.repository,
        dryRun: false,
      );
      final report = await service.apply(onlyIds: {id});
      await provider.refreshAll();
      return 'APPLIED ONE: $id\n${_formatReport(report)}';
    });
  }

  Future<void> _applyDebug() {
    return _run(() async {
      final provider = context.read<MemoryProviderV2>();
      final ids = provider.entries
          .where((entry) => entry.id.startsWith('mem_d00d'))
          .map((entry) => entry.id)
          .toSet();
      if (ids.isEmpty) return 'No debug entries. Tap Seed first.';
      final service = MemoryForgettingService(
        repository: provider.repository,
        dryRun: false,
      );
      final report = await service.apply(onlyIds: ids);
      await provider.refreshAll();
      return 'APPLIED DEBUG\n${_formatReport(report)}';
    });
  }

  String _formatReport(MemoryForgettingReport report) {
    final byType = report.byType.entries
        .map((entry) => '${MemoryEntry.typeToString(entry.key)}=${entry.value}')
        .join(', ');
    final buckets = report.strengthBuckets.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(', ');
    return [
      'dryRun=${report.dryRun} applied=${report.applied}',
      'scanned=${report.scanned} exempt=${report.exemptCount} '
          'baseline=${report.baselineCount} updated=${report.updatedCount} '
          'archived=${report.archivedCount}',
      'byType: $byType',
      'strength: $buckets',
      'candidates: ${report.archiveIds.join(', ')}',
    ].join('\n');
  }

  Future<int> _seedDebugMemories(MemoryRepository repository) {
    final now = DateTime.now().toUtc();
    MemoryEntry make({
      required String id,
      required MemoryType type,
      required String content,
      required int ageDays,
      required double strength,
      double valence = 0.0,
      double arousal = 0.3,
    }) {
      final created = now.subtract(Duration(days: ageDays));
      return MemoryEntry(
        id: id,
        scope: MemoryScope.global,
        type: type,
        content: content,
        source: MemorySource.manual,
        createdAt: created,
        updatedAt: created,
        lastDecayAt: created,
        valence: valence,
        arousal: arousal,
        strength: strength,
      );
    }

    final seeds = [
      make(
        id: 'mem_d00d0001',
        type: MemoryType.workflow,
        content: '[debug] 10 天前、strength 0.2，预期归档',
        ageDays: 10,
        strength: 0.2,
        valence: -0.6,
        arousal: 0.8,
      ),
      make(
        id: 'mem_d00d0002',
        type: MemoryType.workflow,
        content: '[debug] 6 天前、strength 0.2，年龄不够不归档',
        ageDays: 6,
        strength: 0.2,
      ),
      make(
        id: 'mem_d00d0003',
        type: MemoryType.identity,
        content: '[debug] identity 豁免，不衰减不归档',
        ageDays: 90,
        strength: 0.1,
      ),
      make(
        id: 'mem_d00d0004',
        type: MemoryType.instruction,
        content: '[debug] instruction 豁免，不衰减不归档',
        ageDays: 90,
        strength: 0.1,
      ),
      make(
        id: 'mem_d00d0005',
        type: MemoryType.voice,
        content: '[debug] 30 天前、strength 0.9，保留',
        ageDays: 30,
        strength: 0.9,
        valence: 0.5,
        arousal: 0.6,
      ),
    ];

    return repository.runExclusive(() async {
      final all = await repository.readAll();
      all.removeWhere((entry) => entry.id.startsWith('mem_d00d'));
      all.addAll(seeds);
      await repository.writeAll(all);
      return seeds.length;
    });
  }

  Future<int> _clearDebugMemories(MemoryRepository repository) {
    return repository.runExclusive(() async {
      final all = await repository.readAll();
      final before = all.length;
      all.removeWhere((entry) => entry.id.startsWith('mem_d00d'));
      final removed = before - all.length;
      if (removed > 0) await repository.writeAll(all);
      return removed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Memory forgetting debug'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _busy ? null : _seed,
                    child: const Text('Seed'),
                  ),
                  FilledButton.tonal(
                    onPressed: _busy ? null : _preview,
                    child: const Text('Preview'),
                  ),
                  FilledButton.tonal(
                    onPressed: _busy ? null : _applyOne,
                    child: const Text('Apply one'),
                  ),
                  FilledButton.tonal(
                    onPressed: _busy ? null : _applyDebug,
                    child: const Text('Apply debug'),
                  ),
                  FilledButton.tonal(
                    onPressed: _busy ? null : _apply,
                    child: const Text('Apply all'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : _clear,
                    child: const Text('Clear'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  _output,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
