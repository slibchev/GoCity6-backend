import 'automatic_dispatch_redispatch_service.dart';
import 'driver_offer_action_outbox_repository.dart';
import 'driver_offer_action_outbox_worker.dart';
import 'driver_offer_action_outbox_worker_repository.dart';
import 'ride_offer.dart';
import 'ride_offer_repository.dart';

enum DriverOfferRedispatchInvariant {
  actionNotReject,
  missingLease,
  originalOfferNotFound,
  offerIdentityMismatch,
  ownerMismatch,
  originalOfferNotRejected,
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

/// Executes the supported normal automatic redispatch path for one leased
/// reject action. Waiting-board offers are left for a dedicated continuation.
final class AutomaticDispatchRedispatchExecutor
    implements DriverOfferRedispatchExecutor {
  const AutomaticDispatchRedispatchExecutor({
    required this.offerRepository,
    required this.redispatchService,
  });

  final RideOfferRepository offerRepository;
  final AutomaticDispatchRedispatcher redispatchService;

  @override
  Future<DriverOfferRedispatchExecutionResult> execute(
    DriverOfferActionOutboxRecord action,
  ) async {
    if (action.action != DriverOfferAction.reject) {
      throw const DriverOfferRedispatchInvariantException(
        DriverOfferRedispatchInvariant.actionNotReject,
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

    final originalOffer = await offerRepository.findById(action.offerId);
    if (originalOffer == null) {
      throw const DriverOfferRedispatchInvariantException(
        DriverOfferRedispatchInvariant.originalOfferNotFound,
      );
    }
    if (originalOffer.id != action.offerId) {
      throw const DriverOfferRedispatchInvariantException(
        DriverOfferRedispatchInvariant.offerIdentityMismatch,
      );
    }
    if (originalOffer.driverId != action.driverId) {
      throw const DriverOfferRedispatchInvariantException(
        DriverOfferRedispatchInvariant.ownerMismatch,
      );
    }
    if (originalOffer.status != RideOfferStatus.rejected) {
      throw const DriverOfferRedispatchInvariantException(
        DriverOfferRedispatchInvariant.originalOfferNotRejected,
      );
    }
    if (originalOffer.source == RideOfferSource.waitingBoard) {
      return const DriverOfferRedispatchPermanentFailure(
        errorCode: DriverOfferActionOutboxErrorCode.unsupportedOfferSource,
      );
    }
    if (originalOffer.source != RideOfferSource.automatic) {
      return const DriverOfferRedispatchPermanentFailure(
        errorCode: DriverOfferActionOutboxErrorCode.unsupportedOfferSource,
      );
    }

    final result = await redispatchService.redispatch(
      rideId: originalOffer.rideId,
      actionId: action.actionId,
      leaseToken: leaseToken,
    );

    return switch (result) {
      AutomaticDispatchRedispatchCreated(:final offer) ||
      AutomaticDispatchRedispatchAlreadyProgressed(
        :final offer,
      ) => _confirmPersistedOffer(offer, originalOffer),
      AutomaticDispatchRedispatchNoEligibleDriver() =>
        const DriverOfferRedispatchTemporaryFailure(
          errorCode: DriverOfferActionOutboxErrorCode.noEligibleDriver,
        ),
    };
  }

  DriverOfferRedispatchExecutionResult _confirmPersistedOffer(
    RideOffer redispatchedOffer,
    RideOffer originalOffer,
  ) {
    if (redispatchedOffer.rideId != originalOffer.rideId) {
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
