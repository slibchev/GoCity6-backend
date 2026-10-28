import 'waiting_ride_expiration_repository.dart';

final class WaitingRideExpirationResult {
  const WaitingRideExpirationResult({
    required this.cancelledRideCount,
    required this.expiredOfferCount,
    required this.settledOutboxCount,
  });

  final int cancelledRideCount;
  final int expiredOfferCount;
  final int settledOutboxCount;

  bool get didWork =>
      cancelledRideCount > 0 || expiredOfferCount > 0 || settledOutboxCount > 0;
}

/// Reconciles stale waiting-board rides and outbox work in bounded batches.
///
/// Ride cancellation and attached offer/queue updates commit atomically. The
/// outbox reconciliation is a separate, repeatable phase so a process crash
/// between the phases is recovered by the next startup or periodic scan.
final class WaitingRideExpirationService {
  static const int defaultBatchSize = 100;

  const WaitingRideExpirationService({
    required this.repository,
    this.batchSize = defaultBatchSize,
  }) : assert(batchSize > 0);

  final WaitingRideExpirationRepository repository;
  final int batchSize;

  Future<WaitingRideExpirationResult> processDueRides() async {
    final expired = await repository.cancelExpiredWaitingRides(
      limit: batchSize,
    );
    final settledOutboxCount = await repository.settleOutboxForCancelledRides(
      limit: batchSize,
    );

    return WaitingRideExpirationResult(
      cancelledRideCount: expired.cancelledRideCount,
      expiredOfferCount: expired.expiredOfferCount,
      settledOutboxCount: settledOutboxCount,
    );
  }
}
