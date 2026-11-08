import '../ride/ride_lifecycle_service.dart';
import '../ride/ride_request.dart';
import '../ride/ride_request_repository.dart';
import 'automatic_dispatch_exhaustion_service.dart';
import 'automatic_dispatch_orchestrator.dart';
import 'driver_offer_action_outbox_repository.dart';
import 'ride_offer.dart';
import 'ride_offer_history.dart';

typedef RedispatchWaitingRides = Future<void> Function();
typedef ProcessDispatchOutboxAction = Future<void> Function({
  required String actionId,
});
typedef FindOfferForDispatchAction = Future<RideOffer?> Function(
  String actionId,
);

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
  final RedispatchWaitingRides? redispatchWaitingRides;
  final ProcessDispatchOutboxAction? processDispatchOutboxAction;
  final FindOfferForDispatchAction? findOfferForDispatchAction;

  const AutomaticRideSubmissionService({
    required this.lifecycleService,
    required this.rideRepository,
    required this.dispatchOrchestrator,
    required this.exhaustionService,
    required this.offerIdFactory,
    required this.now,
    this.redispatchWaitingRides,
    this.processDispatchOutboxAction,
    this.findOfferForDispatchAction,
  });

  Future<AutomaticRideSubmissionResult> submit(RideRequest request) async {
    final durable = await lifecycleService
        .submitPendingRideForAutomaticDispatch(request);
    final pendingRide = request;

    if (durable) {
      final actionId = initialDispatchActionId(pendingRide.id);
      await processDispatchOutboxAction?.call(actionId: actionId);
      final offer = await findOfferForDispatchAction?.call(actionId);
      final updatedRide = await rideRepository.findById(pendingRide.id);
      return AutomaticRideSubmissionResult(
        ride: updatedRide ?? pendingRide,
        offer: offer,
      );
    }

    final offer = await dispatchOrchestrator.createNextOffer(
      ride: pendingRide,
      offerId: offerIdFactory(),
      now: now().toUtc(),
    );

    if (offer != null) {
      // The new ride gets its local district FIFO attempt before an older
      // waiting-board ride can consume one of the same available drivers.
      try {
        await redispatchWaitingRides?.call();
      } on Exception catch (error) {
        // The new offer has already committed. A failure to redispatch older
        // waiting-board rides must not make the passenger retry a committed
        // submission as if it had failed.
        print(
          'Waiting-board redispatch after local offer failed: '
          '${error.runtimeType}.',
        );
      }
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

    // After the new ride has been offered locally or moved through the
    // existing exhaustion policy, let the waiting-board flow use remaining
    // available drivers. This also includes this ride if it just moved there.
    await redispatchWaitingRides?.call();

    return AutomaticRideSubmissionResult(ride: updatedRide, offer: null);
  }
}
