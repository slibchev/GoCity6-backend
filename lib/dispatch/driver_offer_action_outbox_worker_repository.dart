import 'driver_offer_action_outbox_repository.dart';

/// Safe, predefined diagnostic codes stored in the outbox.
///
/// Do not add raw exception text, provider messages, addresses, or other
/// request data here.
enum DriverOfferActionOutboxErrorCode {
  transientFailure('transient_failure'),
  dependencyUnavailable('dependency_unavailable'),
  noEligibleDriver('no_eligible_driver'),
  permanentFailure('permanent_failure'),
  unsupportedOfferSource('unsupported_offer_source'),
  outcomeUnknown('outcome_unknown'),
  unexpectedFailure('unexpected_failure'),
  attemptsExhausted('attempts_exhausted'),
  rideCancelled('ride_cancelled');

  const DriverOfferActionOutboxErrorCode(this.databaseValue);

  final String databaseValue;
}

/// Transactional claim and lease-checked finalization for reject outbox jobs.
abstract interface class DriverOfferActionOutboxWorkerRepository {
  /// Claims one due job, including a job whose previous lease has expired.
  ///
  /// The implementation must commit the lease before returning and use the
  /// database clock for both readiness and lease expiry comparisons.
  Future<DriverOfferActionOutboxRecord?> claimNext({
    required String leaseToken,
    required Duration leaseDuration,
    required int maxAttempts,
  });

  /// Returns false when this token is no longer the current, unexpired lease.
  Future<bool> markCompleted({
    required String actionId,
    required String leaseToken,
  });

  /// Schedules a bounded retry using database time and the supplied delay.
  Future<bool> markRetryable({
    required String actionId,
    required String leaseToken,
    required Duration retryAfter,
    required DriverOfferActionOutboxErrorCode errorCode,
  });

  /// Stops automatic work and leaves the job for inspection.
  Future<bool> markNeedsReview({
    required String actionId,
    required String leaseToken,
    required DriverOfferActionOutboxErrorCode errorCode,
  });
}
