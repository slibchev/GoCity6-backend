import '../ride/ride_request.dart';
import '../ride/ride_request_status.dart';
import 'atomic_ride_offer_repository.dart';
import 'automatic_dispatch_service.dart';
import 'dispatch_candidate_service.dart';
import 'idempotent_automatic_redispatch_repository.dart';
import 'ride_offer.dart';
import 'ride_offer_history.dart';
import 'ride_offer_repository.dart';

class AutomaticDispatchOrchestrator {
  final DispatchCandidateService candidateService;
  final RideOfferRepository offerRepository;
  final AtomicRideOfferRepository atomicOfferRepository;
  final AutomaticDispatchService dispatchService;

  const AutomaticDispatchOrchestrator({
    required this.candidateService,
    required this.offerRepository,
    required this.atomicOfferRepository,
    this.dispatchService = const AutomaticDispatchService(),
  });

  Future<RideOffer?> createNextOffer({
    required RideRequest ride,
    required String offerId,
    required DateTime now,
  }) async {
    return _createNextOffer(
      ride: ride,
      offerId: offerId,
      now: now,
      requiredStatus: RideRequestStatus.pending,
      source: RideOfferSource.automatic,
    );
  }

  /// Creates the next normal automatic offer for one durable reject action.
  ///
  /// Routing and candidate selection complete before the repository starts
  /// its transaction. The repository atomically writes the offer's causal
  /// action id and queue update, and serializes duplicate attempts.
  Future<IdempotentAutomaticRedispatchPersistenceResult?>
  createNextOfferForRedispatch({
    required RideRequest ride,
    required String offerId,
    required DateTime now,
    required String actionId,
    required String leaseToken,
    required IdempotentAutomaticRedispatchOfferRepository
    redispatchOfferRepository,
  }) async {
    if (ride.status != RideRequestStatus.pending) {
      throw ArgumentError.value(
        ride.status,
        'ride.status',
        'Automatic redispatch requires a pending ride.',
      );
    }

    final nowUtc = now.toUtc();
    final existingOffers = await offerRepository.findByRideId(ride.id);
    final history = RideOfferHistory(rideId: ride.id, offers: existingOffers);
    final batch = await candidateService.buildBatchForRide(
      ride: ride,
      now: nowUtc,
    );
    final result = dispatchService.createNextOffer(
      rideId: ride.id,
      offerId: offerId,
      now: nowUtc,
      candidates: batch.candidates,
      driverStates: batch.driverStates,
      history: history,
      dispatchRound: ride.dispatchRound,
      bonusMinor: ride.driverBonusMinor,
      source: RideOfferSource.automatic,
    );

    if (result == null) {
      return null;
    }

    return redispatchOfferRepository.createPendingOfferForRedispatch(
      offer: result.offer,
      actionId: actionId,
      leaseToken: leaseToken,
    );
  }

  Future<RideOffer?> createNextWaitingBoardOffer({
    required RideRequest ride,
    required String offerId,
    required DateTime now,
  }) {
    return _createNextOffer(
      ride: ride,
      offerId: offerId,
      now: now,
      requiredStatus: RideRequestStatus.waitingForVehicle,
      source: RideOfferSource.waitingBoard,
    );
  }

  Future<RideOffer?> createNextWaitingBoardOfferFromPool({
    required RideRequest ride,
    required String offerId,
    required DateTime now,
    DateTime Function()? offerTime,
    required DispatchCandidatePool candidatePool,
  }) async {
    if (ride.status != RideRequestStatus.waitingForVehicle) {
      throw ArgumentError.value(
        ride.status,
        'ride.status',
        'Waiting-board dispatch requires a waiting ride.',
      );
    }

    final nowUtc = now.toUtc();
    final history = RideOfferHistory(
      rideId: ride.id,
      offers: await offerRepository.findByRideId(ride.id),
    );
    var pool = candidatePool;

    while (!pool.isEmpty) {
      final batch = await candidateService.buildBatchForRide(
        ride: ride,
        now: nowUtc,
        pool: pool,
      );
      final result = dispatchService.createNextOffer(
        rideId: ride.id,
        offerId: offerId,
        // Route estimation happens before this point. Start the driver's
        // response window only after that potentially slow work is complete.
        now: (offerTime?.call() ?? nowUtc).toUtc(),
        candidates: batch.candidates,
        driverStates: batch.driverStates,
        history: history,
        dispatchRound: ride.dispatchRound,
        bonusMinor: ride.driverBonusMinor,
        source: RideOfferSource.waitingBoard,
      );

      if (result == null) {
        return null;
      }

      try {
        return await atomicOfferRepository.createPendingOffer(
          offer: result.offer,
        );
      } on AtomicRideOfferConflictException catch (error) {
        switch (error.conflict) {
          case AtomicRideOfferConflict.driverShiftNotFound:
          case AtomicRideOfferConflict.vehicleDoesNotMatchShift:
          case AtomicRideOfferConflict.driverNotAvailable:
          case AtomicRideOfferConflict.driverLocationStale:
          case AtomicRideOfferConflict.driverAlreadyHasPendingOffer:
          case AtomicRideOfferConflict.rideAlreadyOfferedToDriver:
            pool = pool.withoutDriver(result.offer.driverId);
            continue;

          case AtomicRideOfferConflict.rideNotFound:
          case AtomicRideOfferConflict.rideNotPending:
          case AtomicRideOfferConflict.rideNotWaitingForVehicle:
          case AtomicRideOfferConflict.rideTooOld:
          case AtomicRideOfferConflict.rideAlreadyAssigned:
          case AtomicRideOfferConflict.rideDispatchStateMismatch:
          case AtomicRideOfferConflict.rideHasPendingOffer:
          case AtomicRideOfferConflict.offerNotFound:
          case AtomicRideOfferConflict.offerNotPending:
          case AtomicRideOfferConflict.offerAlreadyExpired:
          case AtomicRideOfferConflict.offerNotExpiredYet:
          case AtomicRideOfferConflict.driverPendingOfferMissing:
          case AtomicRideOfferConflict.rideAlreadyHasPendingOffer:
            rethrow;
        }
      }
    }

    return null;
  }

  Future<RideOffer?> _createNextOffer({
    required RideRequest ride,
    required String offerId,
    required DateTime now,
    required RideRequestStatus requiredStatus,
    required RideOfferSource source,
  }) async {
    if (ride.status != requiredStatus) {
      throw ArgumentError.value(
        ride.status,
        'ride.status',
        'Automatic dispatch requires status ${requiredStatus.name}.',
      );
    }

    final nowUtc = now.toUtc();

    final existingOffers = await offerRepository.findByRideId(ride.id);

    final history = RideOfferHistory(rideId: ride.id, offers: existingOffers);

    final batch = await candidateService.buildBatchForRide(
      ride: ride,
      now: nowUtc,
    );

    final result = dispatchService.createNextOffer(
      rideId: ride.id,
      offerId: offerId,
      now: nowUtc,
      candidates: batch.candidates,
      driverStates: batch.driverStates,
      history: history,
      dispatchRound: ride.dispatchRound,
      bonusMinor: ride.driverBonusMinor,
      source: source,
    );

    if (result == null) {
      return null;
    }

    return atomicOfferRepository.createPendingOffer(offer: result.offer);
  }
}
