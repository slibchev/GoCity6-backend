import '../ride/ride_request_repository.dart';
import '../ride/ride_request_status.dart';
import 'automatic_dispatch_exhaustion_service.dart';
import 'automatic_dispatch_orchestrator.dart';
import 'ride_offer.dart';
import 'ride_offer_history.dart';
import 'ride_offer_repository.dart';

class AutomaticDispatchContinuationService {
  final RideRequestRepository rideRepository;
  final RideOfferRepository offerRepository;
  final AutomaticDispatchOrchestrator dispatchOrchestrator;
  final AutomaticDispatchExhaustionService exhaustionService;
  final String Function() offerIdFactory;
  final DateTime Function() now;

  const AutomaticDispatchContinuationService({
    required this.rideRepository,
    required this.offerRepository,
    required this.dispatchOrchestrator,
    required this.exhaustionService,
    required this.offerIdFactory,
    required this.now,
  });

  Future<RideOffer?> continueRide({required String rideId}) async {
    final ride = await rideRepository.findById(rideId);

    if (ride == null) {
      throw StateError('Ride $rideId was not found.');
    }

    if (ride.status != RideRequestStatus.pending) {
      throw StateError('Ride $rideId is not pending.');
    }

    final nowUtc = now().toUtc();

    final nextOffer = await dispatchOrchestrator.createNextOffer(
      ride: ride,
      offerId: offerIdFactory(),
      now: nowUtc,
    );

    if (nextOffer != null) {
      return nextOffer;
    }

    final offers = await offerRepository.findByRideId(ride.id);

    final history = RideOfferHistory(rideId: ride.id, offers: offers);

    await exhaustionService.handleExhaustedRound(
      rideId: ride.id,
      dispatchRound: ride.dispatchRound,
      history: history,
    );

    return null;
  }
}
