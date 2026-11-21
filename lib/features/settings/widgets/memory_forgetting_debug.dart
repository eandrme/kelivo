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
  static const Set<String> _debugIds = {
    'mem_d00d0001',
    'mem_d00d0002',
    'mem_d00d0003',
    'mem_d00d0004',
    'mem_d00d0005',
  };

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
      final service = MemoryForgettingService(
        repository: provider.repository,
        dryRun: false,
      );
      final report = await service.apply(onlyIds: _debugIds);
      if (report.scanned == 0) return 'No debug entries. Tap Seed first.';
      await provider.refreshAll();
      return 'APPLIED DEBUG\n${_formatReport(report)}';
    });
  }

  Future<void> _runAll() {
    return _run(() async {
      final provider = context.read<MemoryProviderV2>();
      final repository = provider.repository;
      final failures = <String>[];
      void check(bool ok, String message) {
        if (!ok) failures.add(message);
      }

      await _clearDebugMemories(repository);
      await provider.refreshAll();

      final beforeEntries = await repository.readAll();
      final realIds = beforeEntries
          .map((entry) => entry.id)
          .where((id) => !id.startsWith('mem_d00d'))
          .toSet();
      final realBefore = {
        for (final entry in beforeEntries)
          if (realIds.contains(entry.id)) entry.id: entry,
      };

      final realPreview = await provider.forgetting.preview();
      if (realPreview.archiveIds.isNotEmpty) {
        return 'RUN ALL: ABORT\n'
            'real data already has ${realPreview.archiveIds.length} archive '
            'candidates; refusing to apply baseline.\n'
            '${_formatReport(realPreview)}';
      }

      final baseline = await MemoryForgettingService(
        repository: repository,
        dryRun: false,
      ).apply();
      check(
        baseline.archivedCount == 0,
        'baseline archived ${baseline.archivedCount} real entries',
      );
      await provider.refreshAll();

      final seeded = await _seedDebugMemories(repository);
      check(seeded == _debugIds.length, 'seed count=$seeded');
      await provider.refreshAll();

      final preview = await provider.forgetting.preview(onlyIds: _debugIds);
      check(preview.scanned == 5, 'debug preview scanned=${preview.scanned}');
      check(
        preview.exemptCount == 2,
        'debug preview exempt=${preview.exemptCount}',
      );
      check(
        preview.archiveIds.length == 1 &&
            preview.archiveIds.first == 'mem_d00d0001',
        'debug candidates=${preview.archiveIds.join(',')}',
      );

      final debugApply = await MemoryForgettingService(
        repository: repository,
        dryRun: false,
      ).apply(onlyIds: _debugIds);
      check(
        debugApply.archivedCount == 1,
        'debug apply archived=${debugApply.archivedCount}',
      );
      await provider.refreshAll();

      final afterApply = await repository.readAll();
      MemoryEntry find(String id) =>
          afterApply.firstWhere((entry) => entry.id == id);
      final weak = find('mem_d00d0001');
      check(weak.status == MemoryStatus.archived, 'weak not archived');
      check(
        weak.archiveReason == 'forgetting:strength<0.3',
        'weak reason=${weak.archiveReason}',
      );
      final young = find('mem_d00d0002');
      check(young.status == MemoryStatus.active, 'young was archived');
      final identity = find('mem_d00d0003');
      check(
        identity.status == MemoryStatus.active && identity.strength == 0.1,
        'identity changed',
      );
      final instruction = find('mem_d00d0004');
      check(
        instruction.status == MemoryStatus.active &&
            instruction.strength == 0.1,
        'instruction changed',
      );
      final keep = find('mem_d00d0005');
      check(keep.status == MemoryStatus.active, 'keep was archived');

      await repository.restore('mem_d00d0001');
      await provider.refreshAll();
      final restored = (await repository.readAll()).firstWhere(
        (entry) => entry.id == 'mem_d00d0001',
      );
      check(restored.status == MemoryStatus.active, 'restore status failed');
      check(restored.archiveReason == null, 'restore reason not cleared');
      check(restored.strength == 1.0, 'restore strength=${restored.strength}');
      check(
        restored.lastDecayAt == null,
        'restore lastDecayAt=${restored.lastDecayAt}',
      );

      final afterEntries = await repository.readAll();
      for (final entry in realBefore.values) {
        final after = afterEntries.firstWhere((item) => item.id == entry.id);
        check(after.status == entry.status, 'real ${entry.id} status changed');
        check(
          after.strength == entry.strength,
          'real ${entry.id} strength changed',
        );
      }

      await _clearDebugMemories(repository);
      await provider.refreshAll();
      final finalEntries = await repository.readAll();
      check(finalEntries.length == beforeEntries.length, 'real count changed');
      check(
        finalEntries.every((entry) => !entry.id.startsWith('mem_d00d')),
        'debug entries remain',
      );

      final lines = [
        failures.isEmpty ? 'RUN ALL: PASS' : 'RUN ALL: FAIL',
        'real entries: ${realBefore.length}',
        'baseline: updated=${baseline.updatedCount} '
            'archived=${baseline.archivedCount}',
        'debug preview: scanned=${preview.scanned} '
            'exempt=${preview.exemptCount} '
            'candidates=${preview.archiveIds.join(',')}',
        'debug apply: updated=${debugApply.updatedCount} '
            'archived=${debugApply.archivedCount}',
        'restore: status=${restored.status} strength=${restored.strength} '
            'reason=${restored.archiveReason}',
        if (failures.isNotEmpty) ...[
          '',
          ...failures.map((failure) => '- $failure'),
        ],
      ];
      return lines.join('\n');
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
          'baseline=${report.baselineCount} pinned=${report.pinnedCount} '
          'updated=${report.updatedCount} archived=${report.archivedCount}',
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
                  FilledButton(
                    onPressed: _busy ? null : _runAll,
                    child: const Text('Run all'),
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
