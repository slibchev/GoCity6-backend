import 'package:postgres/postgres.dart';

import 'driver_offer_action_outbox_repository.dart';

/// PostgreSQL implementation for migration 016's action journal table.
///
/// This class deliberately depends on [Session], not [SessionExecutor]. Its
/// insert method receives the caller's transaction session and never opens,
/// commits, or rolls back a transaction.
class PostgresDriverOfferActionOutboxRepository
    implements DriverOfferActionOutboxRepository {
  static final String _columns = DriverOfferActionOutboxRecord.columnNames.join(
    ', ',
  );

  static final String _insertSql =
      '''
    INSERT INTO driver_offer_action_outbox (
      action_id,
      offer_id,
      driver_id,
      action,
      idempotency_key,
      request_hash,
      policy_outcome,
      redispatch_status,
      attempt_count,
      available_at,
      lease_token,
      lease_until,
      last_error_code,
      redispatch_result,
      created_at,
      settled_at,
      updated_at,
      redispatch_completed_at
    ) VALUES (
      @actionId,
      @offerId,
      @driverId,
      @action,
      @idempotencyKey,
      @requestHash,
      @policyOutcome,
      @redispatchStatus,
      @attemptCount,
      @availableAt,
      @leaseToken,
      @leaseUntil,
      @lastErrorCode,
      CAST(@redispatchResult AS JSONB),
      @createdAt,
      @settledAt,
      @updatedAt,
      @redispatchCompletedAt
    )
    ON CONFLICT DO NOTHING
    RETURNING $_columns
  ''';

  @override
  Future<DriverOfferActionInsertResult> insert({
    required TxSession transaction,
    required DriverOfferActionOutboxRecord record,
  }) async {
    final inserted = await transaction.execute(
      Sql.named(_insertSql),
      parameters: record.toInsertParameters(),
    );

    if (inserted.isNotEmpty) {
      return DriverOfferActionInserted(_singleRecord(inserted));
    }

    // Resolve a repeated idempotency key before offer uniqueness. A matching
    // key with a different request is always a conflict, never a success.
    final key = record.idempotencyKey;
    if (key != null) {
      final existingByKey = await findByDriverAndIdempotencyKey(
        session: transaction,
        driverId: record.driverId,
        idempotencyKey: key,
      );
      if (existingByKey != null) {
        if (existingByKey.hasSameRequestAs(record)) {
          return DriverOfferActionAlreadyExists(record: existingByKey);
        }
        return const DriverOfferActionIdempotencyConflict();
      }
    }

    // An action_id collision is distinct from an offer conflict. Read the
    // existing request identity so a true retry using the same action_id can
    // still be classified as AlreadyExists, while a different request cannot.
    final actionIdRows = await transaction.execute(
      Sql.named('''
        SELECT $_columns
        FROM driver_offer_action_outbox
        WHERE action_id = @actionId
        LIMIT 2
      '''),
      parameters: {'actionId': record.actionId},
    );
    final existingByActionId = _optionalSingleRecord(actionIdRows);
    if (existingByActionId != null) {
      if (existingByActionId.hasSameRequestAs(record)) {
        return DriverOfferActionAlreadyExists(record: existingByActionId);
      }
      throw const DriverOfferActionIdConflictException();
    }

    final existingForOwner = await findForDriver(
      session: transaction,
      offerId: record.offerId,
      driverId: record.driverId,
    );
    if (existingForOwner != null) {
      if (existingForOwner.hasSameRequestAs(record)) {
        return DriverOfferActionAlreadyExists(record: existingForOwner);
      }
      return const DriverOfferActionOfferConflict();
    }

    // Do not reveal a foreign driver's row. The boolean probe only classifies
    // the unique offer_id conflict and returns no journal or owner fields.
    final offerExists = await transaction.execute(
      Sql.named('''
        SELECT TRUE AS action_exists
        FROM driver_offer_action_outbox
        WHERE offer_id = @offerId
        LIMIT 1
      '''),
      parameters: {'offerId': record.offerId},
    );
    if (offerExists.isNotEmpty) {
      return const DriverOfferActionOfferConflict();
    }

    // For example, a concurrent write may be invisible to a repeatable-read
    // transaction snapshot. Do not misreport this as insertion or success.
    return const DriverOfferActionConflictUnresolved();
  }

  @override
  Future<DriverOfferActionOutboxRecord?> findForDriver({
    required Session session,
    required String offerId,
    required String driverId,
  }) async {
    final rows = await session.execute(
      Sql.named('''
        SELECT $_columns
        FROM driver_offer_action_outbox
        WHERE offer_id = @offerId
          AND driver_id = @driverId
        LIMIT 2
      '''),
      parameters: {'offerId': offerId, 'driverId': driverId},
    );
    return _optionalSingleRecord(rows);
  }

  @override
  Future<DriverOfferActionOutboxRecord?> findByDriverAndIdempotencyKey({
    required Session session,
    required String driverId,
    required String idempotencyKey,
  }) async {
    final rows = await session.execute(
      Sql.named('''
        SELECT $_columns
        FROM driver_offer_action_outbox
        WHERE driver_id = @driverId
          AND idempotency_key = @idempotencyKey
        LIMIT 2
      '''),
      parameters: {'driverId': driverId, 'idempotencyKey': idempotencyKey},
    );
    return _optionalSingleRecord(rows);
  }

  static DriverOfferActionOutboxRecord _singleRecord(Result rows) {
    if (rows.length != 1) {
      throw const DriverOfferActionDuplicateReadException();
    }
    return DriverOfferActionOutboxRecord.fromResultRow(rows.single);
  }

  static DriverOfferActionOutboxRecord? _optionalSingleRecord(Result rows) {
    if (rows.isEmpty) return null;
    return _singleRecord(rows);
  }
}
