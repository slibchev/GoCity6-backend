import '../ride/ride_request.dart';
import '../ride/ride_request_status.dart';
import '../geography/district_matcher.dart';
import '../routing/route_estimator.dart';
import 'atomic_ride_offer_repository.dart';
import 'automatic_dispatch_service.dart';
import 'dispatch_candidate_service.dart';
import 'driver_district_queue.dart';
import 'idempotent_automatic_redispatch_repository.dart';
import 'ride_offer.dart';
import 'ride_offer_history.dart';
import 'ride_offer_repository.dart';

typedef FindDistrictDispatchCandidates =
    Future<List<DriverDistrictQueueCandidate>> Function({
      required int districtObjectId,
      required DateTime now,
    });

class AutomaticDispatchOrchestrator {
  final DispatchCandidateService candidateService;
  final RideOfferRepository offerRepository;
  final AtomicRideOfferRepository atomicOfferRepository;
  final AutomaticDispatchService dispatchService;
  final DistrictMatcher? districtMatcher;
  final FindDistrictDispatchCandidates? findDistrictCandidates;
  final DateTime Function()? currentTime;

  const AutomaticDispatchOrchestrator({
    required this.candidateService,
    required this.offerRepository,
    required this.atomicOfferRepository,
    this.dispatchService = const AutomaticDispatchService(),
    this.districtMatcher,
    this.findDistrictCandidates,
    this.currentTime,
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

    if (_districtFifoIsConfigured) {
      IdempotentAutomaticRedispatchPersistenceResult? persistedResult;
      await _createDistrictFifoOffer(
        ride: ride,
        offerId: offerId,
        now: nowUtc,
        history: history,
        source: RideOfferSource.automatic,
        persist: (offer) async {
          final result = await redispatchOfferRepository
              .createPendingOfferForRedispatch(
                offer: offer,
                actionId: actionId,
                leaseToken: leaseToken,
              );
          persistedResult = result;
          return switch (result) {
            AutomaticRedispatchOfferCreated(:final offer) => offer,
            AutomaticRedispatchAlreadyProgressed(:final offer) => offer,
          };
        },
      );
      return persistedResult;
    }

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
    return _createNextWaitingBoardOffer(ride: ride, offerId: offerId, now: now);
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

    if (candidatePool.isEmpty) return null;

    return _createNextWaitingBoardOffer(
      ride: ride,
      offerId: offerId,
      now: now,
      offerTime: offerTime,
      eligibleDriverIds: {
        for (final entry in candidatePool.entries) entry.shift.driverId,
      },
    );
  }

  Future<RideOffer?> _createNextWaitingBoardOffer({
    required RideRequest ride,
    required String offerId,
    required DateTime now,
    DateTime Function()? offerTime,
    Set<String>? eligibleDriverIds,
  }) async {
    if (ride.status != RideRequestStatus.waitingForVehicle) {
      throw ArgumentError.value(
        ride.status,
        'ride.status',
        'Waiting-board dispatch requires a waiting ride.',
      );
    }

    // If pickup cannot be matched to the approved map, or the district queue
    // is unavailable, leave the ride for manual selection. Never fall back to
    // the global ETA pool for automatic waiting-board offers.
    if (!_districtFifoIsConfigured) return null;

    final nowUtc = now.toUtc();
    final history = RideOfferHistory(
      rideId: ride.id,
      offers: await offerRepository.findByRideId(ride.id),
    );
    return _createDistrictFifoOffer(
      ride: ride,
      offerId: offerId,
      now: nowUtc,
      history: history,
      source: RideOfferSource.waitingBoard,
      offerTime: offerTime,
      eligibleDriverIds: eligibleDriverIds,
      persist: (offer) =>
          atomicOfferRepository.createPendingOffer(offer: offer),
    );
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

    if (source == RideOfferSource.automatic &&
        requiredStatus == RideRequestStatus.pending &&
        _districtFifoIsConfigured) {
      return _createDistrictFifoOffer(
        ride: ride,
        offerId: offerId,
        now: nowUtc,
        history: history,
        source: source,
        persist: (offer) =>
            atomicOfferRepository.createPendingOffer(offer: offer),
      );
    }

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

  bool get _districtFifoIsConfigured =>
      districtMatcher != null && findDistrictCandidates != null;

  Future<RideOffer?> _createDistrictFifoOffer({
    required RideRequest ride,
    required String offerId,
    required DateTime now,
    required RideOfferHistory history,
    required RideOfferSource source,
    DateTime Function()? offerTime,
    Set<String>? eligibleDriverIds,
    required Future<RideOffer> Function(RideOffer offer) persist,
  }) async {
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

    final latitude = ride.pickupLatitude;
    final longitude = ride.pickupLongitude;
    if (latitude == null || longitude == null) return null;

    DistrictMatch? pickupMatch;
    try {
      pickupMatch = districtMatcher!.match(
        latitude: latitude,
        longitude: longitude,
      );
    } on ArgumentError {
      // Invalid or incomplete pickup coordinates cannot establish a district.
      // Do not guess a district for automatic dispatch.
      return null;
    }
    if (pickupMatch == null ||
        pickupMatch.resolution == DistrictMatchResolution.overlapTieBreak) {
      // Unknown or overlapping pickup locations are left for manual selection.
      return null;
    }

    final candidates =
        (await findDistrictCandidates!(
              districtObjectId: pickupMatch.district.objectId,
              now: now,
            ))
            .where(
              (candidate) =>
                  eligibleDriverIds == null ||
                  eligibleDriverIds.contains(candidate.driverId),
            )
            .toList();
    candidates.sort((a, b) {
      if (a.hasCustomerCancellationPriority !=
          b.hasCustomerCancellationPriority) {
        return a.hasCustomerCancellationPriority ? -1 : 1;
      }
      final fifoOrder = a.fifoPriorityAt.compareTo(b.fifoPriorityAt);
      return fifoOrder != 0 ? fifoOrder : a.driverId.compareTo(b.driverId);
    });
    final destination = RouteWaypoint(latitude: latitude, longitude: longitude);

    for (final candidate in candidates) {
      if (!history.canOfferDriver(
        candidate.driverId,
        dispatchRound: ride.dispatchRound,
      )) {
        continue;
      }

      int? etaSeconds;
      int? distanceMeters;
      try {
        final estimate = await candidateService.routeEstimator.estimate(
          origin: RouteWaypoint(
            latitude: candidate.location.latitude,
            longitude: candidate.location.longitude,
          ),
          destination: destination,
        );
        etaSeconds = estimate.durationSeconds.round();
        distanceMeters = estimate.distanceMeters.round();
      } on RouteEstimationFailure {
        // ETA and distance are informational for district dispatch. A route
        // provider failure must never skip this FIFO head or prevent its
        // offer. Other StateErrors and programmer errors remain visible.
        etaSeconds = null;
        distanceMeters = null;
      }

      final offer = RideOffer.create(
        id: offerId,
        rideId: ride.id,
        driverId: candidate.driverId,
        vehicleId: candidate.vehicleId,
        etaSeconds: etaSeconds,
        distanceMeters: distanceMeters,
        dispatchDistrictObjectId: candidate.districtObjectId,
        dispatchDistrictEnteredAt: candidate.enteredAt,
        dispatchLocationUpdatedAt: candidate.location.updatedAt,
        dispatchGpsFixAt: candidate.location.gpsFixAt,
        dispatchHadCancellationPriority:
            candidate.hasCustomerCancellationPriority,
        dispatchRound: ride.dispatchRound,
        bonusMinor: ride.driverBonusMinor,
        source: source,
        offeredAt: (offerTime?.call() ?? currentTime?.call() ?? now).toUtc(),
        timeout: dispatchService.policy.offerTimeout,
      );

      try {
        return await persist(offer);
      } on AtomicRideOfferConflictException catch (error) {
        switch (error.conflict) {
          case AtomicRideOfferConflict.driverShiftNotFound:
          case AtomicRideOfferConflict.vehicleDoesNotMatchShift:
          case AtomicRideOfferConflict.driverNotAvailable:
          case AtomicRideOfferConflict.driverLocationStale:
          case AtomicRideOfferConflict.driverDistrictChanged:
          case AtomicRideOfferConflict.driverCancellationPriorityChanged:
          case AtomicRideOfferConflict.driverAlreadyHasPendingOffer:
          case AtomicRideOfferConflict.rideAlreadyOfferedToDriver:
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
}
