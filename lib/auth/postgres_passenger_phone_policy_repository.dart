import 'package:postgres/postgres.dart';

import 'passenger_phone_identity.dart';
import 'passenger_phone_restriction_service.dart';

class PostgresPassengerPhonePolicyRepository
    implements
        PassengerPhoneRestrictionRepository,
        PassengerPhoneIdentityRepository {
  const PostgresPassengerPhonePolicyRepository({required this.database});

  final SessionExecutor database;

  @override
  Future<bool> hasActiveRestriction(String phoneE164) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT EXISTS (
            SELECT 1
            FROM passenger_phone_restrictions
            WHERE phone_e164 = @phoneE164
              AND lifted_at IS NULL
              AND (expires_at IS NULL OR expires_at > clock_timestamp())
          )
        '''),
        parameters: {'phoneE164': phoneE164},
      );
      return result.single[0] as bool;
    });
  }

  @override
  Future<PassengerPhoneRestrictionRecord> imposeRestriction({
    required String restrictionId,
    required String phoneE164,
    required String adminActor,
    required String reason,
    required int? durationSeconds,
  }) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          WITH phone_guard AS MATERIALIZED (
            SELECT pg_advisory_xact_lock(hashtextextended(@phoneE164, 0))
          ),
          database_time AS MATERIALIZED (
            SELECT clock_timestamp() AS now
            FROM phone_guard
          ),
          inserted AS (
            INSERT INTO passenger_phone_restrictions (
              restriction_id,
              phone_e164,
              imposed_at,
              expires_at,
              reason,
              admin_actor
            )
            SELECT
              @restrictionId::uuid,
              @phoneE164,
              database_time.now,
              CASE
                WHEN @durationSeconds::bigint IS NULL THEN NULL
                ELSE database_time.now
                  + (@durationSeconds::double precision * INTERVAL '1 second')
              END,
              @reason,
              @adminActor
            FROM database_time
            RETURNING
              restriction_id,
              phone_e164,
              imposed_at,
              expires_at,
              reason,
              admin_actor,
              lifted_at,
              lifted_by,
              lift_reason
          ),
          audit AS (
            INSERT INTO passenger_phone_restriction_audit (
              restriction_id,
              phone_e164,
              action,
              admin_actor,
              reason,
              occurred_at
            )
            SELECT
              restriction_id,
              phone_e164,
              'imposed',
              admin_actor,
              reason,
              imposed_at
            FROM inserted
            RETURNING restriction_id
          )
          SELECT
            inserted.restriction_id::text,
            inserted.phone_e164,
            inserted.imposed_at,
            inserted.expires_at,
            inserted.reason,
            inserted.admin_actor,
            inserted.lifted_at,
            inserted.lifted_by,
            inserted.lift_reason
          FROM inserted
          JOIN audit USING (restriction_id)
        '''),
        parameters: {
          'restrictionId': restrictionId,
          'phoneE164': phoneE164,
          'durationSeconds': durationSeconds,
          'reason': reason,
          'adminActor': adminActor,
        },
      );
      return _restrictionRecord(result.single.toColumnMap());
    });
  }

  @override
  Future<int> liftRestrictions({
    required String phoneE164,
    required String adminActor,
    required String reason,
  }) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          WITH phone_guard AS MATERIALIZED (
            SELECT pg_advisory_xact_lock(hashtextextended(@phoneE164, 0))
          ),
          database_time AS MATERIALIZED (
            SELECT clock_timestamp() AS now
            FROM phone_guard
          ),
          lifted AS (
            UPDATE passenger_phone_restrictions AS restriction
            SET
              lifted_at = database_time.now,
              lifted_by = @adminActor,
              lift_reason = @reason
            FROM database_time
            WHERE restriction.phone_e164 = @phoneE164
              AND restriction.lifted_at IS NULL
              AND (
                restriction.expires_at IS NULL
                OR restriction.expires_at > database_time.now
              )
            RETURNING
              restriction.restriction_id,
              restriction.phone_e164,
              restriction.lifted_at
          ),
          audit AS (
            INSERT INTO passenger_phone_restriction_audit (
              restriction_id,
              phone_e164,
              action,
              admin_actor,
              reason,
              occurred_at
            )
            SELECT
              lifted.restriction_id,
              lifted.phone_e164,
              'lifted',
              @adminActor,
              @reason,
              lifted.lifted_at
            FROM lifted
            UNION ALL
            SELECT
              NULL,
              @phoneE164,
              'lift_no_active',
              @adminActor,
              @reason,
              database_time.now
            FROM database_time
            WHERE NOT EXISTS (SELECT 1 FROM lifted)
            RETURNING audit_id
          )
          SELECT
            (SELECT count(*)::integer FROM lifted) AS lifted_count,
            (SELECT count(*) FROM audit) AS audit_count
        '''),
        parameters: {
          'phoneE164': phoneE164,
          'adminActor': adminActor,
          'reason': reason,
        },
      );
      return result.single.toColumnMap()['lifted_count'] as int;
    });
  }

  @override
  Future<List<PassengerPhoneRestrictionRecord>> findRestrictions({
    required String phoneE164,
  }) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT
            restriction_id::text,
            phone_e164,
            imposed_at,
            expires_at,
            reason,
            admin_actor,
            lifted_at,
            lifted_by,
            lift_reason
          FROM passenger_phone_restrictions
          WHERE phone_e164 = @phoneE164
          ORDER BY imposed_at DESC, restriction_id
        '''),
        parameters: {'phoneE164': phoneE164},
      );
      return result
          .map((row) => _restrictionRecord(row.toColumnMap()))
          .toList(growable: false);
    });
  }

  @override
  Future<List<PassengerPhoneRestrictionAuditRecord>> findAuditHistory({
    required String phoneE164,
  }) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT
            audit_id,
            restriction_id::text,
            phone_e164,
            action,
            admin_actor,
            reason,
            occurred_at
          FROM passenger_phone_restriction_audit
          WHERE phone_e164 = @phoneE164
          ORDER BY occurred_at, audit_id
        '''),
        parameters: {'phoneE164': phoneE164},
      );
      return result
          .map((row) => _restrictionAuditRecord(row.toColumnMap()))
          .toList(growable: false);
    });
  }

  @override
  Future<PassengerPhoneAssignmentResult> assignUnverifiedPhone({
    required String passengerId,
    required String phoneE164,
    required String adminActor,
    required String reason,
  }) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          WITH phone_guard AS MATERIALIZED (
            SELECT pg_advisory_xact_lock(hashtextextended(@phoneE164, 0))
          ),
          database_time AS MATERIALIZED (
            SELECT clock_timestamp() AS now
            FROM phone_guard
          ),
          allowed AS MATERIALIZED (
            SELECT
              database_time.now,
              NOT EXISTS (
                SELECT 1
                FROM passenger_phone_restrictions
                WHERE phone_e164 = @phoneE164
                  AND lifted_at IS NULL
                  AND (expires_at IS NULL OR expires_at > database_time.now)
              ) AS phone_allowed
            FROM database_time
          ),
          target AS MATERIALIZED (
            SELECT id, phone_e164
            FROM passengers
            WHERE id = @passengerId
            FOR UPDATE
          ),
          updated AS (
            UPDATE passengers AS passenger
            SET
              phone_e164 = @phoneE164,
              phone_verified_at = NULL,
              updated_at = allowed.now
            FROM target, allowed
            WHERE passenger.id = target.id
              AND allowed.phone_allowed
              AND passenger.phone_e164 IS DISTINCT FROM @phoneE164
            RETURNING passenger.id
          ),
          audit AS (
            INSERT INTO passenger_phone_identity_audit (
              passenger_id,
              phone_e164,
              action,
              admin_actor,
              reason
            )
            SELECT
              updated.id,
              @phoneE164,
              CASE WHEN target.phone_e164 IS NULL THEN 'assigned' ELSE 'changed' END,
              @adminActor,
              @reason
            FROM updated
            JOIN target ON target.id = updated.id
            RETURNING audit_id
          )
          SELECT CASE
            WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'passengerNotFound'
            WHEN NOT (SELECT phone_allowed FROM allowed) THEN 'restricted'
            WHEN EXISTS (SELECT 1 FROM updated) THEN
              CASE
                WHEN (SELECT phone_e164 FROM target) IS NULL THEN 'assigned'
                ELSE 'changed'
              END
            ELSE 'unchanged'
          END AS result,
          (SELECT count(*) FROM audit) AS audit_count
          FROM allowed
        '''),
        parameters: {
          'passengerId': passengerId,
          'phoneE164': phoneE164,
          'adminActor': adminActor,
          'reason': reason,
        },
      );
      return switch (result.single.toColumnMap()['result'] as String) {
        'assigned' => PassengerPhoneAssignmentResult.assigned,
        'changed' => PassengerPhoneAssignmentResult.changed,
        'restricted' => PassengerPhoneAssignmentResult.restricted,
        'passengerNotFound' => PassengerPhoneAssignmentResult.passengerNotFound,
        _ => PassengerPhoneAssignmentResult.unchanged,
      };
    });
  }

  @override
  Future<PassengerPhoneAssignmentResult> clearPhone({
    required String passengerId,
    required String adminActor,
    required String reason,
  }) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          WITH target AS MATERIALIZED (
            SELECT id, phone_e164
            FROM passengers
            WHERE id = @passengerId
            FOR UPDATE
          ),
          phone_guard AS MATERIALIZED (
            SELECT pg_advisory_xact_lock(hashtextextended(phone_e164, 0))
            FROM target
            WHERE phone_e164 IS NOT NULL
          ),
          database_time AS MATERIALIZED (
            SELECT clock_timestamp() AS now
          ),
          updated AS (
            UPDATE passengers AS passenger
            SET
              phone_e164 = NULL,
              phone_verified_at = NULL,
              updated_at = database_time.now
            FROM target, database_time
            WHERE passenger.id = target.id
              AND target.phone_e164 IS NOT NULL
              AND EXISTS (SELECT 1 FROM phone_guard)
            RETURNING passenger.id, target.phone_e164 AS old_phone
          ),
          audit AS (
            INSERT INTO passenger_phone_identity_audit (
              passenger_id,
              phone_e164,
              action,
              admin_actor,
              reason
            )
            SELECT id, old_phone, 'unlinked', @adminActor, @reason
            FROM updated
            RETURNING audit_id
          )
          SELECT CASE
            WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'passengerNotFound'
            WHEN EXISTS (SELECT 1 FROM updated) THEN 'unlinked'
            ELSE 'unchanged'
          END AS result,
          (SELECT count(*) FROM audit) AS audit_count
        '''),
        parameters: {
          'passengerId': passengerId,
          'adminActor': adminActor,
          'reason': reason,
        },
      );
      return switch (result.single.toColumnMap()['result'] as String) {
        'unlinked' => PassengerPhoneAssignmentResult.changed,
        'passengerNotFound' => PassengerPhoneAssignmentResult.passengerNotFound,
        _ => PassengerPhoneAssignmentResult.unchanged,
      };
    });
  }

  @override
  Future<List<PassengerPhoneIdentityAuditRecord>> findPhoneHistory({
    required String passengerId,
  }) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT
            passenger_id,
            phone_e164,
            action,
            admin_actor,
            reason,
            occurred_at
          FROM passenger_phone_identity_audit
          WHERE passenger_id = @passengerId
          ORDER BY occurred_at, audit_id
        '''),
        parameters: {'passengerId': passengerId},
      );
      return result
          .map((row) => _phoneIdentityAuditRecord(row.toColumnMap()))
          .toList(growable: false);
    });
  }

  PassengerPhoneRestrictionRecord _restrictionRecord(Map<String, Object?> row) {
    return PassengerPhoneRestrictionRecord(
      restrictionId: row['restriction_id'] as String,
      phoneE164: row['phone_e164'] as String,
      imposedAt: (row['imposed_at'] as DateTime).toUtc(),
      expiresAt: (row['expires_at'] as DateTime?)?.toUtc(),
      reason: row['reason'] as String,
      adminActor: row['admin_actor'] as String,
      liftedAt: (row['lifted_at'] as DateTime?)?.toUtc(),
      liftedBy: row['lifted_by'] as String?,
      liftReason: row['lift_reason'] as String?,
    );
  }

  PassengerPhoneRestrictionAuditRecord _restrictionAuditRecord(
    Map<String, Object?> row,
  ) {
    return PassengerPhoneRestrictionAuditRecord(
      auditId: row['audit_id'] as int,
      restrictionId: row['restriction_id'] as String?,
      phoneE164: row['phone_e164'] as String,
      action: row['action'] as String,
      adminActor: row['admin_actor'] as String,
      reason: row['reason'] as String,
      occurredAt: (row['occurred_at'] as DateTime).toUtc(),
    );
  }

  PassengerPhoneIdentityAuditRecord _phoneIdentityAuditRecord(
    Map<String, Object?> row,
  ) {
    return PassengerPhoneIdentityAuditRecord(
      passengerId: row['passenger_id'] as String,
      phoneE164: row['phone_e164'] as String,
      action: row['action'] as String,
      adminActor: row['admin_actor'] as String,
      reason: row['reason'] as String,
      occurredAt: (row['occurred_at'] as DateTime).toUtc(),
    );
  }
}
