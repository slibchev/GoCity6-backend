import 'package:postgres/postgres.dart';

import 'atomic_ride_bonus_decision_repository.dart';

class PostgresAtomicRideBonusDecisionRepository
    implements AtomicRideBonusDecisionRepository {
  final SessionExecutor database;

  PostgresAtomicRideBonusDecisionRepository({required this.database});

  @override
  Future<void> markAwaitingCustomer({required String rideId}) {
    return database.runTx((transaction) async {
      final rideRow = await _lockRide(transaction, rideId: rideId);

      _requirePendingUnassignedRide(rideRow);

      if (rideRow['dispatch_round'] != 1 ||
          rideRow['driver_bonus_minor'] != 0 ||
          rideRow['bonus_decision'] != 'not_offered') {
        throw const AtomicRideBonusDecisionConflictException(
          AtomicRideBonusDecisionConflict.rideDispatchStateMismatch,
        );
      }

      await _requireNoPendingOffer(transaction, rideId: rideId);

      final roundOneHistory = await transaction.execute(
        Sql.named('''
          SELECT 1
          FROM ride_offers
          WHERE ride_id = @rideId
            AND dispatch_round = 1
            AND status IN ('rejected', 'expired')
          LIMIT 1
        '''),
        parameters: {'rideId': rideId},
      );

      if (roundOneHistory.isEmpty) {
        throw const AtomicRideBonusDecisionConflictException(
          AtomicRideBonusDecisionConflict.rideHasNoRoundOneOfferHistory,
        );
      }

      final updateResult = await transaction.execute(
        Sql.named('''
          UPDATE rides
          SET bonus_decision = 'awaiting_customer'
          WHERE id = @rideId
            AND status = 'pending'
            AND assigned_driver_id IS NULL
            AND assigned_vehicle_id IS NULL
            AND dispatch_round = 1
            AND driver_bonus_minor = 0
            AND bonus_decision = 'not_offered'
          RETURNING id
        '''),
        parameters: {'rideId': rideId},
      );

      if (updateResult.isEmpty) {
        throw const AtomicRideBonusDecisionConflictException(
          AtomicRideBonusDecisionConflict.rideDispatchStateMismatch,
        );
      }
    });
  }

  @override
  Future<void> acceptFiveEuroBonus({required String rideId}) {
    return database.runTx((transaction) async {
      final rideRow = await _lockRide(transaction, rideId: rideId);

      _requirePendingUnassignedRide(rideRow);

      if (rideRow['dispatch_round'] != 1 ||
          rideRow['driver_bonus_minor'] != 0 ||
          rideRow['bonus_decision'] != 'awaiting_customer') {
        throw const AtomicRideBonusDecisionConflictException(
          AtomicRideBonusDecisionConflict.rideDispatchStateMismatch,
        );
      }

      await _requireNoPendingOffer(transaction, rideId: rideId);

      final updateResult = await transaction.execute(
        Sql.named('''
          UPDATE rides
          SET
            dispatch_round = 2,
            driver_bonus_minor = 500,
            bonus_decision = 'accepted'
          WHERE id = @rideId
            AND status = 'pending'
            AND assigned_driver_id IS NULL
            AND assigned_vehicle_id IS NULL
            AND dispatch_round = 1
            AND driver_bonus_minor = 0
            AND bonus_decision = 'awaiting_customer'
          RETURNING id
        '''),
        parameters: {'rideId': rideId},
      );

      if (updateResult.isEmpty) {
        throw const AtomicRideBonusDecisionConflictException(
          AtomicRideBonusDecisionConflict.rideDispatchStateMismatch,
        );
      }
    });
  }

  @override
  Future<void> declineBonusAndMoveToWaitingForVehicle({
    required String rideId,
  }) {
    return database.runTx((transaction) async {
      final rideRow = await _lockRide(transaction, rideId: rideId);

      _requirePendingUnassignedRide(rideRow);

      if (rideRow['dispatch_round'] != 1 ||
          rideRow['driver_bonus_minor'] != 0 ||
          rideRow['bonus_decision'] != 'awaiting_customer') {
        throw const AtomicRideBonusDecisionConflictException(
          AtomicRideBonusDecisionConflict.rideDispatchStateMismatch,
        );
      }

      await _requireNoPendingOffer(transaction, rideId: rideId);

      final updateResult = await transaction.execute(
        Sql.named('''
          UPDATE rides
          SET
            status = 'waitingForVehicle',
            bonus_decision = 'declined'
          WHERE id = @rideId
            AND status = 'pending'
            AND assigned_driver_id IS NULL
            AND assigned_vehicle_id IS NULL
            AND dispatch_round = 1
            AND driver_bonus_minor = 0
            AND bonus_decision = 'awaiting_customer'
          RETURNING id
        '''),
        parameters: {'rideId': rideId},
      );

      if (updateResult.isEmpty) {
        throw const AtomicRideBonusDecisionConflictException(
          AtomicRideBonusDecisionConflict.rideDispatchStateMismatch,
        );
      }
    });
  }

  Future<Map<String, dynamic>> _lockRide(
    Session transaction, {
    required String rideId,
  }) async {
    final result = await transaction.execute(
      Sql.named('''
        SELECT
          status,
          assigned_driver_id,
          assigned_vehicle_id,
          dispatch_round,
          driver_bonus_minor,
          bonus_decision
        FROM rides
        WHERE id = @rideId
        FOR UPDATE
      '''),
      parameters: {'rideId': rideId},
    );

    if (result.isEmpty) {
      throw const AtomicRideBonusDecisionConflictException(
        AtomicRideBonusDecisionConflict.rideNotFound,
      );
    }

    return result.first.toColumnMap();
  }

  void _requirePendingUnassignedRide(Map<String, dynamic> rideRow) {
    if (rideRow['status'] != 'pending') {
      throw const AtomicRideBonusDecisionConflictException(
        AtomicRideBonusDecisionConflict.rideNotPending,
      );
    }

    if (rideRow['assigned_driver_id'] != null ||
        rideRow['assigned_vehicle_id'] != null) {
      throw const AtomicRideBonusDecisionConflictException(
        AtomicRideBonusDecisionConflict.rideAlreadyAssigned,
      );
    }
  }

  Future<void> _requireNoPendingOffer(
    Session transaction, {
    required String rideId,
  }) async {
    final result = await transaction.execute(
      Sql.named('''
        SELECT 1
        FROM ride_offers
        WHERE ride_id = @rideId
          AND status = 'pending'
        LIMIT 1
      '''),
      parameters: {'rideId': rideId},
    );

    if (result.isNotEmpty) {
      throw const AtomicRideBonusDecisionConflictException(
        AtomicRideBonusDecisionConflict.rideHasPendingOffer,
      );
    }
  }
}
