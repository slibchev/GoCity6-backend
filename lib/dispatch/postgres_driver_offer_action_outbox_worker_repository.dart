import 'package:postgres/postgres.dart';

import 'driver_offer_action_outbox_repository.dart';
import 'driver_offer_action_outbox_worker_repository.dart';

/// PostgreSQL lease and finalization operations for migration 016.
///
/// Each claim or finalization is a short transaction. The redispatch work is
/// intentionally performed by the caller after [claimNext] has committed.
final class PostgresDriverOfferActionOutboxWorkerRepository
    implements DriverOfferActionOutboxWorkerRepository {
  PostgresDriverOfferActionOutboxWorkerRepository({required this.database});

  final SessionExecutor database;

  static final String _returningColumns = DriverOfferActionOutboxRecord
      .columnNames
      .map((column) => 'job.$column AS $column')
      .join(', ');

  @override
  Future<DriverOfferActionOutboxRecord?> claimNext({
    required String leaseToken,
    required Duration leaseDuration,
    required int maxAttempts,
  }) {
    _validateLease(leaseToken, leaseDuration, maxAttempts);
    return database.runTx((transaction) async {
      // Retire one expired/exhausted job per call. Keeping this bounded avoids
      // a large cleanup update in the claim transaction.
      await transaction.execute(
        Sql.named('''
          WITH exhausted AS (
            SELECT action_id
            FROM driver_offer_action_outbox
            WHERE action = 'reject'
              AND attempt_count >= @maxAttempts
              AND (
                redispatch_status IN ('queued', 'retryable')
                OR (
                  redispatch_status = 'leased'
                  AND lease_until <= clock_timestamp()
                )
              )
            ORDER BY available_at, created_at, action_id
            FOR UPDATE SKIP LOCKED
            LIMIT 1
          )
          UPDATE driver_offer_action_outbox AS job
          SET redispatch_status = 'needs_review',
              lease_token = NULL,
              lease_until = NULL,
              last_error_code = @attemptsExhaustedCode,
              redispatch_result = NULL,
              redispatch_completed_at = NULL,
              updated_at = clock_timestamp()
          FROM exhausted
          WHERE job.action_id = exhausted.action_id
        '''),
        parameters: {
          'maxAttempts': maxAttempts,
          'attemptsExhaustedCode':
              DriverOfferActionOutboxErrorCode.attemptsExhausted.databaseValue,
        },
      );

      final rows = await transaction.execute(
        Sql.named('''
          WITH candidate AS (
            SELECT action_id
            FROM driver_offer_action_outbox
            WHERE action = 'reject'
              AND attempt_count < @maxAttempts
              AND (
                (
                  redispatch_status IN ('queued', 'retryable')
                  AND available_at <= clock_timestamp()
                )
                OR (
                  redispatch_status = 'leased'
                  AND lease_until <= clock_timestamp()
                )
              )
            ORDER BY available_at, created_at, action_id
            FOR UPDATE SKIP LOCKED
            LIMIT 1
          )
          UPDATE driver_offer_action_outbox AS job
          SET redispatch_status = 'leased',
              lease_token = @leaseToken,
              lease_until = clock_timestamp()
                + (@leaseMilliseconds * INTERVAL '1 millisecond'),
              attempt_count = job.attempt_count + 1,
              redispatch_result = NULL,
              redispatch_completed_at = NULL,
              updated_at = clock_timestamp()
          FROM candidate
          WHERE job.action_id = candidate.action_id
          RETURNING $_returningColumns
        '''),
        parameters: {
          'maxAttempts': maxAttempts,
          'leaseToken': leaseToken,
          'leaseMilliseconds': leaseDuration.inMilliseconds,
        },
      );
      if (rows.isEmpty) return null;
      if (rows.length != 1) {
        throw StateError('Outbox claim returned more than one job.');
      }
      return DriverOfferActionOutboxRecord.fromResultRow(rows.single);
    });
  }

  @override
  Future<bool> markCompleted({
    required String actionId,
    required String leaseToken,
  }) => _finalize(
    actionId: actionId,
    leaseToken: leaseToken,
    sql: '''
          UPDATE driver_offer_action_outbox
          SET redispatch_status = 'completed',
              lease_token = NULL,
              lease_until = NULL,
              last_error_code = NULL,
              redispatch_result = '{"outcome":"confirmed"}'::jsonb,
              redispatch_completed_at = clock_timestamp(),
              updated_at = clock_timestamp()
          WHERE action_id = @actionId
            AND action = 'reject'
            AND redispatch_status = 'leased'
            AND lease_token = @leaseToken
            AND lease_until > clock_timestamp()
        ''',
  );

  @override
  Future<bool> markRetryable({
    required String actionId,
    required String leaseToken,
    required Duration retryAfter,
    required DriverOfferActionOutboxErrorCode errorCode,
  }) {
    if (retryAfter.inMilliseconds <= 0) {
      throw ArgumentError.value(retryAfter, 'retryAfter', 'Must be positive.');
    }
    return _finalize(
      actionId: actionId,
      leaseToken: leaseToken,
      parameters: {
        'retryMilliseconds': retryAfter.inMilliseconds,
        'errorCode': errorCode.databaseValue,
      },
      sql: '''
        UPDATE driver_offer_action_outbox
        SET redispatch_status = 'retryable',
            lease_token = NULL,
            lease_until = NULL,
            last_error_code = @errorCode,
            redispatch_result = NULL,
            redispatch_completed_at = NULL,
            available_at = clock_timestamp()
              + (@retryMilliseconds * INTERVAL '1 millisecond'),
            updated_at = clock_timestamp()
        WHERE action_id = @actionId
          AND action = 'reject'
          AND redispatch_status = 'leased'
          AND lease_token = @leaseToken
          AND lease_until > clock_timestamp()
      ''',
    );
  }

  @override
  Future<bool> markNeedsReview({
    required String actionId,
    required String leaseToken,
    required DriverOfferActionOutboxErrorCode errorCode,
  }) => _finalize(
    actionId: actionId,
    leaseToken: leaseToken,
    parameters: {'errorCode': errorCode.databaseValue},
    sql: '''
          UPDATE driver_offer_action_outbox
          SET redispatch_status = 'needs_review',
              lease_token = NULL,
              lease_until = NULL,
              last_error_code = @errorCode,
              redispatch_result = NULL,
              redispatch_completed_at = NULL,
              updated_at = clock_timestamp()
          WHERE action_id = @actionId
            AND action = 'reject'
            AND redispatch_status = 'leased'
            AND lease_token = @leaseToken
            AND lease_until > clock_timestamp()
        ''',
  );

  Future<bool> _finalize({
    required String actionId,
    required String leaseToken,
    required String sql,
    Map<String, Object?> parameters = const {},
  }) async {
    _validateLeaseToken(leaseToken);
    final result = await database.runTx((transaction) async {
      return transaction.execute(
        Sql.named(sql),
        parameters: {
          ...parameters,
          'actionId': actionId,
          'leaseToken': leaseToken,
        },
      );
    });
    return result.affectedRows == 1;
  }

  static void _validateLease(
    String leaseToken,
    Duration leaseDuration,
    int maxAttempts,
  ) {
    _validateLeaseToken(leaseToken);
    if (leaseDuration.inMilliseconds <= 0) {
      throw ArgumentError.value(
        leaseDuration,
        'leaseDuration',
        'Must be positive.',
      );
    }
    if (maxAttempts < 1) {
      throw ArgumentError.value(
        maxAttempts,
        'maxAttempts',
        'Must be at least 1.',
      );
    }
  }

  static void _validateLeaseToken(String leaseToken) {
    if (leaseToken.isEmpty ||
        leaseToken.trim() != leaseToken ||
        leaseToken.runes.length > 200) {
      throw ArgumentError.value(leaseToken, 'leaseToken', 'Invalid token.');
    }
  }
}
