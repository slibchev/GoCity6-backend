import 'automatic_dispatch_redispatch_service.dart';
import 'driver_offer_action_outbox_repository.dart';
import 'driver_offer_action_outbox_worker.dart';
import 'driver_offer_action_outbox_worker_repository.dart';
import 'ride_offer.dart';
import 'ride_offer_repository.dart';

enum DriverOfferRedispatchInvariant {
  actionNotContinuation,
  missingLease,
  originalOfferNotFound,
  offerIdentityMismatch,
  ownerMismatch,
  originalOfferStatusMismatch,
  resultRideMismatch,
  resultSourceMismatch,
}

/// Safe invariant failure. The action and offer identifiers are omitted from
/// its diagnostic text; the worker stores only its predefined error code.
final class DriverOfferRedispatchInvariantException implements Exception {
  const DriverOfferRedispatchInvariantException(this.invariant);

  final DriverOfferRedispatchInvariant invariant;

  @override
  String toString() => 'Driver offer redispatch invariant failed.';
}

/// Executes normal dispatch continuation for one leased reject, timeout, or
/// initial-dispatch action. Waiting-board offers use the existing scanner.
final class AutomaticDispatchRedispatchExecutor
    implements DriverOfferRedispatchExecutor {
  const AutomaticDispatchRedispatchExecutor({
    required this.offerRepository,
    required this.redispatchService,
    this.settleTimedOutOffer,
    this.dispatchWaitingBoard,
  });

  final RideOfferRepository offerRepository;
  final AutomaticDispatchRedispatcher redispatchService;
  final Future<bool> Function(String offerId)? settleTimedOutOffer;
  final Future<void> Function()? dispatchWaitingBoard;

  @override
  Future<DriverOfferRedispatchExecutionResult> execute(
    DriverOfferActionOutboxRecord action,
  ) async {
    if (action.action != DriverOfferAction.reject &&
        action.action != DriverOfferAction.timeout &&
        action.action != DriverOfferAction.initialDispatch) {
      throw const DriverOfferRedispatchInvariantException(
        DriverOfferRedispatchInvariant.actionNotContinuation,
      );
    }

    final leaseToken = action.leaseToken;
    if (action.redispatchStatus != DriverOfferRedispatchStatus.leased ||
        leaseToken == null ||
        leaseToken.isEmpty) {
      throw const DriverOfferRedispatchInvariantException(
        DriverOfferRedispatchInvariant.missingLease,
      );
    }

    RideOffer? sourceOffer;
    if (action.action != DriverOfferAction.initialDispatch) {
      final offerId = action.offerId;
      final driverId = action.driverId;
      if (offerId == null || driverId == null) {
        throw const DriverOfferRedispatchInvariantException(
          DriverOfferRedispatchInvariant.originalOfferNotFound,
        );
      }
      sourceOffer = await offerRepository.findById(offerId);
      if (sourceOffer == null) {
        throw const DriverOfferRedispatchInvariantException(
          DriverOfferRedispatchInvariant.originalOfferNotFound,
        );
      }
      if (sourceOffer.id != offerId) {
        throw const DriverOfferRedispatchInvariantException(
          DriverOfferRedispatchInvariant.offerIdentityMismatch,
        );
      }
      if (sourceOffer.driverId != driverId) {
        throw const DriverOfferRedispatchInvariantException(
          DriverOfferRedispatchInvariant.ownerMismatch,
        );
      }
      final expectedStatus = action.action == DriverOfferAction.reject
          ? RideOfferStatus.rejected
          : RideOfferStatus.expired;
      if (sourceOffer.status != expectedStatus) {
        throw const DriverOfferRedispatchInvariantException(
          DriverOfferRedispatchInvariant.originalOfferStatusMismatch,
        );
      }
      if (action.action == DriverOfferAction.timeout) {
        final settle = settleTimedOutOffer;
        if (settle == null) {
          return const DriverOfferRedispatchPermanentFailure(
            errorCode: DriverOfferActionOutboxErrorCode.dependencyUnavailable,
          );
        }
        await settle(sourceOffer.id);
      }
      if (sourceOffer.source == RideOfferSource.waitingBoard) {
        final dispatch = dispatchWaitingBoard;
        if (dispatch == null) {
          return const DriverOfferRedispatchTemporaryFailure(
            errorCode: DriverOfferActionOutboxErrorCode.dependencyUnavailable,
          );
        }
        await dispatch();
        return const DriverOfferRedispatchConfirmed();
      }
      if (sourceOffer.source != RideOfferSource.automatic) {
        return const DriverOfferRedispatchPermanentFailure(
          errorCode: DriverOfferActionOutboxErrorCode.unsupportedOfferSource,
        );
      }
    }

    final result = await redispatchService.redispatch(
      rideId: action.rideId,
      actionId: action.actionId,
      leaseToken: leaseToken,
    );

    return switch (result) {
      AutomaticDispatchRedispatchCreated(:final offer) ||
      AutomaticDispatchRedispatchAlreadyProgressed(
        :final offer,
      ) => _confirmPersistedOffer(offer, action.rideId),
      AutomaticDispatchRedispatchAdvanced() =>
        const DriverOfferRedispatchConfirmed(),
      AutomaticDispatchRedispatchNoEligibleDriver() =>
        const DriverOfferRedispatchTemporaryFailure(
          errorCode: DriverOfferActionOutboxErrorCode.noEligibleDriver,
        ),
    };
  }

  DriverOfferRedispatchExecutionResult _confirmPersistedOffer(
    RideOffer redispatchedOffer,
    String rideId,
  ) {
    if (redispatchedOffer.rideId != rideId) {
      throw const DriverOfferRedispatchInvariantException(
        DriverOfferRedispatchInvariant.resultRideMismatch,
      );
    }
    if (redispatchedOffer.source != RideOfferSource.automatic) {
      throw const DriverOfferRedispatchInvariantException(
        DriverOfferRedispatchInvariant.resultSourceMismatch,
      );
    }
    return const DriverOfferRedispatchConfirmed();
  }
}
