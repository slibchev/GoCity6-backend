import 'package:postgres/postgres.dart';

import 'driver_dispatch_state.dart';
import 'driver_offer_action_outbox_repository.dart';
import 'driver_offer_rejection_transaction.dart';
import 'postgres_driver_dispatch_state_repository.dart';
import 'ride_offer.dart';

/// PostgreSQL adapter for the isolated transaction-aware reject service.
/// It is intentionally not registered in server.dart or an HTTP route.
class PostgresAtomicDriverOfferRejectionTransactionRunner
    implements DriverOfferRejectionTransactionRunner {
  const PostgresAtomicDriverOfferRejectionTransactionRunner({
    required this.database,
    required this.dispatchStateRepository,
    required this.outboxRepository,
  });

  final SessionExecutor database;
  final PostgresDriverDispatchStateRepository dispatchStateRepository;
  final DriverOfferActionOutboxRepository outboxRepository;

  @override
  Future<T> run<T>(
    Future<T> Function(DriverOfferRejectionTransaction transaction) action,
  ) {
    return database.runTx((session) async {
      return action(
        PostgresDriverOfferRejectionTransaction(
          session: session,
          dispatchStateRepository: dispatchStateRepository,
          outboxRepository: outboxRepository,
        ),
      );
    });
  }
}

final class PostgresDriverOfferRejectionTransaction
    implements DriverOfferRejectionTransaction {
  const PostgresDriverOfferRejectionTransaction({
    required this.session,
    required this.dispatchStateRepository,
    required this.outboxRepository,
  });

  final TxSession session;
  final PostgresDriverDispatchStateRepository dispatchStateRepository;
  final DriverOfferActionOutboxRepository outboxRepository;

  @override
  Future<DriverOfferRejectionOffer?> lockOffer(String offerId) async {
    final rows = await session.execute(
      Sql.named('''
        SELECT
          id,
          ride_id,
          driver_id,
          vehicle_id,
          dispatch_round,
          offered_at,
          expires_at,
          status
        FROM ride_offers
        WHERE id = @offerId
        FOR UPDATE
      '''),
      parameters: {'offerId': offerId},
    );
    if (rows.isEmpty) return null;
    if (rows.length != 1) {
      throw StateError('Offer lookup returned duplicate rows.');
    }
    final row = rows.single.toColumnMap();
    return DriverOfferRejectionOffer(
      id: row['id'] as String,
      rideId: row['ride_id'] as String,
      driverId: row['driver_id'] as String,
      vehicleId: row['vehicle_id'] as String,
      dispatchRound: row['dispatch_round'] as int,
      offeredAt: (row['offered_at'] as DateTime).toUtc(),
      expiresAt: (row['expires_at'] as DateTime).toUtc(),
      status: RideOfferStatus.values.byName(row['status'] as String),
    );
  }

  @override
  Future<DateTime?> findRideRequestedAt(String rideId) async {
    final rows = await session.execute(
      Sql.named('''
        SELECT requested_at
        FROM rides
        WHERE id = @rideId
        LIMIT 1
      '''),
      parameters: {'rideId': rideId},
    );
    if (rows.isEmpty) return null;
    return (rows.single.toColumnMap()['requested_at'] as DateTime).toUtc();
  }

  @override
  Future<DriverOfferRejectionQueue?> lockActiveQueue(String driverId) async {
    final rows = await session.execute(
      Sql.named('''
        SELECT
          s.id AS shift_id,
          s.vehicle_id,
          q.availability,
          q.has_pending_offer
        FROM driver_shifts s
        JOIN driver_queue_states q ON q.shift_id = s.id
        WHERE s.driver_id = @driverId
          AND s.ended_at IS NULL
        FOR UPDATE OF s, q
      '''),
      parameters: {'driverId': driverId},
    );
    if (rows.isEmpty) return null;
    if (rows.length != 1) {
      throw StateError('Active driver queue lookup returned duplicate rows.');
    }
    final row = rows.single.toColumnMap();
    return DriverOfferRejectionQueue(
      shiftId: row['shift_id'] as String,
      vehicleId: row['vehicle_id'] as String,
      availability: row['availability'] as String,
      hasPendingOffer: row['has_pending_offer'] as bool,
    );
  }

  @override
  Future<DriverOfferActionOutboxRecord?> findActionForDriver({
    required String offerId,
    required String driverId,
  }) => outboxRepository.findForDriver(
    session: session,
    offerId: offerId,
    driverId: driverId,
  );

  @override
  Future<DriverOfferActionOutboxRecord?> findActionByIdempotencyKey({
    required String driverId,
    required String idempotencyKey,
  }) => outboxRepository.findByDriverAndIdempotencyKey(
    session: session,
    driverId: driverId,
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<DriverDispatchState> updateDispatchState({
    required String driverId,
    required DriverDispatchState Function(DriverDispatchState) transform,
  }) => dispatchStateRepository.updateAtomicallyInTransaction(
    transaction: session,
    driverId: driverId,
    transform: transform,
  );

  @override
  Future<bool> rejectPendingOffer({
    required String offerId,
    required String driverId,
    required DateTime rejectedAt,
  }) async {
    final result = await session.execute(
      Sql.named('''
        UPDATE ride_offers
        SET status = 'rejected', resolved_at = @resolvedAt
        WHERE id = @offerId
          AND driver_id = @driverId
          AND status = 'pending'
      '''),
      parameters: {
        'offerId': offerId,
        'driverId': driverId,
        'resolvedAt': rejectedAt.toUtc(),
      },
    );
    return result.affectedRows == 1;
  }

  @override
  Future<bool> releaseQueue({
    required String shiftId,
    required DateTime queuePrioritySince,
  }) async {
    final result = await session.execute(
      Sql.named('''
        UPDATE driver_queue_states
        SET has_pending_offer = FALSE,
            queue_priority_since = @queuePrioritySince
        WHERE shift_id = @shiftId
          AND availability = 'available'
          AND has_pending_offer = TRUE
      '''),
      parameters: {
        'shiftId': shiftId,
        'queuePrioritySince': queuePrioritySince.toUtc(),
      },
    );
    return result.affectedRows == 1;
  }

  @override
  Future<DriverOfferActionInsertResult> insertAction(
    DriverOfferActionOutboxRecord record,
  ) => outboxRepository.insert(transaction: session, record: record);
}
