import 'dart:math';

enum MemoryScope { global, assistant }

enum MemoryType { identity, workflow, voice, instruction }

enum MemoryStatus { active, archived }

enum MemorySource { manual, tool, extracted, distilled }

class MemoryEntry {
  final String id;
  final MemoryScope scope;
  final String? assistantId;
  final MemoryType type;
  final MemoryStatus status;
  final String content;
  final MemorySource source;
  final List<String> relatedIds;
  final List<String> migrationIds;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Emotional valence of the remembered event, from -1 (negative) to 1.
  final double valence;

  /// Emotional arousal of the remembered event, from 0 (calm) to 1 (intense).
  final double arousal;

  /// How important this memory is to keep, from 0 to 1. Higher slows decay.
  final double importance;

  /// Decayed retention strength, from 0 to 1.
  final double strength;

  /// Last time [strength] was decayed. Null means decay from [createdAt].
  final DateTime? lastDecayAt;

  /// Why this entry was archived, e.g. automatic forgetting.
  final String? archiveReason;

  /// Pinned entries are exempt from automatic decay and archiving.
  final bool pinned;

  /// Number of explicit recalls/reinforcements.
  final int recallCount;

  /// Last time this entry was explicitly recalled.
  final DateTime? lastRecalledAt;

  MemoryEntry({
    required this.id,
    required this.scope,
    this.assistantId,
    required this.type,
    this.status = MemoryStatus.active,
    required this.content,
    this.source = MemorySource.manual,
    this.relatedIds = const <String>[],
    this.migrationIds = const <String>[],
    required this.createdAt,
    required this.updatedAt,
    double valence = 0.0,
    double arousal = 0.3,
    double importance = 0.0,
    double strength = 1.0,
    this.lastDecayAt,
    this.archiveReason,
    this.pinned = false,
    int recallCount = 0,
    this.lastRecalledAt,
  }) : valence = _clampDouble(valence, -1.0, 1.0, 0.0),
       arousal = _clampDouble(arousal, 0.0, 1.0, 0.3),
       importance = _clampDouble(importance, 0.0, 1.0, 0.0),
       strength = _clampDouble(strength, 0.0, 1.0, 1.0),
       recallCount = recallCount < 0 ? 0 : recallCount;

  MemoryEntry copyWith({
    String? id,
    MemoryScope? scope,
    String? assistantId,
    MemoryType? type,
    MemoryStatus? status,
    String? content,
    MemorySource? source,
    List<String>? relatedIds,
    List<String>? migrationIds,
    DateTime? createdAt,
    DateTime? updatedAt,
    double? valence,
    double? arousal,
    double? importance,
    double? strength,
    DateTime? lastDecayAt,
    String? archiveReason,
    bool? pinned,
    int? recallCount,
    DateTime? lastRecalledAt,
    bool clearAssistantId = false,
    bool clearLastDecayAt = false,
    bool clearArchiveReason = false,
  }) => MemoryEntry(
    id: id ?? this.id,
    scope: scope ?? this.scope,
    assistantId: clearAssistantId ? null : (assistantId ?? this.assistantId),
    type: type ?? this.type,
    status: status ?? this.status,
    content: content ?? this.content,
    source: source ?? this.source,
    relatedIds: relatedIds ?? this.relatedIds,
    migrationIds: migrationIds ?? this.migrationIds,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    valence: valence ?? this.valence,
    arousal: arousal ?? this.arousal,
    importance: importance ?? this.importance,
    strength: strength ?? this.strength,
    lastDecayAt: clearLastDecayAt ? null : (lastDecayAt ?? this.lastDecayAt),
    archiveReason: clearArchiveReason
        ? null
        : (archiveReason ?? this.archiveReason),
    pinned: pinned ?? this.pinned,
    recallCount: recallCount ?? this.recallCount,
    lastRecalledAt: lastRecalledAt ?? this.lastRecalledAt,
  );

  Map<String, dynamic> toPayload() => {
    'id': id,
    'scope': scopeToString(scope),
    'assistantId': assistantId,
    'type': typeToString(type),
    'status': statusToString(status),
    'content': content,
    'source': sourceToString(source),
    'relatedIds': relatedIds,
    if (migrationIds.isNotEmpty) 'migrationIds': migrationIds,
    'createdAt': createdAt.microsecondsSinceEpoch,
    'updatedAt': updatedAt.microsecondsSinceEpoch,
    'valence': valence,
    'arousal': arousal,
    'importance': importance,
    'strength': strength,
    'lastDecayAt': lastDecayAt?.microsecondsSinceEpoch,
    'archiveReason': archiveReason,
    'pinned': pinned,
    'recallCount': recallCount,
    'lastRecalledAt': lastRecalledAt?.microsecondsSinceEpoch,
  };

  static MemoryEntry fromPayload(Map<String, dynamic> json) {
    final scope = scopeFromString(json['scope'] as String);
    return MemoryEntry(
      id: json['id'] as String,
      scope: scope,
      assistantId: json['assistantId'] as String?,
      type: typeFromString(json['type'] as String),
      status: statusFromString((json['status'] as String?) ?? 'active'),
      content: json['content'] as String,
      source: sourceFromString((json['source'] as String?) ?? 'manual'),
      relatedIds:
          (json['relatedIds'] as List?)?.cast<String>() ?? const <String>[],
      migrationIds:
          (json['migrationIds'] as List?)?.cast<String>() ?? const <String>[],
      createdAt: DateTime.fromMicrosecondsSinceEpoch(
        (json['createdAt'] as num).toInt(),
      ),
      updatedAt: DateTime.fromMicrosecondsSinceEpoch(
        (json['updatedAt'] as num).toInt(),
      ),
      valence: _readDouble(json['valence'], 0.0),
      arousal: _readDouble(json['arousal'], 0.3),
      importance: _readDouble(json['importance'], 0.0),
      strength: _readDouble(json['strength'], 1.0),
      lastDecayAt: _readDateTime(json['lastDecayAt']),
      archiveReason: json['archiveReason'] is String
          ? json['archiveReason'] as String
          : null,
      pinned: json['pinned'] == true || json['pinned'] == 1,
      recallCount: _readInt(json['recallCount'], 0),
      lastRecalledAt: _readDateTime(json['lastRecalledAt']),
    );
  }

  static double _clampDouble(
    double value,
    double min,
    double max,
    double fallback,
  ) {
    if (!value.isFinite) return fallback;
    return value.clamp(min, max).toDouble();
  }

  static double _readDouble(Object? value, double fallback) {
    if (value is num && value.isFinite) return value.toDouble();
    return fallback;
  }

  static int _readInt(Object? value, int fallback) {
    if (value is num) return value.toInt();
    return fallback;
  }

  static DateTime? _readDateTime(Object? value) {
    if (value is num) {
      return DateTime.fromMicrosecondsSinceEpoch(value.toInt());
    }
    return null;
  }

  /// Trim, collapse every whitespace run to a single space, then lowercase.
  static String normalizeContent(String content) {
    return content.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }

  /// Alphabet: `0123456789abcdef` (8 hex chars after `mem_`).
  static String newId([Random? random]) {
    final rng = random ?? Random.secure();
    const alphabet = '0123456789abcdef';
    final buf = StringBuffer('mem_');
    for (var i = 0; i < 8; i++) {
      buf.write(alphabet[rng.nextInt(alphabet.length)]);
    }
    return buf.toString();
  }

  static String scopeToString(MemoryScope scope) {
    switch (scope) {
      case MemoryScope.global:
        return 'global';
      case MemoryScope.assistant:
        return 'assistant';
    }
  }

  static MemoryScope scopeFromString(String value) {
    switch (value) {
      case 'global':
        return MemoryScope.global;
      case 'assistant':
        return MemoryScope.assistant;
      default:
        throw FormatException('Unknown MemoryScope: $value');
    }
  }

  static String typeToString(MemoryType type) {
    switch (type) {
      case MemoryType.identity:
        return 'identity';
      case MemoryType.workflow:
        return 'workflow';
      case MemoryType.voice:
        return 'voice';
      case MemoryType.instruction:
        return 'instruction';
    }
  }

  static MemoryType typeFromString(String value) {
    switch (value) {
      case 'identity':
        return MemoryType.identity;
      case 'workflow':
        return MemoryType.workflow;
      case 'voice':
        return MemoryType.voice;
      case 'instruction':
        return MemoryType.instruction;
      default:
        throw FormatException('Unknown MemoryType: $value');
    }
  }

  static String statusToString(MemoryStatus status) {
    switch (status) {
      case MemoryStatus.active:
        return 'active';
      case MemoryStatus.archived:
        return 'archived';
    }
  }

  static MemoryStatus statusFromString(String value) {
    switch (value) {
      case 'active':
        return MemoryStatus.active;
      case 'archived':
        return MemoryStatus.archived;
      default:
        throw FormatException('Unknown MemoryStatus: $value');
    }
  }

  static String sourceToString(MemorySource source) {
    switch (source) {
      case MemorySource.manual:
        return 'manual';
      case MemorySource.tool:
        return 'tool';
      case MemorySource.extracted:
        return 'extracted';
      case MemorySource.distilled:
        return 'distilled';
    }
  }

  static MemorySource sourceFromString(String value) {
    switch (value) {
      case 'manual':
        return MemorySource.manual;
      case 'tool':
        return MemorySource.tool;
      case 'extracted':
        return MemorySource.extracted;
      case 'distilled':
        return MemorySource.distilled;
      default:
        throw FormatException('Unknown MemorySource: $value');
    }
  }
}
