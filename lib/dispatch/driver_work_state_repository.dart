import '../ride/ride_request.dart';
import 'active_driver_shift.dart';
import 'ride_offer.dart';

class DriverPendingOfferState {
  final RideOffer offer;
  final RideRequest ride;

  const DriverPendingOfferState({
    required this.offer,
    required this.ride,
  });
}

class DriverWorkStateSnapshot {
  final ActiveDriverShift? activeShift;
  final DriverPendingOfferState? pendingOffer;
  final RideRequest? currentRide;
  final RideRequest? reservedRide;

  const DriverWorkStateSnapshot({
    required this.activeShift,
    required this.pendingOffer,
    required this.currentRide,
    required this.reservedRide,
  });
}

abstract interface class DriverWorkStateRepository {
  Future<DriverWorkStateSnapshot> loadByDriverId(
    String driverId,
  );
}