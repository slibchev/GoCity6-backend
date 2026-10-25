import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'driver_dispatch_policy_service.dart';
import 'driver_dispatch_state.dart';
import 'driver_offer_action_outbox_repository.dart';
import 'driver_offer_rejection_transaction.dart';
import 'ride_offer.dart';

enum DriverOfferRejectionPolicyOutcome {
  notEligible('not_eligible'),
  standardEligible('standard_eligible'),
  bonusEligible('bonus_eligible');

  const DriverOfferRejectionPolicyOutcome(this.databaseValue);

  final String databaseValue;
}

enum AtomicDriverOfferRejectionConflictReason {
  offerNotFound,
  offerOwnedByAnotherDriver,
  offerAlreadyProcessed,
  offerExpired,
  rideNotFound,
  driverShiftNotFound,
  vehicleDoesNotMatchShift,
  driverNotAvailable,
  driverPendingOfferMissing,
  offerActionConflict,
  idempotencyConflict,
  conflictUnresolved,
}

sealed class AtomicDriverOfferRejectionResult {
  const AtomicDriverOfferRejectionResult();
}

final class AtomicDriverOfferRejectionApplied
    extends AtomicDriverOfferRejectionResult {
  const AtomicDriverOfferRejectionApplied({
    required this.outboxRecord,
    required this.policyOutcome,
    required this.dispatchState,
  });

  final DriverOfferActionOutboxRecord outboxRecord;
  final DriverOfferRejectionPolicyOutcome policyOutcome;
  final DriverDispatchState? dispatchState;
}

final class AtomicDriverOfferRejectionAlreadyRecorded
    extends AtomicDriverOfferRejectionResult {
  const AtomicDriverOfferRejectionAlreadyRecorded(this.outboxRecord);

  final DriverOfferActionOutboxRecord outboxRecord;
}

final class AtomicDriverOfferRejectionConflictResult
    extends AtomicDriverOfferRejectionResult {
  const AtomicDriverOfferRejectionConflictResult(this.reason);

  final AtomicDriverOfferRejectionConflictReason reason;
}

/// A transaction-aware, opt-in path for explicit offer rejection.
///
/// This service is intentionally not wired into the current HTTP routes. The
/// [reject] method owns exactly one transaction through the injected runner.
class AtomicDriverOfferRejectionService {
  AtomicDriverOfferRejectionService({
    required this.transactionRunner,
    DateTime Function()? clock,
    String Function()? actionIdFactory,
  }) : clock = clock ?? DateTime.now,
       actionIdFactory = actionIdFactory ?? const Uuid().v4;

  final DriverOfferRejectionTransactionRunner transactionRunner;
  final DateTime Function() clock;
  final String Function() actionIdFactory;

  Future<AtomicDriverOfferRejectionResult> reject({
    required String driverId,
    required String offerId,
    String? idempotencyKey,
  }) async {
    _validateRequest(
      driverId: driverId,
      offerId: offerId,
      idempotencyKey: idempotencyKey,
    );
    try {
      return await transactionRunner.run(
        (transaction) => rejectInTransaction(
          transaction: transaction,
          driverId: driverId,
          offerId: offerId,
          idempotencyKey: idempotencyKey,
        ),
      );
    } on _RollbackWithResult catch (rollback) {
      return rollback.result;
    }
  }

  /// Performs the operation inside a transaction supplied by the caller.
  ///
  /// A [DriverOfferActionInsertResult] conflict discovered after writes causes
  /// a private exception to escape so the surrounding transaction rolls back.
  /// Callers must not swallow that exception inside their transaction.
  Future<AtomicDriverOfferRejectionResult> rejectInTransaction({
    required DriverOfferRejectionTransaction transaction,
    required String driverId,
    required String offerId,
    String? idempotencyKey,
  }) async {
    _validateRequest(
      driverId: driverId,
      offerId: offerId,
      idempotencyKey: idempotencyKey,
    );
    // Lock order: offer -> active shift/queue -> dispatch state -> outbox
    // uniqueness checks. This matches the existing accept/reject/expiry paths
    // for the rows they share and avoids locking the ride row for a read-only
    // requested_at lookup.
    final offer = await transaction.lockOffer(offerId);
    if (offer == null) {
      return const AtomicDriverOfferRejectionConflictResult(
        AtomicDriverOfferRejectionConflictReason.offerNotFound,
      );
    }
    if (offer.driverId != driverId) {
      return const AtomicDriverOfferRejectionConflictResult(
        AtomicDriverOfferRejectionConflictReason.offerOwnedByAnotherDriver,
      );
    }

    final requestedAt = await transaction.findRideRequestedAt(offer.rideId);
    if (requestedAt == null) {
      return const AtomicDriverOfferRejectionConflictResult(
        AtomicDriverOfferRejectionConflictReason.rideNotFound,
      );
    }

    final requestHash = requestHashForReject(
      driverId: driverId,
      offerId: offerId,
    );
    final existingForOffer = await transaction.findActionForDriver(
      offerId: offerId,
      driverId: driverId,
    );
    if (existingForOffer != null) {
      if (_matchesRequest(
        existingForOffer,
        driverId: driverId,
        offerId: offerId,
        idempotencyKey: idempotencyKey,
        requestHash: requestHash,
      )) {
        return AtomicDriverOfferRejectionAlreadyRecorded(existingForOffer);
      }
      return const AtomicDriverOfferRejectionConflictResult(
        AtomicDriverOfferRejectionConflictReason.offerActionConflict,
      );
    }

    if (idempotencyKey != null) {
      final existingForKey = await transaction.findActionByIdempotencyKey(
        driverId: driverId,
        idempotencyKey: idempotencyKey,
      );
      if (existingForKey != null) {
        if (_matchesRequest(
          existingForKey,
          driverId: driverId,
          offerId: offerId,
          idempotencyKey: idempotencyKey,
          requestHash: requestHash,
        )) {
          return AtomicDriverOfferRejectionAlreadyRecorded(existingForKey);
        }
        return const AtomicDriverOfferRejectionConflictResult(
          AtomicDriverOfferRejectionConflictReason.idempotencyConflict,
        );
      }
    }

    if (offer.status != RideOfferStatus.pending) {
      return const AtomicDriverOfferRejectionConflictResult(
        AtomicDriverOfferRejectionConflictReason.offerAlreadyProcessed,
      );
    }

    if (!clock().toUtc().isBefore(offer.expiresAt.toUtc())) {
      return const AtomicDriverOfferRejectionConflictResult(
        AtomicDriverOfferRejectionConflictReason.offerExpired,
      );
    }

    final queue = await transaction.lockActiveQueue(driverId);
    if (queue == null) {
      return const AtomicDriverOfferRejectionConflictResult(
        AtomicDriverOfferRejectionConflictReason.driverShiftNotFound,
      );
    }
    if (queue.vehicleId != offer.vehicleId) {
      return const AtomicDriverOfferRejectionConflictResult(
        AtomicDriverOfferRejectionConflictReason.vehicleDoesNotMatchShift,
      );
    }
    if (queue.availability != 'available') {
      return const AtomicDriverOfferRejectionConflictResult(
        AtomicDriverOfferRejectionConflictReason.driverNotAvailable,
      );
    }
    if (!queue.hasPendingOffer) {
      return const AtomicDriverOfferRejectionConflictResult(
        AtomicDriverOfferRejectionConflictReason.driverPendingOfferMissing,
      );
    }

    // Read the time only after obtaining the offer and queue locks so waiting
    // for contention cannot make an already-expired offer look actionable.
    final rejectedAt = clock().toUtc();
    if (!rejectedAt.isBefore(offer.expiresAt.toUtc())) {
      return const AtomicDriverOfferRejectionConflictResult(
        AtomicDriverOfferRejectionConflictReason.offerExpired,
      );
    }

    final eligible = DriverDispatchPolicyService.isOfferPenaltyEligible(
      requestedAt: requestedAt,
      offeredAt: offer.offeredAt,
    );
    final policyOutcome = !eligible
        ? DriverOfferRejectionPolicyOutcome.notEligible
        : offer.dispatchRound == RideOffer.bonusDispatchRound
        ? DriverOfferRejectionPolicyOutcome.bonusEligible
        : DriverOfferRejectionPolicyOutcome.standardEligible;

    if (!await transaction.rejectPendingOffer(
      offerId: offerId,
      driverId: driverId,
      rejectedAt: rejectedAt,
    )) {
      throw StateError('Locked pending offer could not be rejected.');
    }
    if (!await transaction.releaseQueue(
      shiftId: queue.shiftId,
      queuePrioritySince: rejectedAt,
    )) {
      throw StateError('Locked driver queue could not be released.');
    }

    DriverDispatchState? nextDispatchState;
    if (eligible) {
      nextDispatchState = await transaction.updateDispatchState(
        driverId: driverId,
        transform: (current) =>
            offer.dispatchRound == RideOffer.bonusDispatchRound
            ? DriverDispatchPolicyService.afterBonusOfferRejection(
                current: current,
                rejectedAt: rejectedAt,
              )
            : DriverDispatchPolicyService.afterStandardOfferRejection(
                current: current,
                rejectedAt: rejectedAt,
              ),
      );
    }

    final outboxRecord = DriverOfferActionOutboxRecord(
      actionId: actionIdFactory(),
      offerId: offerId,
      driverId: driverId,
      action: DriverOfferAction.reject,
      idempotencyKey: idempotencyKey,
      requestHash: requestHash,
      policyOutcome: policyOutcome.databaseValue,
      redispatchStatus: DriverOfferRedispatchStatus.queued,
      attemptCount: 0,
      availableAt: rejectedAt,
      leaseToken: null,
      leaseUntil: null,
      lastErrorCode: null,
      redispatchResult: null,
      createdAt: rejectedAt,
      settledAt: rejectedAt,
      updatedAt: rejectedAt,
      redispatchCompletedAt: null,
    );

    final insertResult = await transaction.insertAction(outboxRecord);
    if (insertResult case DriverOfferActionInserted(:final record)) {
      return AtomicDriverOfferRejectionApplied(
        outboxRecord: record,
        policyOutcome: policyOutcome,
        dispatchState: nextDispatchState,
      );
    }

    if (insertResult case DriverOfferActionAlreadyExists(:final record)) {
      throw _RollbackWithResult(
        AtomicDriverOfferRejectionAlreadyRecorded(record),
      );
    }
    if (insertResult is DriverOfferActionIdempotencyConflict) {
      throw const _RollbackWithResult(
        AtomicDriverOfferRejectionConflictResult(
          AtomicDriverOfferRejectionConflictReason.idempotencyConflict,
        ),
      );
    }
    if (insertResult is DriverOfferActionOfferConflict) {
      throw const _RollbackWithResult(
        AtomicDriverOfferRejectionConflictResult(
          AtomicDriverOfferRejectionConflictReason.offerActionConflict,
        ),
      );
    }
    if (insertResult is DriverOfferActionConflictUnresolved) {
      throw const _RollbackWithResult(
        AtomicDriverOfferRejectionConflictResult(
          AtomicDriverOfferRejectionConflictReason.conflictUnresolved,
        ),
      );
    }
    throw StateError('Unexpected offer action insert result.');
  }

  /// Version 1 canonical semantic payload for a reject action.
  ///
  /// The fixed key order and JSON escaping are part of the persisted hash
  /// contract. JWTs, timestamps, queue state, and policy decisions are omitted.
  static String requestHashForReject({
    required String driverId,
    required String offerId,
  }) {
    final canonical =
        '{"version":1,"action":"reject",'
        '"driverId":${jsonEncode(driverId)},'
        '"offerId":${jsonEncode(offerId)}}';
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  static bool _matchesRequest(
    DriverOfferActionOutboxRecord record, {
    required String driverId,
    required String offerId,
    required String? idempotencyKey,
    required String requestHash,
  }) =>
      record.driverId == driverId &&
      record.offerId == offerId &&
      record.action == DriverOfferAction.reject &&
      record.idempotencyKey == idempotencyKey &&
      record.requestHash == requestHash;

  static void _validateRequest({
    required String driverId,
    required String offerId,
    required String? idempotencyKey,
  }) {
    if (driverId.isEmpty || offerId.isEmpty) {
      throw ArgumentError('Driver and offer IDs must be non-empty.');
    }
    if (idempotencyKey != null &&
        (idempotencyKey.trim() != idempotencyKey ||
            idempotencyKey.runes.length > 200 ||
            idempotencyKey.isEmpty)) {
      throw ArgumentError('Invalid idempotency key.');
    }
  }
}

final class _RollbackWithResult implements Exception {
  const _RollbackWithResult(this.result);

  final AtomicDriverOfferRejectionResult result;
}
