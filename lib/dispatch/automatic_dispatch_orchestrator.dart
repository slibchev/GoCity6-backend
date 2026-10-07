import '../ride/ride_request.dart';
import '../ride/ride_request_status.dart';
import 'atomic_ride_offer_repository.dart';
import 'automatic_dispatch_service.dart';
import 'dispatch_candidate_service.dart';
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
    if (ride.status != RideRequestStatus.pending) {
      throw ArgumentError.value(
        ride.status,
        'ride.status',
        'Automatic dispatch requires a pending ride.',
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
    );

    if (result == null) {
      return null;
    }

    return atomicOfferRepository.createPendingOffer(offer: result.offer);
  }
}
