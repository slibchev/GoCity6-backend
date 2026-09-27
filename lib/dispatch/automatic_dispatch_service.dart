import 'dispatch_candidate.dart';
import 'dispatch_candidate_selector.dart';
import 'dispatch_policy.dart';
import 'driver_queue_state.dart';
import 'ride_offer.dart';
import 'ride_offer_history.dart';

enum AutomaticDispatchConflict {
  pendingOfferExists,
  rideAlreadyAccepted,
  driverStateMissing,
}

class AutomaticDispatchConflictException implements Exception {
  final AutomaticDispatchConflict conflict;

  const AutomaticDispatchConflictException(this.conflict);

  @override
  String toString() {
    return 'Automatic dispatch conflict: ${conflict.name}';
  }
}

class AutomaticDispatchResult {
  final RideOffer offer;
  final DriverQueueState driverState;
  final RideOfferHistory history;

  const AutomaticDispatchResult({
    required this.offer,
    required this.driverState,
    required this.history,
  });
}

class AutomaticDispatchService {
  final DispatchCandidateSelector? selector;
  final DispatchPolicy policy;

  const AutomaticDispatchService({
    this.policy = const DispatchPolicy(),
    this.selector,
  });

  AutomaticDispatchResult? createNextOffer({
    required String rideId,
    required String offerId,
    required DateTime now,
    required List<DispatchCandidate> candidates,
    required Map<String, DriverQueueState> driverStates,
    required RideOfferHistory history,
  }) {
    if (history.rideId != rideId) {
      throw ArgumentError('Offer history does not belong to ride $rideId.');
    }

    if (history.hasPendingOffer) {
      throw const AutomaticDispatchConflictException(
        AutomaticDispatchConflict.pendingOfferExists,
      );
    }

    if (history.hasAcceptedOffer) {
      throw const AutomaticDispatchConflictException(
        AutomaticDispatchConflict.rideAlreadyAccepted,
      );
    }

    final remainingCandidates = candidates
        .where((candidate) => history.canOfferDriver(candidate.driverId))
        .toList();

    final effectiveSelector =
        selector ?? DispatchCandidateSelector(policy: policy);
    final selectedCandidate = effectiveSelector.select(remainingCandidates);

    if (selectedCandidate == null) {
      return null;
    }

    final driverState = driverStates[selectedCandidate.driverId];

    if (driverState == null) {
      throw const AutomaticDispatchConflictException(
        AutomaticDispatchConflict.driverStateMissing,
      );
    }

    final updatedDriverState = driverState.beginOffer();

    final offer = RideOffer.create(
      id: offerId,
      rideId: rideId,
      driverId: selectedCandidate.driverId,
      vehicleId: selectedCandidate.vehicleId,
      etaSeconds: selectedCandidate.etaSeconds,
      distanceMeters: selectedCandidate.distanceMeters,
      offeredAt: now,
      timeout: policy.offerTimeout,
    );

    final updatedHistory = history.addOffer(offer);

    return AutomaticDispatchResult(
      offer: offer,
      driverState: updatedDriverState,
      history: updatedHistory,
    );
  }

  AutomaticDispatchResult acceptOffer({
    required RideOffer offer,
    required DateTime now,
    required DriverQueueState driverState,
    required RideOfferHistory history,
  }) {
    final acceptedOffer = offer.accept(now);

    final updatedDriverState = driverState.acceptOffer();

    final updatedHistory = history.replaceOffer(acceptedOffer);

    return AutomaticDispatchResult(
      offer: acceptedOffer,
      driverState: updatedDriverState,
      history: updatedHistory,
    );
  }

  AutomaticDispatchResult rejectOffer({
    required RideOffer offer,
    required DateTime now,
    required DriverQueueState driverState,
    required RideOfferHistory history,
  }) {
    final rejectedOffer = offer.reject(now);

    final updatedDriverState = driverState.rejectOffer(now);

    final updatedHistory = history.replaceOffer(rejectedOffer);

    return AutomaticDispatchResult(
      offer: rejectedOffer,
      driverState: updatedDriverState,
      history: updatedHistory,
    );
  }

  AutomaticDispatchResult expireOffer({
    required RideOffer offer,
    required DateTime now,
    required DriverQueueState driverState,
    required RideOfferHistory history,
  }) {
    final expiredOffer = offer.expire(now);

    final updatedDriverState = driverState.expireOffer(now);

    final updatedHistory = history.replaceOffer(expiredOffer);

    return AutomaticDispatchResult(
      offer: expiredOffer,
      driverState: updatedDriverState,
      history: updatedHistory,
    );
  }
}
