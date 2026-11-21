import 'dart:convert';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_data.dart';
import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/memory_entry.dart';
import 'package:Kelivo/core/services/memory/memory_forgetting_service.dart';
import 'package:Kelivo/core/services/memory/memory_repository.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase database;
  late BusinessRepository businessRepository;
  late BusinessPreferences preferences;
  late ChatDatabaseRepository chatRepository;
  late MemoryRepository memoryRepository;
  final now = DateTime.utc(2026, 9, 1, 12);

  setUp(() async {
    database = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA foreign_keys = ON;'),
      ),
    );
    businessRepository = BusinessRepository(database);
    preferences = BusinessPreferences(businessRepository);
    chatRepository = ChatDatabaseRepository(database);
    memoryRepository = MemoryRepository(preferences);
    await chatRepository.ensureReady();
    await preferences.load();
  });

  tearDown(() => database.close());

  Future<void> putEntry({
    required String id,
    required String content,
    MemoryType type = MemoryType.workflow,
    MemoryStatus status = MemoryStatus.active,
    double valence = 0.0,
    double arousal = 0.3,
    double strength = 1.0,
    DateTime? createdAt,
    DateTime? lastDecayAt,
    bool noDecayBaseline = false,
    String? archiveReason,
  }) async {
    final created = createdAt ?? now.subtract(const Duration(days: 30));
    final effectiveLastDecayAt = noDecayBaseline
        ? null
        : (lastDecayAt ?? created);
    final raw = preferences.getString(BusinessEntityKind.memoryEntry.sourceKey);
    final entries = <Map<String, dynamic>>[
      if (raw != null && raw.isNotEmpty)
        for (final item in jsonDecode(raw) as List)
          (item as Map).cast<String, dynamic>(),
    ];
    entries.removeWhere((item) => item['id'] == id);
    entries.add({
      'id': id,
      'scope': 'global',
      'assistantId': null,
      'type': MemoryEntry.typeToString(type),
      'status': MemoryEntry.statusToString(status),
      'content': content,
      'source': 'manual',
      'relatedIds': const <String>[],
      'createdAt': created.microsecondsSinceEpoch,
      'updatedAt': created.microsecondsSinceEpoch,
      'valence': valence,
      'arousal': arousal,
      'strength': strength,
      'lastDecayAt': effectiveLastDecayAt?.microsecondsSinceEpoch,
      'archiveReason': archiveReason,
    });
    await preferences.setString(
      BusinessEntityKind.memoryEntry.sourceKey,
      jsonEncode(entries),
    );
  }

  MemoryForgettingService service({bool dryRun = true}) {
    return MemoryForgettingService(
      repository: memoryRepository,
      dryRun: dryRun,
      clock: () => now,
    );
  }

  test('preview computes decay and candidates without writing', () async {
    await putEntry(
      id: 'mem_keep0001',
      content: 'Keep',
      createdAt: now.subtract(const Duration(days: 10)),
      strength: 1.0,
    );
    await putEntry(
      id: 'mem_weak0001',
      content: 'Weak',
      createdAt: now.subtract(const Duration(days: 10)),
      strength: 0.4,
    );
    await putEntry(
      id: 'mem_young001',
      content: 'Young',
      createdAt: now.subtract(const Duration(days: 6)),
      strength: 0.2,
    );
    await putEntry(
      id: 'mem_arch0001',
      content: 'Already archived',
      status: MemoryStatus.archived,
      createdAt: now.subtract(const Duration(days: 30)),
      strength: 0.1,
    );

    final report = await service().preview();

    expect(report.dryRun, isTrue);
    expect(report.applied, isFalse);
    expect(report.scanned, 3);
    expect(report.updatedCount, 3);
    expect(report.archiveIds, ['mem_weak0001']);
    expect(report.archivedCount, 1);
    expect(report.byType[MemoryType.workflow], 3);
    expect(report.strengthBuckets['<0.3'], 2);
    expect(report.strengthBuckets['0.7-0.9'], 1);
    expect(report.summary, contains('dryRun=true'));

    final entries = await memoryRepository.readAll();
    final weak = entries.firstWhere((entry) => entry.id == 'mem_weak0001');
    expect(weak.strength, 0.4);
    expect(weak.status, MemoryStatus.active);
    expect(
      weak.lastDecayAt!.microsecondsSinceEpoch,
      now.subtract(const Duration(days: 10)).microsecondsSinceEpoch,
    );

    final dryApply = await service().apply();
    expect(dryApply.dryRun, isTrue);
    expect(dryApply.applied, isFalse);
    final unchanged = (await memoryRepository.readAll()).firstWhere(
      (entry) => entry.id == 'mem_weak0001',
    );
    expect(unchanged.strength, 0.4);
    expect(
      unchanged.lastDecayAt!.microsecondsSinceEpoch,
      now.subtract(const Duration(days: 10)).microsecondsSinceEpoch,
    );
  });

  test('apply writes strength, lastDecayAt, and archives candidates', () async {
    await putEntry(
      id: 'mem_keep0001',
      content: 'Keep',
      createdAt: now.subtract(const Duration(days: 10)),
      strength: 1.0,
    );
    await putEntry(
      id: 'mem_weak0001',
      content: 'Weak',
      createdAt: now.subtract(const Duration(days: 10)),
      strength: 0.4,
    );
    await putEntry(
      id: 'mem_young001',
      content: 'Young',
      createdAt: now.subtract(const Duration(days: 6)),
      strength: 0.2,
    );

    final report = await service(dryRun: false).apply();

    expect(report.dryRun, isFalse);
    expect(report.applied, isTrue);
    expect(report.updatedCount, 3);
    expect(report.archivedCount, 1);

    final entries = await memoryRepository.readAll();
    final weak = entries.firstWhere((entry) => entry.id == 'mem_weak0001');
    expect(weak.status, MemoryStatus.archived);
    expect(weak.archiveReason, 'forgetting:strength<0.3');
    expect(weak.strength, closeTo(0.2946, 0.001));
    expect(
      weak.lastDecayAt!.microsecondsSinceEpoch,
      now.microsecondsSinceEpoch,
    );

    final keep = entries.firstWhere((entry) => entry.id == 'mem_keep0001');
    expect(keep.status, MemoryStatus.active);
    expect(keep.strength, closeTo(0.7364, 0.001));
    expect(
      keep.lastDecayAt!.microsecondsSinceEpoch,
      now.microsecondsSinceEpoch,
    );

    final young = entries.firstWhere((entry) => entry.id == 'mem_young001');
    expect(young.status, MemoryStatus.active);
    expect(young.strength, closeTo(0.1664, 0.001));

    final visible = await chatRepository.queryVisibleMemories(
      assistantId: null,
    );
    expect(visible.map((entry) => entry.id), isNot(contains('mem_weak0001')));
  });

  test('legacy entries without lastDecayAt start a fresh baseline', () async {
    await putEntry(
      id: 'mem_legacy01',
      content: 'Legacy payload',
      createdAt: now.subtract(const Duration(days: 90)),
      strength: 0.1,
      noDecayBaseline: true,
    );

    final preview = await service().preview();
    expect(preview.baselineCount, 1);
    expect(preview.updatedCount, 1);
    expect(preview.archiveIds, isEmpty);

    final applied = await service(dryRun: false).apply();
    expect(applied.baselineCount, 1);
    expect(applied.updatedCount, 1);
    expect(applied.archivedCount, 0);

    final entry = (await memoryRepository.readAll()).firstWhere(
      (item) => item.id == 'mem_legacy01',
    );
    expect(entry.status, MemoryStatus.active);
    expect(entry.strength, 0.1);
    expect(
      entry.lastDecayAt!.microsecondsSinceEpoch,
      now.microsecondsSinceEpoch,
    );

    final next = await MemoryForgettingService(
      repository: memoryRepository,
      clock: () => now.add(const Duration(days: 1)),
    ).preview();
    expect(next.baselineCount, 0);
    expect(next.archiveIds, ['mem_legacy01']);
  });

  test('onlyIds limits decay and archiving', () async {
    await putEntry(
      id: 'mem_a0000001',
      content: 'Selected',
      createdAt: now.subtract(const Duration(days: 30)),
      strength: 0.1,
    );
    await putEntry(
      id: 'mem_b0000001',
      content: 'Untouched',
      createdAt: now.subtract(const Duration(days: 30)),
      strength: 0.1,
    );

    final report = await service(
      dryRun: false,
    ).apply(onlyIds: {'mem_a0000001'});
    expect(report.scanned, 1);
    expect(report.updatedCount, 1);
    expect(report.archivedCount, 1);

    final entries = await memoryRepository.readAll();
    final selected = entries.firstWhere((entry) => entry.id == 'mem_a0000001');
    expect(selected.status, MemoryStatus.archived);
    final untouched = entries.firstWhere((entry) => entry.id == 'mem_b0000001');
    expect(untouched.status, MemoryStatus.active);
    expect(untouched.strength, 0.1);
  });

  test('identity and instruction never decay or archive', () async {
    await putEntry(
      id: 'mem_identity',
      content: 'Identity',
      type: MemoryType.identity,
      createdAt: now.subtract(const Duration(days: 90)),
      strength: 0.1,
      noDecayBaseline: true,
    );
    await putEntry(
      id: 'mem_instruct',
      content: 'Instruction',
      type: MemoryType.instruction,
      createdAt: now.subtract(const Duration(days: 90)),
      strength: 0.1,
      noDecayBaseline: true,
    );
    await putEntry(
      id: 'mem_flow0001',
      content: 'Workflow',
      createdAt: now.subtract(const Duration(days: 90)),
      strength: 0.1,
    );

    final report = await service(dryRun: false).apply();

    expect(report.scanned, 3);
    expect(report.exemptCount, 2);
    expect(report.updatedCount, 1);
    expect(report.archiveIds, ['mem_flow0001']);

    final entries = await memoryRepository.readAll();
    for (final id in ['mem_identity', 'mem_instruct']) {
      final entry = entries.firstWhere((entry) => entry.id == id);
      expect(entry.status, MemoryStatus.active);
      expect(entry.strength, 0.1);
      expect(entry.lastDecayAt, isNull);
    }
    final workflow = entries.firstWhere((entry) => entry.id == 'mem_flow0001');
    expect(workflow.status, MemoryStatus.archived);
  });

  test('minAgeDays and strict threshold gate archiving', () async {
    await putEntry(
      id: 'mem_edge0001',
      content: 'Exactly seven days at threshold',
      createdAt: now.subtract(const Duration(days: 7)),
      strength: 0.3,
      lastDecayAt: now,
    );
    await putEntry(
      id: 'mem_young001',
      content: 'Young and empty',
      createdAt: now.subtract(const Duration(days: 6)),
      strength: 0.0,
    );
    await putEntry(
      id: 'mem_old0001',
      content: 'Old and below threshold',
      createdAt: now.subtract(const Duration(days: 7)),
      strength: 0.29,
      lastDecayAt: now,
    );

    final report = await service().preview();

    expect(report.archiveIds, ['mem_old0001']);
  });

  test('negative valence slows decay', () async {
    await putEntry(
      id: 'mem_neutral1',
      content: 'Neutral',
      createdAt: now.subtract(const Duration(days: 10)),
      strength: 0.5,
      valence: 0.0,
    );
    await putEntry(
      id: 'mem_neg00001',
      content: 'Negative',
      createdAt: now.subtract(const Duration(days: 10)),
      strength: 0.5,
      valence: -0.8,
    );

    await service(dryRun: false).apply();

    final entries = await memoryRepository.readAll();
    final neutral = entries.firstWhere((entry) => entry.id == 'mem_neutral1');
    final negative = entries.firstWhere((entry) => entry.id == 'mem_neg00001');
    expect(neutral.strength, closeTo(0.3682, 0.001));
    expect(negative.strength, closeTo(0.4019, 0.001));
    expect(negative.strength, greaterThan(neutral.strength));
  });

  test('restore clears archive reason and resets decay', () async {
    await putEntry(
      id: 'mem_restore1',
      content: 'Restore me',
      createdAt: now.subtract(const Duration(days: 30)),
      strength: 0.2,
      lastDecayAt: now.subtract(const Duration(days: 1)),
    );

    await memoryRepository.archive('mem_restore1', reason: 'forgetting:test');
    expect(await memoryRepository.restore('mem_restore1'), isTrue);

    final restored = (await memoryRepository.readAll()).firstWhere(
      (entry) => entry.id == 'mem_restore1',
    );
    expect(restored.status, MemoryStatus.active);
    expect(restored.archiveReason, isNull);
    expect(restored.strength, 1.0);
    expect(restored.lastDecayAt, isNull);
  });
}
