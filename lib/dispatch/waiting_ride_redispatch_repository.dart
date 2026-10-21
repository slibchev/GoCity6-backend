import '../ride/ride_request.dart';

abstract interface class WaitingRideRedispatchRepository {
  Future<List<RideRequest>> findOldestPage({
    required DateTime notBefore,
    DateTime? afterRequestedAt,
    String? afterRideId,
    int limit = 50,
  });
}
