import '../ride/ride_lifecycle_service.dart';
import '../ride/ride_request.dart';
import '../ride/ride_request_repository.dart';
import 'automatic_dispatch_exhaustion_service.dart';
import 'automatic_dispatch_orchestrator.dart';
import 'ride_offer.dart';
import 'ride_offer_history.dart';

class AutomaticRideSubmissionResult {
  final RideRequest ride;
  final RideOffer? offer;

  const AutomaticRideSubmissionResult({
    required this.ride,
    required this.offer,
  });
}

class AutomaticRideSubmissionService {
  final RideLifecycleService lifecycleService;
  final RideRequestRepository rideRepository;
  final AutomaticDispatchOrchestrator dispatchOrchestrator;
  final AutomaticDispatchExhaustionService exhaustionService;
  final String Function() offerIdFactory;
  final DateTime Function() now;

  const AutomaticRideSubmissionService({
    required this.lifecycleService,
    required this.rideRepository,
    required this.dispatchOrchestrator,
    required this.exhaustionService,
    required this.offerIdFactory,
    required this.now,
  });

  Future<AutomaticRideSubmissionResult> submit(RideRequest request) async {
    final pendingRide = await lifecycleService.submitPendingRide(request);

    final offer = await dispatchOrchestrator.createNextOffer(
      ride: pendingRide,
      offerId: offerIdFactory(),
      now: now().toUtc(),
    );

    if (offer != null) {
      return AutomaticRideSubmissionResult(ride: pendingRide, offer: offer);
    }

    await exhaustionService.handleExhaustedRound(
      rideId: pendingRide.id,
      dispatchRound: pendingRide.dispatchRound,
      history: RideOfferHistory(rideId: pendingRide.id, offers: const []),
    );

    final updatedRide = await rideRepository.findById(pendingRide.id);

    if (updatedRide == null) {
      throw StateError(
        'Submitted ride ${pendingRide.id} could not be reloaded.',
      );
    }

    return AutomaticRideSubmissionResult(ride: updatedRide, offer: null);
  }
}
