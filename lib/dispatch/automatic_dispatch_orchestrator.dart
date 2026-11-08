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

      final selectedPoolEntry = pool.entries.firstWhere(
        (entry) => entry.shift.driverId == result.offer.driverId,
      );
      final offerWithDistrictSnapshot =
          await _waitingBoardOfferWithDistrictSnapshot(
            offer: result.offer,
            latitude: selectedPoolEntry.location.latitude,
            longitude: selectedPoolEntry.location.longitude,
            now: nowUtc,
          );

      try {
        return await atomicOfferRepository.createPendingOffer(
          offer: offerWithDistrictSnapshot,
        );
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

    if (source == RideOfferSource.automatic &&
        requiredStatus == RideRequestStatus.pending &&
        _districtFifoIsConfigured) {
      return _createDistrictFifoOffer(
        ride: ride,
        offerId: offerId,
        now: nowUtc,
        history: history,
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

  Future<RideOffer> _waitingBoardOfferWithDistrictSnapshot({
    required RideOffer offer,
    required double latitude,
    required double longitude,
    required DateTime now,
  }) async {
    if (!_districtFifoIsConfigured) return offer;

    final match = districtMatcher!.match(
      latitude: latitude,
      longitude: longitude,
    );
    if (match == null ||
        match.resolution == DistrictMatchResolution.overlapTieBreak) {
      return offer;
    }

    final districtCandidates = await findDistrictCandidates!(
      districtObjectId: match.district.objectId,
      now: now,
    );
    DriverDistrictQueueCandidate? selectedDistrictCandidate;
    for (final candidate in districtCandidates) {
      if (candidate.driverId == offer.driverId) {
        selectedDistrictCandidate = candidate;
        break;
      }
    }
    if (selectedDistrictCandidate == null) return offer;

    final candidate = selectedDistrictCandidate;
    return RideOffer.create(
      id: offer.id,
      rideId: offer.rideId,
      driverId: offer.driverId,
      vehicleId: offer.vehicleId,
      etaSeconds: offer.etaSeconds,
      distanceMeters: offer.distanceMeters,
      dispatchDistrictObjectId: candidate.districtObjectId,
      dispatchDistrictEnteredAt: candidate.enteredAt,
      dispatchLocationUpdatedAt: candidate.location.updatedAt,
      dispatchGpsFixAt: candidate.location.gpsFixAt,
      dispatchHadCancellationPriority:
          candidate.hasCustomerCancellationPriority,
      dispatchRound: offer.dispatchRound,
      bonusMinor: offer.bonusMinor,
      source: offer.source,
      offeredAt: offer.offeredAt,
      timeout: offer.expiresAt.difference(offer.offeredAt),
    );
  }

  Future<RideOffer?> _createDistrictFifoOffer({
    required RideRequest ride,
    required String offerId,
    required DateTime now,
    required RideOfferHistory history,
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
      // Let the existing waiting-board flow handle this ride.
      return null;
    }
    if (pickupMatch == null ||
        pickupMatch.resolution == DistrictMatchResolution.overlapTieBreak) {
      // Unknown or overlapping pickup locations use the existing waiting
      // board path; no district is guessed for this ride.
      return null;
    }

    final candidates = (await findDistrictCandidates!(
      districtObjectId: pickupMatch.district.objectId,
      now: now,
    )).toList();
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
        source: RideOfferSource.automatic,
        offeredAt: (currentTime?.call() ?? now).toUtc(),
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
