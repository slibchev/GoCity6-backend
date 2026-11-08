import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';

import 'atomic_ride_completion_repository.dart';

import 'ride_request.dart';

import 'ride_request_repository.dart';

import 'ride_request_status.dart';
import 'atomic_ride_cancellation_repository.dart';
import 'atomic_reserved_ride_cancellation_repository.dart';
import '../geography/district_matcher.dart';
import '../dispatch/driver_offer_action_outbox_repository.dart';
import '../dispatch/postgres_driver_offer_action_outbox_repository.dart';

class PostgresRideRequestRepository
    implements
        RideRequestRepository,
        AtomicRideClaimRepository,
        DurableAutomaticDispatchSubmissionRepository,
        AtomicRideCancellationRepository,
        AtomicReservedRideCancellationRepository,
        AtomicRideCompletionRepository {
  final Session database;
  final DistrictMatcher? districtMatcher;
  final DriverOfferActionOutboxRepository outboxRepository;

  PostgresRideRequestRepository({
    required this.database,
    this.districtMatcher,
    DriverOfferActionOutboxRepository? outboxRepository,
  }) : outboxRepository =
           outboxRepository ?? PostgresDriverOfferActionOutboxRepository();

  @override
  Future<RideRequest?> findById(String id) async {
    final result = await database.execute(
      Sql.named('''

        SELECT

          id,

          pickup,
          pickup_display_address,

          pickup_latitude,

          pickup_longitude,

          destination,

          passengers,

          has_luggage,

          requested_at,
          client_request_id,
          passenger_id,

          status,

          assigned_driver_id,

          assigned_vehicle_id,

          dispatch_round,

          driver_bonus_minor,

          bonus_decision,

          currency,

          meter_fare_minor,

          commission_rate_bps,

          commission_amount_minor,

          completed_by_driver_id,

          completed_at

        FROM rides

        WHERE id = @id

        LIMIT 1

      '''),

      parameters: {'id': id},
    );

    if (result.isEmpty) {
      return null;
    }

    return _rideFromRow(result.first.toColumnMap());
  }

  @override
  Future<RideRequest?> findByClientRequestId(String clientRequestId) async {
    final result = await database.execute(
      Sql.named('''
        SELECT *
        FROM rides
        WHERE client_request_id = @clientRequestId
        LIMIT 1
      '''),
      parameters: {'clientRequestId': clientRequestId},
    );

    if (result.isEmpty) {
      return null;
    }

    return _rideFromRow(result.first.toColumnMap());
  }

  @override
  Future<List<RideRequest>> findByAssignedDriverId(String driverId) async {
    final result = await database.execute(
      Sql.named('''

        SELECT

          id,

          pickup,
          pickup_display_address,

          pickup_latitude,

          pickup_longitude,

          destination,

          passengers,

          has_luggage,

          requested_at,
          client_request_id,
          passenger_id,

          status,

          assigned_driver_id,

          assigned_vehicle_id,

          dispatch_round,

          driver_bonus_minor,

          bonus_decision,

          currency,

          meter_fare_minor,

          commission_rate_bps,

          commission_amount_minor,

          completed_by_driver_id,

          completed_at

        FROM rides

        WHERE assigned_driver_id = @driverId

        ORDER BY requested_at ASC

      '''),

      parameters: {'driverId': driverId},
    );

    return result.map((row) => _rideFromRow(row.toColumnMap())).toList();
  }

  @override
  Future<List<RideRequest>> findWaitingForVehicle() async {
    final result = await database.execute(
      Sql.named('''
        SELECT
          id,
          pickup,
          pickup_display_address,
          pickup_latitude,
          pickup_longitude,
          destination,
          passengers,
          has_luggage,
          requested_at,
          client_request_id,
          passenger_id,
          status,
          assigned_driver_id,
          assigned_vehicle_id,
          dispatch_round,
          driver_bonus_minor,
          bonus_decision,
          currency,
          meter_fare_minor,
          commission_rate_bps,
          commission_amount_minor,
          completed_by_driver_id,
          completed_at
        FROM rides
        WHERE status = 'waitingForVehicle'
          AND assigned_driver_id IS NULL
          AND assigned_vehicle_id IS NULL
          AND requested_at > clock_timestamp() - INTERVAL '30 minutes'
          AND NOT EXISTS (
            SELECT 1
            FROM ride_offers ro
            WHERE ro.ride_id = rides.id
              AND ro.status = 'pending'
          )
        ORDER BY requested_at ASC, id ASC
      '''),
    );

    return result.map((row) => _rideFromRow(row.toColumnMap())).toList();
  }

  @override
  Future<void> save(RideRequest request) => _saveOn(database, request);

  Future<void> _saveOn(Session session, RideRequest request) async {
    await session.execute(
      Sql.named('''

        INSERT INTO rides (

          id,

          pickup,
          pickup_display_address,

          pickup_latitude,

          pickup_longitude,

          destination,

          passengers,

          has_luggage,

          requested_at,
          client_request_id,
          passenger_id,

          status,

          assigned_driver_id,

          assigned_vehicle_id,

          dispatch_round,

          driver_bonus_minor,

          bonus_decision,

          currency,

          meter_fare_minor,

          commission_rate_bps,

          commission_amount_minor,

          completed_by_driver_id,

          completed_at

        )

        VALUES (

          @id,

          @pickup,

          @pickupDisplayAddress,

          @pickupLatitude,

          @pickupLongitude,

          @destination,

          @passengers,

          @hasLuggage,

          @requestedAt,

          @clientRequestId,

          @passengerId,

          @status,

          @assignedDriverId,

          @assignedVehicleId,

          @dispatchRound,

          @driverBonusMinor,

          @bonusDecision,

          @currency,

          @meterFareMinor,

          @commissionRateBps,

          @commissionAmountMinor,

          @completedByDriverId,

          @completedAt

        )

        ON CONFLICT (id)

        DO UPDATE SET

          pickup = EXCLUDED.pickup,

          pickup_display_address = COALESCE(
            EXCLUDED.pickup_display_address,
            rides.pickup_display_address
          ),

          pickup_latitude = EXCLUDED.pickup_latitude,

          pickup_longitude = EXCLUDED.pickup_longitude,

          destination = EXCLUDED.destination,

          passengers = EXCLUDED.passengers,

          has_luggage = EXCLUDED.has_luggage,

          requested_at = EXCLUDED.requested_at,

          client_request_id = COALESCE(rides.client_request_id, EXCLUDED.client_request_id),

          passenger_id = COALESCE(rides.passenger_id, EXCLUDED.passenger_id),

          status = EXCLUDED.status,

          assigned_driver_id = EXCLUDED.assigned_driver_id,

          assigned_vehicle_id = EXCLUDED.assigned_vehicle_id,

          dispatch_round = EXCLUDED.dispatch_round,

          driver_bonus_minor = EXCLUDED.driver_bonus_minor,

          bonus_decision = EXCLUDED.bonus_decision,

          currency = EXCLUDED.currency,

          meter_fare_minor = EXCLUDED.meter_fare_minor,

          commission_rate_bps = EXCLUDED.commission_rate_bps,

          commission_amount_minor = EXCLUDED.commission_amount_minor,

          completed_by_driver_id = EXCLUDED.completed_by_driver_id,

          completed_at = EXCLUDED.completed_at

      '''),

      parameters: {
        'id': request.id,

        'pickup': request.pickup,

        'pickupDisplayAddress': request.pickupDisplayAddress,

        'pickupLatitude': request.pickupLatitude,

        'pickupLongitude': request.pickupLongitude,

        'destination': request.destination,

        'passengers': request.passengers,

        'hasLuggage': request.hasLuggage,

        'requestedAt': request.requestedAt.toUtc(),

        'clientRequestId': request.clientRequestId,

        'passengerId': request.passengerId,

        'status': request.status.name,

        'assignedDriverId': request.assignedDriverId,

        'assignedVehicleId': request.assignedVehicleId,

        'dispatchRound': request.dispatchRound,

        'driverBonusMinor': request.driverBonusMinor,

        'bonusDecision': request.bonusDecision.databaseValue,

        'currency': request.currency,

        'meterFareMinor': request.meterFareMinor,

        'commissionRateBps': request.commissionRateBps,

        'commissionAmountMinor': request.commissionAmountMinor,

        'completedByDriverId': request.completedByDriverId,

        'completedAt': request.completedAt?.toUtc(),
      },
    );
  }

  @override
  Future<void> savePendingRideForAutomaticDispatch(RideRequest request) async {
    if (request.status != RideRequestStatus.pending) {
      throw ArgumentError.value(
        request.status,
        'request.status',
        'Only pending rides can be queued for initial dispatch.',
      );
    }

    final transactionDatabase = database as SessionExecutor;
    await transactionDatabase.runTx((transaction) async {
      await _saveOn(transaction, request);
      final nowResult = await transaction.execute(
        Sql('SELECT clock_timestamp() AS database_now'),
      );
      final databaseNow =
          (nowResult.single.toColumnMap()['database_now'] as DateTime).toUtc();
      final actionId = initialDispatchActionId(request.id);
      final event = _initialDispatchRecord(
        rideId: request.id,
        actionId: actionId,
        createdAt: databaseNow,
      );
      final inserted = await outboxRepository.insert(
        transaction: transaction,
        record: event,
      );
      if (inserted is! DriverOfferActionInserted &&
          inserted is! DriverOfferActionAlreadyExists) {
        throw StateError('Initial ride dispatch could not be queued.');
      }
    });
  }

  /// Repairs pending rides written by a pre-outbox Backend release. It is
  /// safe to call at every startup: the deterministic action id and unique
  /// partial index make the insert idempotent.
  Future<int> recoverPendingDispatchEvents({int limit = 100}) async {
    if (limit < 1 || limit > 1000) {
      throw ArgumentError.value(limit, 'limit');
    }
    final transactionDatabase = database as SessionExecutor;
    return transactionDatabase.runTx((transaction) async {
      final rows = await transaction.execute(
        Sql.named('''
          SELECT ride.id
          FROM rides AS ride
          WHERE ride.status = 'pending'
            AND ride.assigned_driver_id IS NULL
            AND ride.assigned_vehicle_id IS NULL
            AND ride.bonus_decision <> 'awaiting_customer'
            AND NOT EXISTS (
              SELECT 1
              FROM ride_offers AS offer
              WHERE offer.ride_id = ride.id
                AND offer.status IN ('pending', 'accepted')
            )
            AND NOT EXISTS (
              SELECT 1
              FROM driver_offer_action_outbox AS action
              WHERE action.ride_id = ride.id
                AND action.action IN (
                  'reject', 'timeout', 'initial_dispatch'
                )
            )
          ORDER BY ride.requested_at ASC, ride.id ASC
          LIMIT @limit
          FOR UPDATE OF ride SKIP LOCKED
        '''),
        parameters: {'limit': limit},
      );
      if (rows.isEmpty) return 0;
      final nowRows = await transaction.execute(
        Sql('SELECT clock_timestamp() AS database_now'),
      );
      final now = (nowRows.single.toColumnMap()['database_now'] as DateTime)
          .toUtc();
      var insertedCount = 0;
      for (final row in rows) {
        final rideId = row.toColumnMap()['id'] as String;
        final result = await outboxRepository.insert(
          transaction: transaction,
          record: _initialDispatchRecord(
            rideId: rideId,
            actionId: initialDispatchActionId(rideId),
            createdAt: now,
          ),
        );
        if (result is DriverOfferActionInserted) {
          insertedCount++;
        } else if (result is! DriverOfferActionAlreadyExists) {
          throw StateError('Pending ride dispatch recovery conflicted.');
        }
      }
      return insertedCount;
    });
  }

  DriverOfferActionOutboxRecord _initialDispatchRecord({
    required String rideId,
    required String actionId,
    required DateTime createdAt,
  }) {
    final requestHash = sha256
        .convert(
          utf8.encode(
            '{"version":1,"action":"initial_dispatch",'
            '"rideId":${jsonEncode(rideId)}}',
          ),
        )
        .toString();
    return DriverOfferActionOutboxRecord(
      actionId: actionId,
      rideId: rideId,
      offerId: null,
      driverId: null,
      action: DriverOfferAction.initialDispatch,
      idempotencyKey: null,
      requestHash: requestHash,
      policyOutcome: null,
      redispatchStatus: DriverOfferRedispatchStatus.queued,
      attemptCount: 0,
      availableAt: createdAt,
      leaseToken: null,
      leaseUntil: null,
      lastErrorCode: null,
      redispatchResult: null,
      createdAt: createdAt,
      settledAt: createdAt,
      updatedAt: createdAt,
      redispatchCompletedAt: null,
    );
  }

  @override
  Future<RideRequest?> claimWaitingRide({
    required String rideId,

    required String driverId,

    required String vehicleId,

    required RideRequestStatus targetStatus,
  }) async {
    if (targetStatus != RideRequestStatus.accepted &&
        targetStatus != RideRequestStatus.reserved) {
      throw ArgumentError.value(
        targetStatus,

        'targetStatus',

        'Target status must be accepted or reserved.',
      );
    }

    final result = await database.execute(
      Sql.named('''

        UPDATE rides

        SET

          status = @status,

          assigned_driver_id = @driverId,

          assigned_vehicle_id = @vehicleId

        WHERE id = @rideId

          AND status = 'waitingForVehicle'

          AND assigned_driver_id IS NULL

          AND assigned_vehicle_id IS NULL

        RETURNING

          id,

          pickup,
          pickup_display_address,

          pickup_latitude,

          pickup_longitude,

          destination,

          passengers,

          has_luggage,

          requested_at,
          client_request_id,
          passenger_id,

          status,

          assigned_driver_id,

          assigned_vehicle_id,

          dispatch_round,

          driver_bonus_minor,

          bonus_decision,

          currency,

          meter_fare_minor,

          commission_rate_bps,

          commission_amount_minor,

          completed_by_driver_id,

          completed_at

      '''),

      parameters: {
        'rideId': rideId,

        'driverId': driverId,

        'vehicleId': vehicleId,

        'status': targetStatus.name,
      },
    );

    if (result.isEmpty) {
      return null;
    }

    return _rideFromRow(result.first.toColumnMap());
  }

  @override
  Future<RideRequest> cancelAssignedRideAndPromoteReservedRide({
    required RideRequest cancelledRide,
    required DateTime cancelledAt,
  }) {
    if (cancelledRide.status != RideRequestStatus.cancelled) {
      throw ArgumentError.value(
        cancelledRide.status,
        'cancelledRide.status',
        'Ride must already be transitioned to cancelled.',
      );
    }

    final driverId = cancelledRide.assignedDriverId;
    final vehicleId = cancelledRide.assignedVehicleId;
    final effectiveCancelledAt = cancelledAt.toUtc();

    if (driverId == null || vehicleId == null) {
      throw ArgumentError(
        'Cancelled assigned ride is missing driver or vehicle assignment.',
      );
    }

    final transactionDatabase = database as SessionExecutor;

    return transactionDatabase.runTx((transaction) async {
      final shiftResult = await transaction.execute(
        Sql.named('''
        SELECT
          s.id AS shift_id,
          s.vehicle_id,
          q.availability,
          q.has_pending_offer,
          q.pending_break_kind,
          q.pending_break_request_id,
          q.district_object_id,
          q.district_entered_at,
          q.queue_priority_since,
          q.latitude,
          q.longitude,
          q.location_updated_at,
          q.gps_fix_at,
          q.pending_district_object_id,
          q.has_customer_cancellation_priority
        FROM driver_shifts s
        JOIN driver_queue_states q
          ON q.shift_id = s.id
        WHERE s.driver_id = @driverId
          AND s.ended_at IS NULL
        LIMIT 1
        FOR UPDATE OF s, q
      '''),
        parameters: {'driverId': driverId},
      );

      if (shiftResult.isEmpty) {
        throw const AtomicRideCancellationConflictException(
          AtomicRideCancellationConflict.activeShiftNotFound,
        );
      }

      final shiftRow = shiftResult.single.toColumnMap();

      final shiftId = shiftRow['shift_id'] as String;
      final shiftVehicleId = shiftRow['vehicle_id'] as String;
      final availability = shiftRow['availability'] as String;
      final hasPendingOffer = shiftRow['has_pending_offer'] as bool;

      if (shiftVehicleId != vehicleId) {
        throw const AtomicRideCancellationConflictException(
          AtomicRideCancellationConflict.currentRideAssignmentMismatch,
        );
      }

      if (availability != 'busy' || hasPendingOffer) {
        throw const AtomicRideCancellationConflictException(
          AtomicRideCancellationConflict.queueStateMismatch,
        );
      }

      final currentRideResult = await transaction.execute(
        Sql.named('''
        SELECT
          status,
          assigned_driver_id,
          assigned_vehicle_id,
          completed_by_driver_id,
          completed_at,
          manual_acceptance_shift_id,
          manual_acceptance_district_object_id,
          manual_acceptance_district_entered_at,
          manual_acceptance_queue_priority_since
        FROM rides
        WHERE id = @rideId
        FOR UPDATE
      '''),
        parameters: {'rideId': cancelledRide.id},
      );

      if (currentRideResult.isEmpty) {
        throw const AtomicRideCancellationConflictException(
          AtomicRideCancellationConflict.currentRideNotFound,
        );
      }

      final currentRideRow = currentRideResult.single.toColumnMap();
      final currentStatus = currentRideRow['status'] as String;

      if (currentStatus != 'accepted' && currentStatus != 'driverArriving') {
        throw const AtomicRideCancellationConflictException(
          AtomicRideCancellationConflict.currentRideNotCancellable,
        );
      }

      if (currentRideRow['assigned_driver_id'] != driverId ||
          currentRideRow['assigned_vehicle_id'] != vehicleId) {
        throw const AtomicRideCancellationConflictException(
          AtomicRideCancellationConflict.currentRideAssignmentMismatch,
        );
      }

      if (currentRideRow['completed_by_driver_id'] != null ||
          currentRideRow['completed_at'] != null) {
        throw const AtomicRideCancellationConflictException(
          AtomicRideCancellationConflict.currentRideNotCancellable,
        );
      }

      final reservationResult = await transaction.execute(
        Sql.named('''
        SELECT
          id,
          ride_id,
          driver_id,
          vehicle_id,
          shift_id,
          reserved_at,
          ended_at
        FROM ride_reservations
        WHERE driver_id = @driverId
          AND ended_at IS NULL
        FOR UPDATE
      '''),
        parameters: {'driverId': driverId},
      );

      if (reservationResult.length > 1) {
        throw const AtomicRideCancellationConflictException(
          AtomicRideCancellationConflict.reservationStateMismatch,
        );
      }

      Map<String, dynamic>? reservationRow;
      String? reservationId;
      String? reservedRideId;

      if (reservationResult.isNotEmpty) {
        final activeReservationRow = reservationResult.single.toColumnMap();

        reservationRow = activeReservationRow;

        if (activeReservationRow['driver_id'] != driverId ||
            activeReservationRow['vehicle_id'] != vehicleId ||
            activeReservationRow['shift_id'] != shiftId) {
          throw const AtomicRideCancellationConflictException(
            AtomicRideCancellationConflict.reservationStateMismatch,
          );
        }

        reservationId = activeReservationRow['id'] as String;
        reservedRideId = activeReservationRow['ride_id'] as String;

        if (reservedRideId == cancelledRide.id) {
          throw const AtomicRideCancellationConflictException(
            AtomicRideCancellationConflict.reservationStateMismatch,
          );
        }

        final reservedRideResult = await transaction.execute(
          Sql.named('''
          SELECT
            status,
            assigned_driver_id,
            assigned_vehicle_id
          FROM rides
          WHERE id = @rideId
          FOR UPDATE
        '''),
          parameters: {'rideId': reservedRideId},
        );

        if (reservedRideResult.isEmpty) {
          throw const AtomicRideCancellationConflictException(
            AtomicRideCancellationConflict.reservedRideStateMismatch,
          );
        }

        final reservedRideRow = reservedRideResult.single.toColumnMap();

        if (reservedRideRow['status'] != 'reserved' ||
            reservedRideRow['assigned_driver_id'] != null ||
            reservedRideRow['assigned_vehicle_id'] != null) {
          throw const AtomicRideCancellationConflictException(
            AtomicRideCancellationConflict.reservedRideStateMismatch,
          );
        }
      }

      final pendingBreakKind = shiftRow['pending_break_kind'] as String?;
      final pendingBreakRequestId =
          shiftRow['pending_break_request_id'] as String?;
      if ((pendingBreakKind == null) != (pendingBreakRequestId == null)) {
        throw const AtomicRideCancellationConflictException(
          AtomicRideCancellationConflict.queueStateMismatch,
        );
      }
      if (pendingBreakRequestId != null && reservationRow != null) {
        throw const AtomicRideCancellationConflictException(
          AtomicRideCancellationConflict.queueStateMismatch,
        );
      }
      if (pendingBreakRequestId != null) {
        final pendingBreakResult = await transaction.execute(
          Sql.named('''
            SELECT request_id
            FROM driver_break_requests
            WHERE request_id = @requestId
              AND shift_id = @shiftId
              AND break_kind = @kind
              AND status = 'pending'
            FOR UPDATE
          '''),
          parameters: {
            'requestId': pendingBreakRequestId,
            'shiftId': shiftId,
            'kind': pendingBreakKind,
          },
        );
        if (pendingBreakResult.isEmpty) {
          throw const AtomicRideCancellationConflictException(
            AtomicRideCancellationConflict.queueStateMismatch,
          );
        }
      }

      DateTime? restoredQueuePrioritySince;
      var restoredCancellationPriority = false;
      if (reservationRow == null) {
        final manualShiftId =
            currentRideRow['manual_acceptance_shift_id'] as String?;
        final manualDistrictId =
            currentRideRow['manual_acceptance_district_object_id'] as int?;
        final manualDistrictEnteredAt =
            (currentRideRow['manual_acceptance_district_entered_at']
                    as DateTime?)
                ?.toUtc();
        final manualPrioritySince =
            (currentRideRow['manual_acceptance_queue_priority_since']
                    as DateTime?)
                ?.toUtc();
        final currentDistrictId = shiftRow['district_object_id'] as int?;
        final currentDistrictEnteredAt =
            (shiftRow['district_entered_at'] as DateTime?)?.toUtc();
        final currentQueuePrioritySince =
            (shiftRow['queue_priority_since'] as DateTime?)?.toUtc();

        if (manualShiftId != null) {
          final stayedInOriginalMembership =
              manualShiftId == shiftId &&
              manualDistrictId != null &&
              manualDistrictEnteredAt != null &&
              manualPrioritySince != null &&
              currentDistrictId == manualDistrictId &&
              currentDistrictEnteredAt == manualDistrictEnteredAt;
          if (stayedInOriginalMembership) {
            restoredQueuePrioritySince = manualPrioritySince;
            restoredCancellationPriority =
                shiftRow['has_customer_cancellation_priority'] as bool;
          } else {
            // The explicitly approved manual-board rule places a driver who
            // changed districts at the end of the confirmed destination queue.
            restoredQueuePrioritySince = effectiveCancelledAt;
          }
        } else {
          final acceptedOfferResult = await transaction.execute(
            Sql.named('''
              SELECT
                source,
                dispatch_district_object_id,
                dispatch_district_entered_at
              FROM ride_offers
              WHERE ride_id = @rideId
                AND driver_id = @driverId
                AND status = 'accepted'
              ORDER BY resolved_at DESC
              LIMIT 1
            '''),
            parameters: {'rideId': cancelledRide.id, 'driverId': driverId},
          );
          final acceptedOffer = acceptedOfferResult.isEmpty
              ? null
              : acceptedOfferResult.single.toColumnMap();
          final offerDistrictId =
              acceptedOffer?['dispatch_district_object_id'] as int?;
          final offerDistrictEnteredAt =
              (acceptedOffer?['dispatch_district_entered_at'] as DateTime?)
                  ?.toUtc();
          final isAutomaticOffer =
              acceptedOffer?['source'] == 'automatic' ||
              acceptedOffer?['source'] == 'waiting_board';

          if (isAutomaticOffer) {
            // For an automatic assignment with an exact district snapshot,
            // grant the one-shot first position only when current fresh GPS
            // still proves the same confirmed membership. If it does not,
            // preserve the existing timestamp; district entry time naturally
            // ranks a later confirmed district transition, and signal loss
            // alone never resets earned FIFO priority.
            restoredQueuePrioritySince = currentQueuePrioritySince;
            if (offerDistrictId == null || offerDistrictEnteredAt == null) {
              // Legacy/global automatic offers have no durable dispatch-area
              // snapshot. Preserve any existing one-shot priority instead of
              // guessing which district should receive compensation.
              restoredCancellationPriority =
                  shiftRow['has_customer_cancellation_priority'] as bool;
            } else {
              final databaseTimeResult = await transaction.execute(
                Sql('SELECT clock_timestamp() AS database_now'),
              );
              final databaseNow =
                  (databaseTimeResult.single.toColumnMap()['database_now']
                          as DateTime)
                      .toUtc();
              restoredCancellationPriority =
                  currentDistrictId == offerDistrictId &&
                  currentDistrictEnteredAt == offerDistrictEnteredAt &&
                  _locationProvesDistrictMembership(
                    shiftRow: shiftRow,
                    districtObjectId: offerDistrictId,
                    now: databaseNow,
                  );
            }
          } else {
            // Legacy/manual assignments without a durable queue snapshot keep
            // their established cancellation behavior.
            restoredQueuePrioritySince = effectiveCancelledAt;
          }
        }
      }

      final cancelledRideResult = await transaction.execute(
        Sql.named('''
        UPDATE rides
        SET status = 'cancelled'
        WHERE id = @rideId
          AND status IN ('accepted', 'driverArriving')
          AND assigned_driver_id = @driverId
          AND assigned_vehicle_id = @vehicleId
          AND completed_by_driver_id IS NULL
          AND completed_at IS NULL
        RETURNING
          id,
          pickup,
          pickup_display_address,
          pickup_latitude,
          pickup_longitude,
          destination,
          passengers,
          has_luggage,
          requested_at,
          client_request_id,
          passenger_id,
          status,
          assigned_driver_id,
          assigned_vehicle_id,
          dispatch_round,
          driver_bonus_minor,
          bonus_decision,
          currency,
          meter_fare_minor,
          commission_rate_bps,
          commission_amount_minor,
          completed_by_driver_id,
          completed_at
      '''),
        parameters: {
          'rideId': cancelledRide.id,
          'driverId': driverId,
          'vehicleId': vehicleId,
        },
      );

      if (cancelledRideResult.isEmpty) {
        throw const AtomicRideCancellationConflictException(
          AtomicRideCancellationConflict.currentRideNotCancellable,
        );
      }

      if (reservationRow != null) {
        final reservedRideUpdateResult = await transaction.execute(
          Sql.named('''
          UPDATE rides
          SET
            status = 'accepted',
            assigned_driver_id = @driverId,
            assigned_vehicle_id = @vehicleId
          WHERE id = @rideId
            AND status = 'reserved'
            AND assigned_driver_id IS NULL
            AND assigned_vehicle_id IS NULL
          RETURNING id
        '''),
          parameters: {
            'rideId': reservedRideId,
            'driverId': driverId,
            'vehicleId': vehicleId,
          },
        );

        if (reservedRideUpdateResult.isEmpty) {
          throw const AtomicRideCancellationConflictException(
            AtomicRideCancellationConflict.reservedRideStateMismatch,
          );
        }

        final reservationUpdateResult = await transaction.execute(
          Sql.named('''
          UPDATE ride_reservations
          SET ended_at = @endedAt
          WHERE id = @reservationId
            AND ended_at IS NULL
          RETURNING id
        '''),
          parameters: {
            'reservationId': reservationId,
            'endedAt': effectiveCancelledAt,
          },
        );

        if (reservationUpdateResult.isEmpty) {
          throw const AtomicRideCancellationConflictException(
            AtomicRideCancellationConflict.reservationStateMismatch,
          );
        }

        final queueUpdateResult = await transaction.execute(
          Sql.named('''
          UPDATE driver_queue_states
          SET
            availability = 'busy',
            break_started_at = NULL,
            has_pending_offer = FALSE
          WHERE shift_id = @shiftId
            AND availability = 'busy'
            AND has_pending_offer = FALSE
          RETURNING shift_id
        '''),
          parameters: {'shiftId': shiftId},
        );

        if (queueUpdateResult.isEmpty) {
          throw const AtomicRideCancellationConflictException(
            AtomicRideCancellationConflict.queueStateMismatch,
          );
        }
      } else {
        if (pendingBreakRequestId != null) {
          final cancelledBreakResult = await transaction.execute(
            Sql.named('''
              UPDATE driver_break_requests
              SET status = 'cancelled', ended_at = clock_timestamp()
              WHERE request_id = @requestId
                AND shift_id = @shiftId
                AND status = 'pending'
              RETURNING request_id
            '''),
            parameters: {
              'requestId': pendingBreakRequestId,
              'shiftId': shiftId,
            },
          );
          if (cancelledBreakResult.isEmpty) {
            throw const AtomicRideCancellationConflictException(
              AtomicRideCancellationConflict.queueStateMismatch,
            );
          }
        }
        final queueUpdateResult = await transaction.execute(
          Sql.named('''
          UPDATE driver_queue_states
          SET
            availability = 'available',
            queue_priority_since = @queuePrioritySince,
            has_customer_cancellation_priority =
              @hasCustomerCancellationPriority,
            break_started_at = NULL,
            has_pending_offer = FALSE,
            pending_break_kind = NULL,
            pending_break_request_id = NULL
          WHERE shift_id = @shiftId
            AND availability = 'busy'
            AND has_pending_offer = FALSE
          RETURNING shift_id
        '''),
          parameters: {
            'shiftId': shiftId,
            'queuePrioritySince': restoredQueuePrioritySince,
            'hasCustomerCancellationPriority': restoredCancellationPriority,
          },
        );

        if (queueUpdateResult.isEmpty) {
          throw const AtomicRideCancellationConflictException(
            AtomicRideCancellationConflict.queueStateMismatch,
          );
        }
      }

      return _rideFromRow(cancelledRideResult.single.toColumnMap());
    });
  }

  @override
  Future<RideRequest> cancelReservedRide({
    required String rideId,
    required DateTime cancelledAt,
  }) {
    final effectiveCancelledAt = cancelledAt.toUtc();
    final transactionDatabase = database as SessionExecutor;

    return transactionDatabase.runTx((transaction) async {
      // Identify the active reservation first, without taking a lock.
      // The authoritative reservation state is revalidated later
      // after shift/current-state locks are held.
      final reservationLookupResult = await transaction.execute(
        Sql.named('''
        SELECT
          id,
          ride_id,
          driver_id,
          vehicle_id,
          shift_id
        FROM ride_reservations
        WHERE ride_id = @rideId
          AND ended_at IS NULL
        ORDER BY reserved_at DESC
        LIMIT 2
      '''),
        parameters: {'rideId': rideId},
      );

      if (reservationLookupResult.isEmpty) {
        throw const AtomicReservedRideCancellationConflictException(
          AtomicReservedRideCancellationConflict.activeReservationNotFound,
        );
      }

      if (reservationLookupResult.length > 1) {
        throw const AtomicReservedRideCancellationConflictException(
          AtomicReservedRideCancellationConflict.reservationStateMismatch,
        );
      }

      final reservationLookupRow = reservationLookupResult.single.toColumnMap();

      final reservationId = reservationLookupRow['id'] as String;
      final driverId = reservationLookupRow['driver_id'] as String;
      final vehicleId = reservationLookupRow['vehicle_id'] as String;
      final shiftId = reservationLookupRow['shift_id'] as String;

      // Lock order:
      //   1. active shift + queue
      final shiftResult = await transaction.execute(
        Sql.named('''
        SELECT
          s.id AS shift_id,
          s.driver_id,
          s.vehicle_id,
          q.availability,
          q.has_pending_offer
        FROM driver_shifts s
        JOIN driver_queue_states q
          ON q.shift_id = s.id
        WHERE s.id = @shiftId
          AND s.driver_id = @driverId
          AND s.ended_at IS NULL
        LIMIT 1
        FOR UPDATE OF s, q
      '''),
        parameters: {'shiftId': shiftId, 'driverId': driverId},
      );

      if (shiftResult.isEmpty) {
        throw const AtomicReservedRideCancellationConflictException(
          AtomicReservedRideCancellationConflict.activeShiftNotFound,
        );
      }

      final shiftRow = shiftResult.single.toColumnMap();

      if (shiftRow['vehicle_id'] != vehicleId) {
        throw const AtomicReservedRideCancellationConflictException(
          AtomicReservedRideCancellationConflict.reservationStateMismatch,
        );
      }

      final availability = shiftRow['availability'] as String;
      final hasPendingOffer = shiftRow['has_pending_offer'] as bool;

      if ((availability != 'busy' && availability != 'externalRide') ||
          hasPendingOffer) {
        throw const AtomicReservedRideCancellationConflictException(
          AtomicReservedRideCancellationConflict.queueStateMismatch,
        );
      }

      // 2. Lock and validate the driver's current ride/session.
      if (availability == 'busy') {
        final currentRideResult = await transaction.execute(
          Sql.named('''
          SELECT
            id,
            status,
            assigned_driver_id,
            assigned_vehicle_id
          FROM rides
          WHERE assigned_driver_id = @driverId
            AND assigned_vehicle_id = @vehicleId
            AND status IN (
              'accepted',
              'driverArriving',
              'inProgress'
            )
            AND id <> @reservedRideId
          ORDER BY requested_at ASC
          FOR UPDATE
        '''),
          parameters: {
            'driverId': driverId,
            'vehicleId': vehicleId,
            'reservedRideId': rideId,
          },
        );

        if (currentRideResult.isEmpty) {
          throw const AtomicReservedRideCancellationConflictException(
            AtomicReservedRideCancellationConflict.currentCity6RideNotFound,
          );
        }

        if (currentRideResult.length > 1) {
          throw const AtomicReservedRideCancellationConflictException(
            AtomicReservedRideCancellationConflict.queueStateMismatch,
          );
        }
      } else {
        final externalRideResult = await transaction.execute(
          Sql.named('''
          SELECT id
          FROM external_ride_sessions
          WHERE driver_id = @driverId
            AND ended_at IS NULL
          LIMIT 1
          FOR UPDATE
        '''),
          parameters: {'driverId': driverId},
        );

        if (externalRideResult.isEmpty) {
          throw const AtomicReservedRideCancellationConflictException(
            AtomicReservedRideCancellationConflict.activeExternalRideNotFound,
          );
        }
      }

      // 3. Lock and revalidate the active reservation.
      final reservationResult = await transaction.execute(
        Sql.named('''
        SELECT
          id,
          ride_id,
          driver_id,
          vehicle_id,
          shift_id,
          ended_at
        FROM ride_reservations
        WHERE id = @reservationId
        FOR UPDATE
      '''),
        parameters: {'reservationId': reservationId},
      );

      if (reservationResult.isEmpty) {
        throw const AtomicReservedRideCancellationConflictException(
          AtomicReservedRideCancellationConflict.activeReservationNotFound,
        );
      }

      final reservationRow = reservationResult.single.toColumnMap();

      if (reservationRow['ended_at'] != null ||
          reservationRow['ride_id'] != rideId ||
          reservationRow['driver_id'] != driverId ||
          reservationRow['vehicle_id'] != vehicleId ||
          reservationRow['shift_id'] != shiftId) {
        throw const AtomicReservedRideCancellationConflictException(
          AtomicReservedRideCancellationConflict.reservationStateMismatch,
        );
      }

      // 4. Lock and revalidate the reserved ride.
      final reservedRideResult = await transaction.execute(
        Sql.named('''
        SELECT
          status,
          assigned_driver_id,
          assigned_vehicle_id
        FROM rides
        WHERE id = @rideId
        FOR UPDATE
      '''),
        parameters: {'rideId': rideId},
      );

      if (reservedRideResult.isEmpty) {
        throw const AtomicReservedRideCancellationConflictException(
          AtomicReservedRideCancellationConflict.reservedRideNotFound,
        );
      }

      final reservedRideRow = reservedRideResult.single.toColumnMap();

      if (reservedRideRow['status'] != 'reserved') {
        throw const AtomicReservedRideCancellationConflictException(
          AtomicReservedRideCancellationConflict.reservedRideNotReserved,
        );
      }

      if (reservedRideRow['assigned_driver_id'] != null ||
          reservedRideRow['assigned_vehicle_id'] != null) {
        throw const AtomicReservedRideCancellationConflictException(
          AtomicReservedRideCancellationConflict.reservationStateMismatch,
        );
      }

      final cancelledRideResult = await transaction.execute(
        Sql.named('''
        UPDATE rides
        SET status = 'cancelled'
        WHERE id = @rideId
          AND status = 'reserved'
          AND assigned_driver_id IS NULL
          AND assigned_vehicle_id IS NULL
        RETURNING
          id,
          pickup,
          pickup_display_address,
          pickup_latitude,
          pickup_longitude,
          destination,
          passengers,
          has_luggage,
          requested_at,
          client_request_id,
          passenger_id,
          status,
          assigned_driver_id,
          assigned_vehicle_id,
          dispatch_round,
          driver_bonus_minor,
          bonus_decision,
          currency,
          meter_fare_minor,
          commission_rate_bps,
          commission_amount_minor,
          completed_by_driver_id,
          completed_at
      '''),
        parameters: {'rideId': rideId},
      );

      if (cancelledRideResult.isEmpty) {
        throw const AtomicReservedRideCancellationConflictException(
          AtomicReservedRideCancellationConflict.reservedRideNotReserved,
        );
      }

      final reservationUpdateResult = await transaction.execute(
        Sql.named('''
        UPDATE ride_reservations
        SET ended_at = @endedAt
        WHERE id = @reservationId
          AND ended_at IS NULL
        RETURNING id
      '''),
        parameters: {
          'reservationId': reservationId,
          'endedAt': effectiveCancelledAt,
        },
      );

      if (reservationUpdateResult.isEmpty) {
        throw const AtomicReservedRideCancellationConflictException(
          AtomicReservedRideCancellationConflict.reservationStateMismatch,
        );
      }

      // Queue availability intentionally remains unchanged:
      // the driver's current City6/external ride is still active.
      return _rideFromRow(cancelledRideResult.single.toColumnMap());
    });
  }

  @override
  Future<RideRequest> completeRideAndPromoteReservedRide({
    required RideRequest completedRide,
  }) {
    if (completedRide.status != RideRequestStatus.completed) {
      throw ArgumentError.value(
        completedRide.status,

        'completedRide.status',

        'Ride must already be computed as completed.',
      );
    }

    final driverId = completedRide.completedByDriverId;

    final assignedDriverId = completedRide.assignedDriverId;

    final vehicleId = completedRide.assignedVehicleId;

    final completedAt = completedRide.completedAt?.toUtc();

    final meterFareMinor = completedRide.meterFareMinor;

    final commissionRateBps = completedRide.commissionRateBps;

    final commissionAmountMinor = completedRide.commissionAmountMinor;

    if (driverId == null ||
        assignedDriverId == null ||
        vehicleId == null ||
        completedAt == null ||
        meterFareMinor == null ||
        commissionRateBps == null ||
        commissionAmountMinor == null) {
      throw ArgumentError(
        'Completed ride is missing assignment, fare, commission, '
        'or completion data.',
      );
    }

    if (assignedDriverId != driverId) {
      throw ArgumentError('completedByDriverId must match assignedDriverId.');
    }

    if (meterFareMinor <= 0 ||
        commissionRateBps < 0 ||
        commissionAmountMinor < 0) {
      throw ArgumentError(
        'Completed ride contains invalid fare or commission data.',
      );
    }

    final transactionDatabase = database as SessionExecutor;

    return transactionDatabase.runTx((transaction) async {
      final shiftResult = await transaction.execute(
        Sql.named('''

          SELECT

            s.id AS shift_id,

            s.vehicle_id,

            s.protected_breaks_used,

            q.availability,

            q.has_pending_offer,

            q.pending_break_kind,

            q.pending_break_request_id

          FROM driver_shifts s

          JOIN driver_queue_states q

            ON q.shift_id = s.id

          WHERE s.driver_id = @driverId

            AND s.ended_at IS NULL

          LIMIT 1

          FOR UPDATE OF s, q

        '''),

        parameters: {'driverId': driverId},
      );

      if (shiftResult.isEmpty) {
        throw const AtomicRideCompletionConflictException(
          AtomicRideCompletionConflict.activeShiftNotFound,
        );
      }

      final shiftRow = shiftResult.single.toColumnMap();

      final shiftId = shiftRow['shift_id'] as String;

      final shiftVehicleId = shiftRow['vehicle_id'] as String;

      final availability = shiftRow['availability'] as String;

      final hasPendingOffer = shiftRow['has_pending_offer'] as bool;

      final pendingBreakKind = shiftRow['pending_break_kind'] as String?;

      final pendingBreakRequestId =
          shiftRow['pending_break_request_id'] as String?;

      final shortBreaksUsed = shiftRow['protected_breaks_used'] as int;

      if (shiftVehicleId != vehicleId) {
        throw const AtomicRideCompletionConflictException(
          AtomicRideCompletionConflict.currentRideAssignmentMismatch,
        );
      }

      if (availability != 'busy' || hasPendingOffer) {
        throw const AtomicRideCompletionConflictException(
          AtomicRideCompletionConflict.queueStateMismatch,
        );
      }

      if ((pendingBreakKind == null) != (pendingBreakRequestId == null)) {
        throw const AtomicRideCompletionConflictException(
          AtomicRideCompletionConflict.queueStateMismatch,
        );
      }

      final currentRideResult = await transaction.execute(
        Sql.named('''

          SELECT

            status,

            assigned_driver_id,

            assigned_vehicle_id,

            completed_by_driver_id,

            completed_at

          FROM rides

          WHERE id = @rideId

          FOR UPDATE

        '''),

        parameters: {'rideId': completedRide.id},
      );

      if (currentRideResult.isEmpty) {
        throw const AtomicRideCompletionConflictException(
          AtomicRideCompletionConflict.currentRideNotFound,
        );
      }

      final currentRideRow = currentRideResult.single.toColumnMap();

      if (currentRideRow['status'] != 'inProgress') {
        throw const AtomicRideCompletionConflictException(
          AtomicRideCompletionConflict.currentRideNotInProgress,
        );
      }

      if (currentRideRow['assigned_driver_id'] != driverId ||
          currentRideRow['assigned_vehicle_id'] != vehicleId) {
        throw const AtomicRideCompletionConflictException(
          AtomicRideCompletionConflict.currentRideAssignmentMismatch,
        );
      }

      if (currentRideRow['completed_by_driver_id'] != null ||
          currentRideRow['completed_at'] != null) {
        throw const AtomicRideCompletionConflictException(
          AtomicRideCompletionConflict.currentRideNotInProgress,
        );
      }

      final reservationResult = await transaction.execute(
        Sql.named('''

          SELECT

            id,

            ride_id,

            driver_id,

            vehicle_id,

            shift_id,

            reserved_at,

            ended_at

          FROM ride_reservations

          WHERE driver_id = @driverId

            AND ended_at IS NULL

          FOR UPDATE

        '''),

        parameters: {'driverId': driverId},
      );

      if (reservationResult.length > 1) {
        throw const AtomicRideCompletionConflictException(
          AtomicRideCompletionConflict.reservationStateMismatch,
        );
      }

      Map<String, dynamic>? reservationRow;

      String? reservationId;

      String? reservedRideId;

      if (reservationResult.isNotEmpty) {
        final activeReservationRow = reservationResult.single.toColumnMap();
        reservationRow = activeReservationRow;

        if (activeReservationRow['driver_id'] != driverId ||
            activeReservationRow['vehicle_id'] != vehicleId ||
            activeReservationRow['shift_id'] != shiftId) {
          throw const AtomicRideCompletionConflictException(
            AtomicRideCompletionConflict.reservationStateMismatch,
          );
        }

        reservationId = activeReservationRow['id'] as String;
        reservedRideId = activeReservationRow['ride_id'] as String;

        if (reservedRideId == completedRide.id) {
          throw const AtomicRideCompletionConflictException(
            AtomicRideCompletionConflict.reservationStateMismatch,
          );
        }

        final reservedRideResult = await transaction.execute(
          Sql.named('''

            SELECT

              status,

              assigned_driver_id,

              assigned_vehicle_id

            FROM rides

            WHERE id = @rideId

            FOR UPDATE

          '''),

          parameters: {'rideId': reservedRideId},
        );

        if (reservedRideResult.isEmpty) {
          throw const AtomicRideCompletionConflictException(
            AtomicRideCompletionConflict.reservedRideStateMismatch,
          );
        }

        final reservedRideRow = reservedRideResult.single.toColumnMap();

        if (reservedRideRow['status'] != 'reserved' ||
            reservedRideRow['assigned_driver_id'] != null ||
            reservedRideRow['assigned_vehicle_id'] != null) {
          throw const AtomicRideCompletionConflictException(
            AtomicRideCompletionConflict.reservedRideStateMismatch,
          );
        }
      }

      if (pendingBreakRequestId != null && reservationRow != null) {
        throw const AtomicRideCompletionConflictException(
          AtomicRideCompletionConflict.queueStateMismatch,
        );
      }

      if (pendingBreakRequestId != null) {
        final requestResult = await transaction.execute(
          Sql.named('''
            SELECT request_id
            FROM driver_break_requests
            WHERE request_id = @requestId
              AND shift_id = @shiftId
              AND break_kind = @kind
              AND status = 'pending'
            FOR UPDATE
          '''),
          parameters: {
            'requestId': pendingBreakRequestId,
            'shiftId': shiftId,
            'kind': pendingBreakKind,
          },
        );
        if (requestResult.isEmpty ||
            (pendingBreakKind == 'short' && shortBreaksUsed >= 3)) {
          throw const AtomicRideCompletionConflictException(
            AtomicRideCompletionConflict.queueStateMismatch,
          );
        }
      }

      final completedRideResult = await transaction.execute(
        Sql.named('''

          UPDATE rides

          SET

            status = 'completed',

            meter_fare_minor = @meterFareMinor,

            commission_rate_bps = @commissionRateBps,

            commission_amount_minor = @commissionAmountMinor,

            completed_by_driver_id = @completedByDriverId,

            completed_at = @completedAt

          WHERE id = @rideId

            AND status = 'inProgress'

            AND assigned_driver_id = @driverId

            AND assigned_vehicle_id = @vehicleId

            AND completed_by_driver_id IS NULL

            AND completed_at IS NULL

          RETURNING

            id,

            pickup,
            pickup_display_address,

          pickup_latitude,

          pickup_longitude,

            destination,

            passengers,

            has_luggage,

            requested_at,
            client_request_id,
            passenger_id,

            status,

            assigned_driver_id,

            assigned_vehicle_id,

            dispatch_round,

            driver_bonus_minor,

            bonus_decision,

            currency,

            meter_fare_minor,

            commission_rate_bps,

            commission_amount_minor,

            completed_by_driver_id,

            completed_at

        '''),

        parameters: {
          'rideId': completedRide.id,

          'driverId': driverId,

          'vehicleId': vehicleId,

          'meterFareMinor': meterFareMinor,

          'commissionRateBps': commissionRateBps,

          'commissionAmountMinor': commissionAmountMinor,

          'completedByDriverId': driverId,

          'completedAt': completedAt,
        },
      );

      if (completedRideResult.isEmpty) {
        throw const AtomicRideCompletionConflictException(
          AtomicRideCompletionConflict.currentRideNotInProgress,
        );
      }

      if (reservationRow != null) {
        final reservedRideUpdateResult = await transaction.execute(
          Sql.named('''

            UPDATE rides

            SET

              status = 'accepted',

              assigned_driver_id = @driverId,

              assigned_vehicle_id = @vehicleId

            WHERE id = @rideId

              AND status = 'reserved'

              AND assigned_driver_id IS NULL

              AND assigned_vehicle_id IS NULL

            RETURNING id

          '''),

          parameters: {
            'rideId': reservedRideId,

            'driverId': driverId,

            'vehicleId': vehicleId,
          },
        );

        if (reservedRideUpdateResult.isEmpty) {
          throw const AtomicRideCompletionConflictException(
            AtomicRideCompletionConflict.reservedRideStateMismatch,
          );
        }

        final reservationUpdateResult = await transaction.execute(
          Sql.named('''

            UPDATE ride_reservations

            SET ended_at = @endedAt

            WHERE id = @reservationId

              AND ended_at IS NULL

            RETURNING id

          '''),

          parameters: {'reservationId': reservationId, 'endedAt': completedAt},
        );

        if (reservationUpdateResult.isEmpty) {
          throw const AtomicRideCompletionConflictException(
            AtomicRideCompletionConflict.reservationStateMismatch,
          );
        }

        final queueUpdateResult = await transaction.execute(
          Sql.named('''

            UPDATE driver_queue_states

            SET

              availability = 'busy',

              break_started_at = NULL,

              has_pending_offer = FALSE

            WHERE shift_id = @shiftId

              AND availability = 'busy'

              AND has_pending_offer = FALSE

            RETURNING shift_id

          '''),

          parameters: {'shiftId': shiftId},
        );

        if (queueUpdateResult.isEmpty) {
          throw const AtomicRideCompletionConflictException(
            AtomicRideCompletionConflict.queueStateMismatch,
          );
        }
      } else {
        DateTime? activatedAt;
        if (pendingBreakRequestId != null) {
          final activationResult = await transaction.execute(
            Sql('SELECT clock_timestamp() AS activation_time'),
          );
          activatedAt =
              (activationResult.single.toColumnMap()['activation_time']
                      as DateTime)
                  .toUtc();

          final requestUpdateResult = await transaction.execute(
            Sql.named('''
              UPDATE driver_break_requests
              SET status = 'active', activated_at = @activatedAt
              WHERE request_id = @requestId
                AND shift_id = @shiftId
                AND break_kind = @kind
                AND status = 'pending'
              RETURNING request_id
            '''),
            parameters: {
              'activatedAt': activatedAt,
              'requestId': pendingBreakRequestId,
              'shiftId': shiftId,
              'kind': pendingBreakKind,
            },
          );
          if (requestUpdateResult.isEmpty) {
            throw const AtomicRideCompletionConflictException(
              AtomicRideCompletionConflict.queueStateMismatch,
            );
          }

          if (pendingBreakKind == 'short') {
            final shortBreakCountResult = await transaction.execute(
              Sql.named('''
                UPDATE driver_shifts
                SET protected_breaks_used = protected_breaks_used + 1
                WHERE id = @shiftId
                  AND protected_breaks_used < 3
                RETURNING id
              '''),
              parameters: {'shiftId': shiftId},
            );
            if (shortBreakCountResult.isEmpty) {
              throw const AtomicRideCompletionConflictException(
                AtomicRideCompletionConflict.queueStateMismatch,
              );
            }
          }
        }

        final queueUpdateResult = await transaction.execute(
          Sql.named('''

            UPDATE driver_queue_states

            SET

              availability = CASE @pendingBreakKind::text
                WHEN 'short' THEN 'shortBreak'
                WHEN 'long' THEN 'longBreak'
                ELSE 'available'
              END,

              queue_priority_since = @queuePrioritySince,

              break_started_at = @breakStartedAt,

              has_pending_offer = FALSE,

              pending_break_kind = NULL,

              pending_break_request_id = NULL,

              active_break_request_id = @activeBreakRequestId

            WHERE shift_id = @shiftId

              AND availability = 'busy'

              AND has_pending_offer = FALSE

            RETURNING shift_id

          '''),

          parameters: {
            'shiftId': shiftId,
            'queuePrioritySince': completedAt,
            'pendingBreakKind': pendingBreakKind,
            'breakStartedAt': activatedAt,
            'activeBreakRequestId': pendingBreakRequestId,
          },
        );

        if (queueUpdateResult.isEmpty) {
          throw const AtomicRideCompletionConflictException(
            AtomicRideCompletionConflict.queueStateMismatch,
          );
        }
      }

      return _rideFromRow(completedRideResult.single.toColumnMap());
    });
  }

  bool _locationProvesDistrictMembership({
    required Map<String, dynamic> shiftRow,
    required int districtObjectId,
    required DateTime now,
  }) {
    final matcher = districtMatcher;
    if (matcher == null ||
        shiftRow['district_object_id'] != districtObjectId ||
        shiftRow['pending_district_object_id'] != null) {
      return false;
    }

    final latitude = (shiftRow['latitude'] as num?)?.toDouble();
    final longitude = (shiftRow['longitude'] as num?)?.toDouble();
    final locationUpdatedAt = (shiftRow['location_updated_at'] as DateTime?)
        ?.toUtc();
    final gpsFixAt = (shiftRow['gps_fix_at'] as DateTime?)?.toUtc();
    if (latitude == null ||
        longitude == null ||
        locationUpdatedAt == null ||
        gpsFixAt == null) {
      return false;
    }

    final nowUtc = now.toUtc();
    final locationAge = nowUtc.difference(locationUpdatedAt);
    final gpsFixAge = nowUtc.difference(gpsFixAt);
    if (locationAge.isNegative ||
        locationAge > const Duration(seconds: 30) ||
        gpsFixAge < const Duration(seconds: -5) ||
        gpsFixAge > const Duration(seconds: 15)) {
      return false;
    }

    try {
      final match = matcher.match(latitude: latitude, longitude: longitude);
      return match != null &&
          match.district.objectId == districtObjectId &&
          match.resolution != DistrictMatchResolution.overlapTieBreak;
    } on ArgumentError {
      return false;
    }
  }

  RideRequest _rideFromRow(Map<String, dynamic> row) {
    return RideRequest(
      id: row['id'] as String,

      pickup: row['pickup'] as String,

      pickupDisplayAddress: row['pickup_display_address'] as String?,

      pickupLatitude: (row['pickup_latitude'] as num?)?.toDouble(),

      pickupLongitude: (row['pickup_longitude'] as num?)?.toDouble(),

      destination: row['destination'] as String,

      passengers: row['passengers'] as int,

      hasLuggage: row['has_luggage'] as bool,

      requestedAt: (row['requested_at'] as DateTime).toUtc(),

      clientRequestId: row['client_request_id'] as String?,

      passengerId: row['passenger_id'] as String?,

      status: RideRequestStatus.values.byName(row['status'] as String),

      assignedDriverId: row['assigned_driver_id'] as String?,

      assignedVehicleId: row['assigned_vehicle_id'] as String?,

      dispatchRound: row['dispatch_round'] as int,

      driverBonusMinor: row['driver_bonus_minor'] as int,

      bonusDecision: RideBonusDecision.fromDatabaseValue(
        row['bonus_decision'] as String,
      ),

      currency: (row['currency'] as String).trim(),

      meterFareMinor: row['meter_fare_minor'] as int?,

      commissionRateBps: row['commission_rate_bps'] as int?,

      commissionAmountMinor: row['commission_amount_minor'] as int?,

      completedByDriverId: row['completed_by_driver_id'] as String?,

      completedAt: (row['completed_at'] as DateTime?)?.toUtc(),
    );
  }
}
