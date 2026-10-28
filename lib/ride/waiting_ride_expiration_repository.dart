/// One bounded transaction's work for expiring waiting-board rides.
final class WaitingRideExpirationBatch {
  const WaitingRideExpirationBatch({
    required this.cancelledRideIds,
    required this.expiredOfferCount,
  });

  final List<String> cancelledRideIds;
  final int expiredOfferCount;

  int get cancelledRideCount => cancelledRideIds.length;
}

abstract interface class WaitingRideExpirationRepository {
  /// Atomically cancels a bounded batch of due waiting-board rides.
  ///
  /// The implementation must use the database clock and serialize on each
  /// ride row with acceptance, reservation and waiting-board offer creation.
  Future<WaitingRideExpirationBatch> cancelExpiredWaitingRides({
    required int limit,
  });

  /// Stops queued/leased reject redispatch work for cancelled rides without
  /// claiming that redispatch completed. This is safe to retry after restart.
  Future<int> settleOutboxForCancelledRides({required int limit});
}
