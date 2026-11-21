import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/memory_entry.dart';
import '../../../core/providers/memory_provider_v2.dart';
import '../../../core/services/memory/memory_forgetting_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import 'memory_ui.dart';

String memoryForgettingLabel(BuildContext context) =>
    AppLocalizations.of(context)!.memoryForgettingTitle;

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
  Set<String> _selected = const {};
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
        _selected = report.archiveIds.toSet();
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
    if (report == null || _selected.isEmpty || _applying) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.memoryForgettingTitle),
        content: Text(l10n.memoryForgettingApplyConfirm(_selected.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.settingsSearchCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.statsPageCustomRangeApply),
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
      await service.apply(onlyIds: _selected.toSet());
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
        title: Text(AppLocalizations.of(context)!.memoryForgettingTitle),
        content: Text(
          AppLocalizations.of(
            context,
          )!.memoryForgettingBaselineConfirm(report.baselineCount),
        ),
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
      title: Text(l10n.memoryForgettingTitle),
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
                    l10n.memoryForgettingCandidateHint,
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
                      itemBuilder: (_, index) {
                        final entry = candidates[index];
                        return _CandidateTile(
                          entry: entry,
                          selected: _selected.contains(entry.id),
                          onChanged: (value) => setState(() {
                            if (value) {
                              _selected = {..._selected, entry.id};
                            } else {
                              _selected = _selected
                                  .where((id) => id != entry.id)
                                  .toSet();
                            }
                          }),
                        );
                      },
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Lucide.CheckCircle, size: 36, color: cs.primary),
                  const SizedBox(height: 8),
                  Text(l10n.memoryForgettingEmpty),
                  if (report != null && report.baselineCount > 0) ...[
                    const SizedBox(height: 10),
                    Text(
                      l10n.memoryForgettingBaselineHint(report.baselineCount),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: cs.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: busy ? null : _initializeBaseline,
                      child: Text(l10n.memoryForgettingInitialize),
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
          onPressed: busy || _selected.isEmpty ? null : _applyCandidates,
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
  const _CandidateTile({
    required this.entry,
    required this.selected,
    required this.onChanged,
  });

  final MemoryEntry entry;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IosCheckbox(
              value: selected,
              size: 20,
              hitTestSize: 28,
              borderWidth: 1.6,
              activeColor: cs.primary,
              borderColor: cs.primary.withValues(alpha: 0.55),
              onChanged: onChanged,
            ),
            const SizedBox(width: 4),
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
