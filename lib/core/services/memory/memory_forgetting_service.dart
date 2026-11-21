import 'dart:math';

import '../../models/memory_entry.dart';
import 'memory_repository.dart';

/// Outcome of one forgetting pass (preview or apply).
class MemoryForgettingReport {
  MemoryForgettingReport({
    required this.scanned,
    required this.exemptCount,
    required this.baselineCount,
    required this.pinnedCount,
    required Map<MemoryType, int> byType,
    required List<String> archiveIds,
    required Map<String, int> strengthBuckets,
    required this.dryRun,
    required this.applied,
    required this.updatedCount,
    required this.archivedCount,
    required this.now,
  }) : byType = Map<MemoryType, int>.unmodifiable(byType),
       archiveIds = List<String>.unmodifiable(archiveIds),
       strengthBuckets = Map<String, int>.unmodifiable(strengthBuckets);

  /// Active entries seen in this pass, including exempt types.
  final int scanned;

  /// Active entries whose type is exempt from decay and automatic archiving.
  final int exemptCount;

  /// Entries that have no decay timestamp yet and start a fresh baseline.
  final int baselineCount;

  /// Pinned entries skipped by this pass.
  final int pinnedCount;

  /// Active entry counts by type, including exempt types.
  final Map<MemoryType, int> byType;

  /// Entries that should be archived (preview) or were archived (apply).
  final List<String> archiveIds;

  /// Distribution of the decayed strength of non-exempt entries.
  final Map<String, int> strengthBuckets;

  /// True when no writes were performed.
  final bool dryRun;

  /// True when this report came from a writing pass.
  final bool applied;

  /// Entries with a written strength in apply, or entries that would be
  /// written in preview.
  final int updatedCount;

  /// Entries archived in apply, or archive candidates in preview.
  final int archivedCount;

  /// Clock used for the pass.
  final DateTime now;

  String get summary =>
      'scanned=$scanned exempt=$exemptCount baseline=$baselineCount '
      'pinned=$pinnedCount updated=$updatedCount '
      'archiveCandidates=${archiveIds.length} archived=$archivedCount '
      'dryRun=$dryRun';
}

/// Strength decay and automatic archiving for V2 memories.
///
/// The service only reads the active V2 entries. It never deletes content:
/// automatic forgetting flips [MemoryStatus.archived] and records an
/// [MemoryEntry.archiveReason], so entries remain restorable.
class MemoryForgettingService {
  MemoryForgettingService({
    required this.repository,
    this.minAgeDays = 7,
    this.baseTauDays = 30.0,
    this.archiveThreshold = 0.3,
    this.dryRun = true,
    this.exemptTypes = const {MemoryType.identity, MemoryType.instruction},
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MemoryRepository repository;

  /// Minimum age before an entry can be automatically archived.
  final int minAgeDays;

  /// Base retention time constant used by the exponential decay formula.
  final double baseTauDays;

  /// Decayed strength below which an old entry is archived.
  final double archiveThreshold;

  /// When true, [apply] behaves like [preview] and writes nothing.
  final bool dryRun;

  /// Types that never decay automatically and are never auto-archived.
  final Set<MemoryType> exemptTypes;

  final DateTime Function() _clock;

  String get archiveReason => 'forgetting:strength<$archiveThreshold';

  /// Computes the pass without writing anything.
  Future<MemoryForgettingReport> preview({Set<String>? onlyIds}) =>
      _run(write: false, onlyIds: onlyIds);

  /// Applies strength updates and archives candidates unless [dryRun] is on.
  Future<MemoryForgettingReport> apply({Set<String>? onlyIds}) =>
      _run(write: !dryRun, onlyIds: onlyIds);

  Future<MemoryForgettingReport> _run({
    required bool write,
    Set<String>? onlyIds,
  }) async {
    final now = _clock().toUtc();
    final all = await repository.readAll();

    final byType = <MemoryType, int>{};
    final updates = <String, double>{};
    final archiveIds = <String>[];
    final buckets = <String, int>{};
    var exemptCount = 0;
    var baselineCount = 0;
    var pinnedCount = 0;

    for (final entry in all) {
      if (entry.status != MemoryStatus.active) continue;
      if (onlyIds != null && !onlyIds.contains(entry.id)) continue;

      byType.update(entry.type, (count) => count + 1, ifAbsent: () => 1);
      if (exemptTypes.contains(entry.type)) {
        exemptCount++;
        continue;
      }
      if (entry.pinned) {
        pinnedCount++;
        continue;
      }

      final tau =
          baseTauDays *
          (1 + 0.5 * max(0.0, -entry.valence)) *
          (1 + 0.3 * entry.arousal) *
          (1 + entry.importance);
      final lastDecayAt = entry.lastDecayAt;
      final nextStrength = lastDecayAt == null
          ? entry.strength
          : _clamp01(
              entry.strength * exp(-_daysBetween(lastDecayAt, now) / tau),
            );
      if (lastDecayAt == null) baselineCount++;

      updates[entry.id] = nextStrength;
      final bucket = _bucket(nextStrength);
      buckets.update(bucket, (count) => count + 1, ifAbsent: () => 1);

      final ageDays = _daysBetween(entry.createdAt, now);
      if (lastDecayAt != null &&
          ageDays >= minAgeDays &&
          nextStrength < archiveThreshold) {
        archiveIds.add(entry.id);
      }
    }

    var updatedCount = updates.length;
    var archivedCount = archiveIds.length;
    if (write) {
      updatedCount = await repository.updateForgettingStrengths(
        updates,
        decayedAt: now,
      );
      archivedCount = await repository.archiveMany(
        archiveIds,
        reason: archiveReason,
      );
    }

    return MemoryForgettingReport(
      scanned: byType.values.fold(0, (sum, count) => sum + count),
      exemptCount: exemptCount,
      baselineCount: baselineCount,
      pinnedCount: pinnedCount,
      byType: byType,
      archiveIds: archiveIds,
      strengthBuckets: buckets,
      dryRun: !write,
      applied: write,
      updatedCount: updatedCount,
      archivedCount: archivedCount,
      now: now,
    );
  }

  static double _daysBetween(DateTime from, DateTime to) {
    final micros = to.difference(from).inMicroseconds;
    if (micros <= 0) return 0;
    return micros / Duration.microsecondsPerDay;
  }

  static double _clamp01(num value) {
    final parsed = value.toDouble();
    if (!parsed.isFinite) return 0;
    return parsed.clamp(0.0, 1.0).toDouble();
  }

  static String _bucket(double strength) {
    if (strength < 0.3) return '<0.3';
    if (strength < 0.5) return '0.3-0.5';
    if (strength < 0.7) return '0.5-0.7';
    if (strength < 0.9) return '0.7-0.9';
    return '>=0.9';
  }
}
