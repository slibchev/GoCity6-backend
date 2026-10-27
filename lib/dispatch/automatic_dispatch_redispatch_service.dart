import '../ride/ride_request_repository.dart';
import '../ride/ride_request_status.dart';
import 'automatic_dispatch_orchestrator.dart';
import 'idempotent_automatic_redispatch_repository.dart';
import 'ride_offer.dart';

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

/// Opt-in normal-dispatch continuation for a single rejected-offer action.
///
/// This service is intentionally not connected to the live worker or server.
/// Candidate and route calculation finishes before the atomic offer
/// transaction begins. It does not resolve exhausted rounds or waiting-board
/// rides.
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
  });

  final RideRequestRepository rideRepository;
  final AutomaticDispatchOrchestrator dispatchOrchestrator;
  final IdempotentAutomaticRedispatchOfferRepository redispatchOfferRepository;
  final String Function() offerIdFactory;
  final DateTime Function() now;

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
      throw StateError('Redispatch ride is no longer pending.');
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
