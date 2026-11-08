import 'atomic_ride_offer_repository.dart';
import 'ride_offer.dart';
import 'ride_offer_repository.dart';
import 'driver_dispatch_policy_service.dart';
import '../ride/ride_request_repository.dart';
import 'atomic_driver_offer_rejection_service.dart';

typedef ContinueAutomaticDispatch = Future<RideOffer?> Function({
  required String rideId,
});

enum DriverRideOfferActionConflict { offerNotFound, offerDoesNotBelongToDriver }

class DriverRideOfferActionException implements Exception {
  final DriverRideOfferActionConflict conflict;

  const DriverRideOfferActionException(this.conflict);

  @override
  String toString() {
    return 'Driver ride offer action conflict: ${conflict.name}';
  }
}

class DriverRideOfferActionService {
  final RideOfferRepository offerRepository;
  final AtomicRideOfferRepository atomicOfferRepository;
  final RideRequestRepository rideRepository;
  final ContinueAutomaticDispatch continueRide;
  final DriverDispatchPolicyService dispatchPolicyService;
  final AtomicDriverOfferRejectionService? atomicRejectionService;
  final Future<void> Function({required String actionId})? processOutboxAction;

  const DriverRideOfferActionService({
    required this.offerRepository,
    required this.atomicOfferRepository,
    required this.rideRepository,
    required this.continueRide,
    required this.dispatchPolicyService,
    this.atomicRejectionService,
    this.processOutboxAction,
  });

  Future<RideOffer> accept({
    required String driverId,
    required String offerId,
    required DateTime now,
  }) async {
    await _requireOwnedOffer(driverId: driverId, offerId: offerId);

    return atomicOfferRepository.acceptPendingOffer(offerId: offerId, now: now);
  }

  Future<RideOffer> reject({
    required String driverId,
    required String offerId,
    required DateTime now,
  }) async {
    final offer = await _requireOwnedOffer(
      driverId: driverId,
      offerId: offerId,
    );
    final atomicRejection = atomicRejectionService;
    if (atomicRejection != null) {
      final result = await atomicRejection.reject(
        driverId: driverId,
        offerId: offerId,
      );
      final actionId = switch (result) {
        AtomicDriverOfferRejectionApplied(:final outboxRecord) =>
          outboxRecord.actionId,
        AtomicDriverOfferRejectionAlreadyRecorded(:final outboxRecord) =>
          outboxRecord.actionId,
        AtomicDriverOfferRejectionConflictResult(:final reason) =>
          switch (reason) {
            AtomicDriverOfferRejectionConflictReason.offerNotFound ||
            AtomicDriverOfferRejectionConflictReason
                .offerOwnedByAnotherDriver =>
              throw DriverRideOfferActionException(
                reason == AtomicDriverOfferRejectionConflictReason.offerNotFound
                    ? DriverRideOfferActionConflict.offerNotFound
                    : DriverRideOfferActionConflict.offerDoesNotBelongToDriver,
              ),
            _ => throw const AtomicRideOfferConflictException(
              AtomicRideOfferConflict.offerNotPending,
            ),
          },
      };
      await processOutboxAction?.call(actionId: actionId);
      final rejectedOffer = await offerRepository.findById(offerId);
      if (rejectedOffer == null) {
        throw StateError('Rejected offer could not be reloaded.');
      }
      return rejectedOffer;
    }

    final ride = await rideRepository.findById(offer.rideId);

    if (ride == null) {
      throw StateError(
        'Ride ${offer.rideId} for offer ${offer.id} was not found.',
      );
    }

    final rejectedOffer = await atomicOfferRepository.rejectPendingOffer(
      offerId: offerId,
      now: now,
    );
    if (DriverDispatchPolicyService.isOfferPenaltyEligible(
      requestedAt: ride.requestedAt,
      offeredAt: rejectedOffer.offeredAt,
    )) {
      if (rejectedOffer.dispatchRound == RideOffer.bonusDispatchRound) {
        await dispatchPolicyService.recordRejectedBonusOffer(
          driverId: driverId,
          now: now,
        );
      } else {
        await dispatchPolicyService.recordRejectedOffer(
          driverId: driverId,
          now: now,
        );
      }
    }

    await continueRide(rideId: rejectedOffer.rideId);

    return rejectedOffer;
  }

  Future<RideOffer> _requireOwnedOffer({
    required String driverId,
    required String offerId,
  }) async {
    final offer = await offerRepository.findById(offerId);

    if (offer == null) {
      throw const DriverRideOfferActionException(
        DriverRideOfferActionConflict.offerNotFound,
      );
    }

    if (offer.driverId != driverId) {
      throw const DriverRideOfferActionException(
        DriverRideOfferActionConflict.offerDoesNotBelongToDriver,
      );
    }

    return offer;
  }
}
