import '../ride/ride_request.dart';
import 'atomic_ride_offer_repository.dart';
import 'automatic_dispatch_orchestrator.dart';
import 'dispatch_candidate_service.dart';
import 'ride_offer.dart';
import 'waiting_ride_redispatch_repository.dart';

class WaitingBoardRedispatchService {
  static const Duration maximumRideAge = Duration(minutes: 30);
  static const int pageSize = 50;

  final WaitingRideRedispatchRepository rideRepository;
  final DispatchCandidateService candidateService;
  final AutomaticDispatchOrchestrator dispatchOrchestrator;
  final String Function() offerIdFactory;
  final DateTime Function() now;

  const WaitingBoardRedispatchService({
    required this.rideRepository,
    required this.candidateService,
    required this.dispatchOrchestrator,
    required this.offerIdFactory,
    required this.now,
  });

  Future<List<RideOffer>> dispatchAvailableWaiters({DateTime? at}) async {
    final nowUtc = (at ?? now()).toUtc();
    var pool = await candidateService.buildEligiblePool(now: nowUtc);

    if (pool.isEmpty) {
      return const [];
    }

    final notBefore = nowUtc.subtract(maximumRideAge);
    final createdOffers = <RideOffer>[];

    // Each committed offer removes its driver from this snapshot. The loop
    // therefore ends after at most one offer per initially eligible driver.
    while (!pool.isEmpty) {
      DateTime? afterRequestedAt;
      String? afterRideId;
      var createdOfferForPool = false;

      while (true) {
        final page = await rideRepository.findOldestPage(
          notBefore: notBefore,
          afterRequestedAt: afterRequestedAt,
          afterRideId: afterRideId,
          limit: pageSize,
        );

        if (page.isEmpty) {
          break;
        }

        for (final ride in page) {
          if (_isTooOld(ride, nowUtc)) {
            continue;
          }

          try {
            final offer = await dispatchOrchestrator
                .createNextWaitingBoardOfferFromPool(
                  ride: ride,
                  offerId: offerIdFactory(),
                  now: nowUtc,
                  offerTime: now,
                  candidatePool: pool,
                );

            if (offer == null) {
              continue;
            }

            createdOffers.add(offer);
            pool = pool.withoutDriver(offer.driverId);
            createdOfferForPool = true;
            break;
          } on AtomicRideOfferConflictException catch (error) {
            switch (error.conflict) {
              case AtomicRideOfferConflict.rideNotFound:
              case AtomicRideOfferConflict.rideNotPending:
              case AtomicRideOfferConflict.rideNotWaitingForVehicle:
              case AtomicRideOfferConflict.rideTooOld:
              case AtomicRideOfferConflict.rideAlreadyAssigned:
              case AtomicRideOfferConflict.rideDispatchStateMismatch:
              case AtomicRideOfferConflict.rideHasPendingOffer:
              case AtomicRideOfferConflict.rideAlreadyHasPendingOffer:
                continue;

              case AtomicRideOfferConflict.offerNotFound:
              case AtomicRideOfferConflict.offerNotPending:
              case AtomicRideOfferConflict.offerAlreadyExpired:
              case AtomicRideOfferConflict.offerNotExpiredYet:
              case AtomicRideOfferConflict.driverShiftNotFound:
              case AtomicRideOfferConflict.vehicleDoesNotMatchShift:
              case AtomicRideOfferConflict.driverNotAvailable:
              case AtomicRideOfferConflict.driverLocationStale:
              case AtomicRideOfferConflict.driverAlreadyHasPendingOffer:
              case AtomicRideOfferConflict.driverPendingOfferMissing:
              case AtomicRideOfferConflict.rideAlreadyOfferedToDriver:
                rethrow;
            }
          }
        }

        if (createdOfferForPool || page.length < pageSize) {
          break;
        }

        final lastRide = page.last;
        afterRequestedAt = lastRide.requestedAt;
        afterRideId = lastRide.id;
      }

      if (!createdOfferForPool) {
        break;
      }
    }

    return List.unmodifiable(createdOffers);
  }

  bool _isTooOld(RideRequest ride, DateTime nowUtc) {
    return !nowUtc.isBefore(ride.requestedAt.toUtc().add(maximumRideAge));
  }
}
