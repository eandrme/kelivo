import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/memory_entry.dart';
import 'package:Kelivo/core/models/user_profile_field.dart';

void main() {
  group('MemoryEntry.normalizeContent', () {
    test('trims, collapses whitespace, and lowercases', () {
      expect(MemoryEntry.normalizeContent('  Hello\n\tWORLD  '), 'hello world');
      expect(MemoryEntry.normalizeContent('A   B\r\nC'), 'a b c');
      expect(MemoryEntry.normalizeContent(' already '), 'already');
    });
  });

  group('MemoryEntry payload', () {
    test('toPayload omits contentNormalized and uses microsecond epochs', () {
      final created = DateTime.utc(2026, 8, 6, 12, 1, 20, 0, 106);
      final updated = DateTime.utc(2026, 8, 7, 12, 1, 20, 0, 106);
      final entry = MemoryEntry(
        id: 'mem_a1b2c3d4',
        scope: MemoryScope.global,
        type: MemoryType.workflow,
        content: '用户开发 Flutter 应用时重视跨平台与长列表性能。',
        source: MemorySource.extracted,
        relatedIds: const ['mem_e5f6g7h8'],
        migrationIds: const ['legacy_memory_v1:receipt'],
        createdAt: created,
        updatedAt: updated,
      );
      final payload = entry.toPayload();
      expect(payload.containsKey('contentNormalized'), isFalse);
      expect(payload['createdAt'], created.microsecondsSinceEpoch);
      expect(payload['updatedAt'], updated.microsecondsSinceEpoch);
      expect(payload['scope'], 'global');
      expect(payload['type'], 'workflow');
      expect(payload['status'], 'active');
      expect(payload['source'], 'extracted');
      expect(payload['valence'], 0.0);
      expect(payload['arousal'], 0.3);
      expect(payload['strength'], 1.0);
      expect(payload, contains('lastDecayAt'));
      expect(payload['lastDecayAt'], isNull);
      expect(payload, contains('archiveReason'));
      expect(payload['archiveReason'], isNull);

      final roundTrip = MemoryEntry.fromPayload(payload);
      expect(roundTrip.id, entry.id);
      expect(roundTrip.scope, entry.scope);
      expect(roundTrip.type, entry.type);
      expect(roundTrip.content, entry.content);
      expect(roundTrip.relatedIds, entry.relatedIds);
      expect(roundTrip.migrationIds, entry.migrationIds);
      expect(roundTrip.valence, 0.0);
      expect(roundTrip.arousal, 0.3);
      expect(roundTrip.strength, 1.0);
      expect(roundTrip.lastDecayAt, isNull);
      expect(roundTrip.archiveReason, isNull);
      expect(
        roundTrip.createdAt.microsecondsSinceEpoch,
        entry.createdAt.microsecondsSinceEpoch,
      );
      expect(
        roundTrip.updatedAt.microsecondsSinceEpoch,
        entry.updatedAt.microsecondsSinceEpoch,
      );
    });

    test('newId uses mem_ + 8 hex chars', () {
      final id = MemoryEntry.newId();
      expect(id, matches(RegExp(r'^mem_[0-9a-f]{8}$')));
    });
  });

  group('MemoryEntry affect payload', () {
    MemoryEntry build({
      double valence = 0.0,
      double arousal = 0.3,
      double strength = 1.0,
      DateTime? lastDecayAt,
      String? archiveReason,
    }) => MemoryEntry(
      id: 'mem_a1b2c3d4',
      scope: MemoryScope.global,
      type: MemoryType.workflow,
      content: '情绪色彩测试',
      source: MemorySource.extracted,
      valence: valence,
      arousal: arousal,
      strength: strength,
      lastDecayAt: lastDecayAt,
      archiveReason: archiveReason,
      createdAt: DateTime.utc(2026, 8, 6),
      updatedAt: DateTime.utc(2026, 8, 7),
    );

    test('legacy payload without affect fields uses neutral defaults', () {
      final payload = <String, dynamic>{
        'id': 'mem_a1b2c3d4',
        'scope': 'global',
        'type': 'workflow',
        'status': 'active',
        'content': '旧数据',
        'source': 'manual',
        'createdAt': DateTime.utc(2026, 1, 1).microsecondsSinceEpoch,
        'updatedAt': DateTime.utc(2026, 1, 2).microsecondsSinceEpoch,
      };

      final entry = MemoryEntry.fromPayload(payload);

      expect(entry.valence, 0.0);
      expect(entry.arousal, 0.3);
      expect(entry.strength, 1.0);
      expect(entry.lastDecayAt, isNull);
      expect(entry.archiveReason, isNull);
    });

    test('affect fields survive a JSON backup round trip', () {
      final lastDecayAt = DateTime.utc(2026, 8, 20, 9, 30);
      final entry = build(
        valence: -0.6,
        arousal: 0.8,
        strength: 0.42,
        lastDecayAt: lastDecayAt,
        archiveReason: 'forgetting:strength<0.3',
      );

      final decoded =
          jsonDecode(jsonEncode(entry.toPayload())) as Map<String, dynamic>;
      final restored = MemoryEntry.fromPayload(decoded);

      expect(restored.valence, -0.6);
      expect(restored.arousal, 0.8);
      expect(restored.strength, 0.42);
      expect(
        restored.lastDecayAt!.microsecondsSinceEpoch,
        lastDecayAt.microsecondsSinceEpoch,
      );
      expect(restored.archiveReason, 'forgetting:strength<0.3');
    });

    test(
      'out-of-range values are clamped on construction and payload read',
      () {
        final entry = build(valence: -4.0, arousal: 9.0, strength: -2.0);
        expect(entry.valence, -1.0);
        expect(entry.arousal, 1.0);
        expect(entry.strength, 0.0);

        final copied = build().copyWith(
          valence: 2.0,
          arousal: -1.0,
          strength: 5.0,
        );
        expect(copied.valence, 1.0);
        expect(copied.arousal, 0.0);
        expect(copied.strength, 1.0);

        final payload = <String, dynamic>{
          ...build().toPayload(),
          'valence': 3.5,
          'arousal': -1.0,
          'strength': 2.0,
        };
        final restored = MemoryEntry.fromPayload(payload);
        expect(restored.valence, 1.0);
        expect(restored.arousal, 0.0);
        expect(restored.strength, 1.0);
      },
    );

    test('missing or invalid values fall back to neutral defaults', () {
      final payload = <String, dynamic>{
        ...build().toPayload(),
        'valence': double.nan,
        'arousal': 'calm',
        'strength': double.infinity,
        'lastDecayAt': 'not-a-number',
        'archiveReason': 42,
      };

      final entry = MemoryEntry.fromPayload(payload);

      expect(entry.valence, 0.0);
      expect(entry.arousal, 0.3);
      expect(entry.strength, 1.0);
      expect(entry.lastDecayAt, isNull);
      expect(entry.archiveReason, isNull);
    });

    test('copyWith preserves affect fields and can clear optional ones', () {
      final lastDecayAt = DateTime.utc(2026, 9, 1);
      final entry = build(
        valence: 0.5,
        arousal: 0.6,
        strength: 0.7,
        lastDecayAt: lastDecayAt,
        archiveReason: 'manual',
      );

      final updated = entry.copyWith(content: '更新后的内容');
      expect(updated.content, '更新后的内容');
      expect(updated.valence, 0.5);
      expect(updated.arousal, 0.6);
      expect(updated.strength, 0.7);
      expect(updated.lastDecayAt, lastDecayAt);
      expect(updated.archiveReason, 'manual');

      final cleared = updated.copyWith(
        clearLastDecayAt: true,
        clearArchiveReason: true,
      );
      expect(cleared.lastDecayAt, isNull);
      expect(cleared.archiveReason, isNull);
      expect(cleared.valence, 0.5);
      expect(cleared.arousal, 0.6);
      expect(cleared.strength, 0.7);
    });
  });

  group('UserProfileField', () {
    test('isValidKey accepts known and custom keys', () {
      expect(UserProfileField.isValidKey('preferred_name'), isTrue);
      expect(UserProfileField.isValidKey('custom.company'), isTrue);
      expect(UserProfileField.isValidKey('custom.a-b_1'), isTrue);
      expect(UserProfileField.isValidKey('nickname'), isFalse);
      expect(UserProfileField.isValidKey('custom.'), isFalse);
    });

    test('payload uses id for key', () {
      final field = UserProfileField(
        key: 'preferred_name',
        value: 'Psyche',
        source: MemorySource.tool,
        updatedAt: DateTime.fromMicrosecondsSinceEpoch(1786012880106000),
      );
      final payload = field.toPayload();
      expect(payload['id'], 'preferred_name');
      expect(payload['value'], 'Psyche');
      expect(payload['source'], 'tool');
      expect(UserProfileField.fromPayload(payload).key, 'preferred_name');
    });
  });
}
