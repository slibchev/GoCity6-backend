import 'ride_offer.dart';

/// The durable result of creating an automatic offer for an outbox action.
sealed class IdempotentAutomaticRedispatchPersistenceResult {
  const IdempotentAutomaticRedispatchPersistenceResult(this.offer);

  final RideOffer offer;
}

final class AutomaticRedispatchOfferCreated
    extends IdempotentAutomaticRedispatchPersistenceResult {
  const AutomaticRedispatchOfferCreated(super.offer);
}

/// The action already created an offer, including when that offer is terminal.
final class AutomaticRedispatchAlreadyProgressed
    extends IdempotentAutomaticRedispatchPersistenceResult {
  const AutomaticRedispatchAlreadyProgressed(super.offer);
}

enum AutomaticRedispatchConflict {
  actionNotFound,
  actionNotReject,
  leaseLost,
  rideMismatch,
}

final class AutomaticRedispatchConflictException implements Exception {
  const AutomaticRedispatchConflictException(this.conflict);

  final AutomaticRedispatchConflict conflict;

  @override
  String toString() => 'Automatic redispatch conflict: ${conflict.name}';
}

/// Durable idempotency boundary for a single automatic redispatch action.
///
/// Implementations must persist the causal action id in the same transaction
/// as the offer and queue update. The lease token authorizes the mutation;
/// action id remains the stable idempotency identity across retries.
abstract interface class IdempotentAutomaticRedispatchOfferRepository {
  /// Returns the offer caused by [actionId], regardless of its current status.
  Future<RideOffer?> findOfferByRedispatchActionId(String actionId);

  /// Creates at most one automatic offer for [actionId].
  ///
  /// The implementation must serialize concurrent attempts for the same
  /// action and return [AutomaticRedispatchAlreadyProgressed] when an offer
  /// was committed by an earlier attempt.
  Future<IdempotentAutomaticRedispatchPersistenceResult>
  createPendingOfferForRedispatch({
    required RideOffer offer,
    required String actionId,
    required String leaseToken,
  });
}
