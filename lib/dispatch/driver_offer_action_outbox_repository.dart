import 'dart:convert';

import 'package:postgres/postgres.dart';

/// Actions persisted in `driver_offer_action_outbox.action`.
enum DriverOfferAction { accept, reject }

/// Represents the JSONB literal `null`, which differs from SQL NULL.
enum DriverOfferActionJsonbNull { value }

/// Worker states persisted in `driver_offer_action_outbox.redispatch_status`.
enum DriverOfferRedispatchStatus {
  queued,
  leased,
  retryable,
  completed,
  needsReview('needs_review'),
  notRequired('not_required');

  const DriverOfferRedispatchStatus([this.databaseValue]);

  final String? databaseValue;

  String get value => databaseValue ?? name;

  static DriverOfferRedispatchStatus fromDatabase(Object? value) {
    if (value is! String) {
      throw const FormatException('Invalid redispatch status in database.');
    }
    for (final status in values) {
      if (status.value == value) return status;
    }
    throw const FormatException('Unknown redispatch status in database.');
  }
}

/// A persisted row in `driver_offer_action_outbox`.
///
/// The field names and enum values mirror migration 016. In particular,
/// `requestHash` is an already-computed lower-case SHA-256 digest; canonical
/// request serialization and hashing remain the responsibility of the caller.
/// `redispatchResult` must contain sanitized outcome metadata only. It must
/// never contain an exception, external provider payload, address, credential,
/// or personal data.
class DriverOfferActionOutboxRecord {
  DriverOfferActionOutboxRecord({
    required this.actionId,
    required this.offerId,
    required this.driverId,
    required this.action,
    required this.idempotencyKey,
    required this.requestHash,
    required this.policyOutcome,
    required this.redispatchStatus,
    required this.attemptCount,
    required this.availableAt,
    required this.leaseToken,
    required this.leaseUntil,
    required this.lastErrorCode,
    required this.redispatchResult,
    required this.createdAt,
    required this.settledAt,
    required this.updatedAt,
    required this.redispatchCompletedAt,
  }) {
    _validate();
  }

  final String actionId;
  final String offerId;
  final String driverId;
  final DriverOfferAction action;
  final String? idempotencyKey;
  final String requestHash;
  final String? policyOutcome;
  final DriverOfferRedispatchStatus redispatchStatus;
  final int attemptCount;
  final DateTime availableAt;
  final String? leaseToken;
  final DateTime? leaseUntil;
  final String? lastErrorCode;
  final Object? redispatchResult;
  final DateTime createdAt;
  final DateTime settledAt;
  final DateTime updatedAt;
  final DateTime? redispatchCompletedAt;

  static const List<String> columnNames = [
    'action_id',
    'offer_id',
    'driver_id',
    'action',
    'idempotency_key',
    'request_hash',
    'policy_outcome',
    'redispatch_status',
    'attempt_count',
    'available_at',
    'lease_token',
    'lease_until',
    'last_error_code',
    'redispatch_result',
    'created_at',
    'settled_at',
    'updated_at',
    'redispatch_completed_at',
  ];

  /// Restores a row returned by PostgreSQL.
  ///
  /// postgres.dart decodes JSONB to Dart JSON values. SQL NULL remains Dart
  /// null; JSON scalar strings remain Dart strings.
  factory DriverOfferActionOutboxRecord.fromRow(Map<String, Object?> row) {
    return DriverOfferActionOutboxRecord(
      actionId: _string(row, 'action_id'),
      offerId: _string(row, 'offer_id'),
      driverId: _string(row, 'driver_id'),
      action: _actionFromDatabase(row['action']),
      idempotencyKey: _nullableString(row, 'idempotency_key'),
      requestHash: _string(row, 'request_hash'),
      policyOutcome: _nullableString(row, 'policy_outcome'),
      redispatchStatus: DriverOfferRedispatchStatus.fromDatabase(
        row['redispatch_status'],
      ),
      attemptCount: _integer(row, 'attempt_count'),
      availableAt: _dateTime(row, 'available_at'),
      leaseToken: _nullableString(row, 'lease_token'),
      leaseUntil: _nullableDateTime(row, 'lease_until'),
      lastErrorCode: _nullableString(row, 'last_error_code'),
      redispatchResult: _jsonValue(row['redispatch_result']),
      createdAt: _dateTime(row, 'created_at'),
      settledAt: _dateTime(row, 'settled_at'),
      updatedAt: _dateTime(row, 'updated_at'),
      redispatchCompletedAt: _nullableDateTime(row, 'redispatch_completed_at'),
    );
  }

  /// Restores a postgres.dart row while preserving the distinction between
  /// SQL NULL and the JSONB literal `null` in `redispatch_result`.
  factory DriverOfferActionOutboxRecord.fromResultRow(ResultRow row) {
    final values = row.toColumnMap();
    final jsonbIndex = row.schema.columns.indexWhere(
      (column) => column.columnName == 'redispatch_result',
    );
    if (jsonbIndex >= 0 &&
        !row.isSqlNull(jsonbIndex) &&
        row[jsonbIndex] == null) {
      values['redispatch_result'] = DriverOfferActionJsonbNull.value;
    }
    return DriverOfferActionOutboxRecord.fromRow(values);
  }

  /// Values for the insert statement. JSONB is encoded explicitly and cast in
  /// SQL so null and JSON values are not confused by PostgreSQL type inference.
  Map<String, Object?> toInsertParameters() {
    _validateDiagnosticCodeForInsert();
    return {
      'actionId': actionId,
      'offerId': offerId,
      'driverId': driverId,
      'action': action.name,
      'idempotencyKey': idempotencyKey,
      'requestHash': requestHash,
      'policyOutcome': policyOutcome,
      'redispatchStatus': redispatchStatus.value,
      'attemptCount': attemptCount,
      'availableAt': availableAt.toUtc(),
      'leaseToken': leaseToken,
      'leaseUntil': leaseUntil?.toUtc(),
      'lastErrorCode': lastErrorCode,
      'redispatchResult': switch (redispatchResult) {
        null => null,
        DriverOfferActionJsonbNull.value => 'null',
        final value => jsonEncode(value),
      },
      'createdAt': createdAt.toUtc(),
      'settledAt': settledAt.toUtc(),
      'updatedAt': updatedAt.toUtc(),
      'redispatchCompletedAt': redispatchCompletedAt?.toUtc(),
    };
  }

  bool hasSameRequestAs(DriverOfferActionOutboxRecord other) =>
      offerId == other.offerId &&
      driverId == other.driverId &&
      action == other.action &&
      idempotencyKey == other.idempotencyKey &&
      requestHash == other.requestHash;

  void _validate() {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(requestHash)) {
      throw const FormatException('requestHash must be a lowercase SHA-256.');
    }
    if (idempotencyKey != null &&
        !_isTrimmedLength(idempotencyKey!, minimum: 1, maximum: 200)) {
      throw const FormatException('Invalid idempotency key.');
    }
    if (action == DriverOfferAction.accept) {
      if (policyOutcome != null ||
          redispatchStatus != DriverOfferRedispatchStatus.notRequired) {
        throw const FormatException('Invalid accept action state.');
      }
    } else {
      if (policyOutcome == null ||
          !_isTrimmedLength(policyOutcome!, minimum: 1, maximum: 100) ||
          redispatchStatus == DriverOfferRedispatchStatus.notRequired) {
        throw const FormatException('Invalid reject action state.');
      }
    }
    if (attemptCount < 0) {
      throw const FormatException('attemptCount cannot be negative.');
    }
    if (redispatchStatus == DriverOfferRedispatchStatus.leased) {
      if (leaseToken == null ||
          !_isTrimmedLength(leaseToken!, minimum: 1, maximum: 200) ||
          leaseUntil == null) {
        throw const FormatException('Invalid leased action state.');
      }
    } else if (leaseToken != null || leaseUntil != null) {
      throw const FormatException('Non-leased action cannot have a lease.');
    }
    if (lastErrorCode != null &&
        !_isTrimmedLength(lastErrorCode!, minimum: 1, maximum: 100)) {
      throw const FormatException('Invalid last error code in database row.');
    }
    if ((redispatchStatus == DriverOfferRedispatchStatus.completed) !=
        (redispatchCompletedAt != null)) {
      throw const FormatException('Invalid redispatch completion timestamp.');
    }
    if (settledAt.toUtc().isBefore(createdAt.toUtc())) {
      throw const FormatException('settledAt cannot precede createdAt.');
    }
    _ensureJsonValue(redispatchResult);
  }

  void _validateDiagnosticCodeForInsert() {
    if (lastErrorCode != null &&
        !RegExp(r'^[a-z][a-z0-9_]{0,99}$').hasMatch(lastErrorCode!)) {
      // The migration permits trimmed text, but new writes use only a
      // machine-readable code and never a raw exception or sensitive value.
      throw const FormatException('lastErrorCode must be a sanitized code.');
    }
  }

  static void _ensureJsonValue(Object? value) {
    if (value == DriverOfferActionJsonbNull.value) return;
    try {
      jsonEncode(value);
    } on Object {
      throw const FormatException(
        'redispatchResult must be JSON serializable.',
      );
    }
  }

  static bool _isTrimmedLength(
    String value, {
    required int minimum,
    required int maximum,
  }) {
    final length = value.runes.length;
    return length >= minimum && length <= maximum && value == value.trim();
  }

  static String _string(Map<String, Object?> row, String key) {
    final value = row[key];
    if (value is String) return value;
    throw FormatException('Invalid $key value in database row.');
  }

  static String? _nullableString(Map<String, Object?> row, String key) {
    final value = row[key];
    if (value == null || value is String) return value as String?;
    throw FormatException('Invalid $key value in database row.');
  }

  static int _integer(Map<String, Object?> row, String key) {
    final value = row[key];
    if (value is int) return value;
    throw FormatException('Invalid $key value in database row.');
  }

  static DateTime _dateTime(Map<String, Object?> row, String key) {
    final value = row[key];
    if (value is DateTime) return value.toUtc();
    if (value is String) {
      try {
        return DateTime.parse(value).toUtc();
      } on FormatException {
        throw FormatException('Invalid $key value in database row.');
      }
    }
    throw FormatException('Invalid $key value in database row.');
  }

  static DateTime? _nullableDateTime(Map<String, Object?> row, String key) {
    if (row[key] == null) return null;
    return _dateTime(row, key);
  }

  static Object? _jsonValue(Object? value) {
    if (value == DriverOfferActionJsonbNull.value) return value;
    if (value == null ||
        value is String ||
        value is num ||
        value is bool ||
        value is Map ||
        value is List) {
      _ensureJsonValue(value);
      return value;
    }
    throw const FormatException('Invalid JSONB value in database row.');
  }

  static DriverOfferAction _actionFromDatabase(Object? value) {
    if (value is String) {
      for (final action in DriverOfferAction.values) {
        if (action.name == value) return action;
      }
    }
    throw const FormatException('Unknown action in database row.');
  }
}

/// Repository contract for transaction-aware access to action journal rows.
///
/// Callers supply the session for every operation. In particular, [insert]
/// accepts the caller's PostgreSQL transaction session and never opens or
/// commits a transaction itself.
abstract interface class DriverOfferActionOutboxRepository {
  /// The transaction-aware caller MUST validate that [record]'s driver owns
  /// the referenced `ride_offers` row before calling [insert]. This repository
  /// only journals actions; it is not an offer-ownership boundary.
  Future<DriverOfferActionInsertResult> insert({
    required TxSession transaction,
    required DriverOfferActionOutboxRecord record,
  });

  /// Returns null for both an unknown offer and an offer owned by another
  /// driver. Implementations must apply both IDs in the database predicate.
  Future<DriverOfferActionOutboxRecord?> findForDriver({
    required Session session,
    required String offerId,
    required String driverId,
  });

  Future<DriverOfferActionOutboxRecord?> findByDriverAndIdempotencyKey({
    required Session session,
    required String driverId,
    required String idempotencyKey,
  });
}

sealed class DriverOfferActionInsertResult {
  const DriverOfferActionInsertResult();
}

final class DriverOfferActionInserted extends DriverOfferActionInsertResult {
  const DriverOfferActionInserted(this.record);

  final DriverOfferActionOutboxRecord record;
}

/// The exact same request was already recorded. Implementations must compare
/// driverId, offerId, action, requestHash, and idempotencyKey (including NULL)
/// before returning this result.
final class DriverOfferActionAlreadyExists
    extends DriverOfferActionInsertResult {
  const DriverOfferActionAlreadyExists({required this.record});

  final DriverOfferActionOutboxRecord record;
}

/// The offer already has a different action, or is associated with another
/// driver's action. This result deliberately exposes no stored row or owner.
final class DriverOfferActionOfferConflict
    extends DriverOfferActionInsertResult {
  const DriverOfferActionOfferConflict();
}

final class DriverOfferActionIdempotencyConflict
    extends DriverOfferActionInsertResult {
  const DriverOfferActionIdempotencyConflict();
}

/// A uniqueness conflict could not be classified in the caller's transaction
/// snapshot. The caller must restart/re-read; this is never reported as success.
final class DriverOfferActionConflictUnresolved
    extends DriverOfferActionInsertResult {
  const DriverOfferActionConflictUnresolved();
}

class DriverOfferActionIdConflictException implements Exception {
  const DriverOfferActionIdConflictException();

  @override
  String toString() => 'Driver offer action ID conflict.';
}

class DriverOfferActionDuplicateReadException implements Exception {
  const DriverOfferActionDuplicateReadException();

  @override
  String toString() => 'Driver offer action lookup returned duplicate rows.';
}
