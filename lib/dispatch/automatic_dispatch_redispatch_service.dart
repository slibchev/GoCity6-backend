import '../ride/ride_request_repository.dart';
import '../ride/ride_request.dart';
import '../ride/ride_request_status.dart';
import 'automatic_dispatch_exhaustion_service.dart';
import 'automatic_dispatch_orchestrator.dart';
import 'idempotent_automatic_redispatch_repository.dart';
import 'ride_offer.dart';
import 'ride_offer_history.dart';
import 'ride_offer_repository.dart';

sealed class AutomaticDispatchRedispatchResult {
  const AutomaticDispatchRedispatchResult();
}

final class AutomaticDispatchRedispatchCreated
    extends AutomaticDispatchRedispatchResult {
  const AutomaticDispatchRedispatchCreated(this.offer);

  final RideOffer offer;
}

/// An earlier attempt committed an offer for this action.
///
/// The offer may already be expired, rejected, or accepted. Its existence is
/// the durable proof that this action progressed and must not create another.
final class AutomaticDispatchRedispatchAlreadyProgressed
    extends AutomaticDispatchRedispatchResult {
  const AutomaticDispatchRedispatchAlreadyProgressed(this.offer);

  final RideOffer offer;
}

/// No eligible driver was found. This is not a settled outbox result.
final class AutomaticDispatchRedispatchNoEligibleDriver
    extends AutomaticDispatchRedispatchResult {
  const AutomaticDispatchRedispatchNoEligibleDriver();
}

/// The event advanced the ride to its durable exhausted-round state or found
/// that another valid state transition had already superseded dispatch.
final class AutomaticDispatchRedispatchAdvanced
    extends AutomaticDispatchRedispatchResult {
  const AutomaticDispatchRedispatchAdvanced();
}

/// Durable normal-dispatch continuation for reject, timeout, and initial
/// dispatch outbox actions.
///
/// Candidate and route calculation finishes before the atomic offer
/// transaction begins. When configured with exhaustion and waiting-board
/// services, it advances those states through their existing flow.
abstract interface class AutomaticDispatchRedispatcher {
  Future<AutomaticDispatchRedispatchResult> redispatch({
    required String rideId,
    required String actionId,
    required String leaseToken,
  });
}

final class AutomaticDispatchRedispatchService
    implements AutomaticDispatchRedispatcher {
  AutomaticDispatchRedispatchService({
    required this.rideRepository,
    required this.dispatchOrchestrator,
    required this.redispatchOfferRepository,
    required this.offerIdFactory,
    required this.now,
    this.offerRepository,
    this.exhaustionService,
    this.dispatchWaitingBoard,
  });

  final RideRequestRepository rideRepository;
  final AutomaticDispatchOrchestrator dispatchOrchestrator;
  final IdempotentAutomaticRedispatchOfferRepository redispatchOfferRepository;
  final String Function() offerIdFactory;
  final DateTime Function() now;
  final RideOfferRepository? offerRepository;
  final AutomaticDispatchExhaustionService? exhaustionService;
  final Future<void> Function()? dispatchWaitingBoard;

  @override
  Future<AutomaticDispatchRedispatchResult> redispatch({
    required String rideId,
    required String actionId,
    required String leaseToken,
  }) async {
    if (rideId.isEmpty || actionId.isEmpty || leaseToken.isEmpty) {
      throw ArgumentError('Ride, action, and lease identities are required.');
    }

    final progressedOffer = await redispatchOfferRepository
        .findOfferByRedispatchActionId(actionId);
    if (progressedOffer != null) {
      if (progressedOffer.rideId != rideId) {
        throw const AutomaticRedispatchConflictException(
          AutomaticRedispatchConflict.rideMismatch,
        );
      }
      return AutomaticDispatchRedispatchAlreadyProgressed(progressedOffer);
    }

    final ride = await rideRepository.findById(rideId);
    if (ride == null) {
      throw StateError('Redispatch ride was not found.');
    }
    if (ride.status != RideRequestStatus.pending) {
      if (ride.status == RideRequestStatus.waitingForVehicle) {
        await dispatchWaitingBoard?.call();
        return const AutomaticDispatchRedispatchAdvanced();
      }
      throw StateError('Redispatch ride is no longer pending.');
    }
    if (ride.bonusDecision == RideBonusDecision.awaitingCustomer) {
      return const AutomaticDispatchRedispatchAdvanced();
    }

    final priorOffers = await offerRepository?.findByRideId(rideId);
    if (priorOffers != null &&
        priorOffers.any(
          (offer) =>
              offer.status == RideOfferStatus.pending ||
              offer.status == RideOfferStatus.accepted,
        )) {
      return const AutomaticDispatchRedispatchAdvanced();
    }

    final persisted = await dispatchOrchestrator.createNextOfferForRedispatch(
      ride: ride,
      offerId: offerIdFactory(),
      now: now().toUtc(),
      actionId: actionId,
      leaseToken: leaseToken,
      redispatchOfferRepository: redispatchOfferRepository,
    );

    if (persisted == null) {
      final exhaustion = exhaustionService;
      final offerHistoryRepository = offerRepository;
      if (exhaustion != null && offerHistoryRepository != null) {
        final offers =
            priorOffers ?? await offerHistoryRepository.findByRideId(rideId);
        await exhaustion.handleExhaustedRound(
          rideId: rideId,
          dispatchRound: ride.dispatchRound,
          history: RideOfferHistory(rideId: rideId, offers: offers),
        );
        await dispatchWaitingBoard?.call();
        return const AutomaticDispatchRedispatchAdvanced();
      }
      return const AutomaticDispatchRedispatchNoEligibleDriver();
    }

    return switch (persisted) {
      AutomaticRedispatchOfferCreated(:final offer) =>
        AutomaticDispatchRedispatchCreated(offer),
      AutomaticRedispatchAlreadyProgressed(:final offer) =>
        AutomaticDispatchRedispatchAlreadyProgressed(offer),
    };
  }
}
