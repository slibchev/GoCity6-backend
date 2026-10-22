import 'ride_request.dart';

bool rideSubmissionMatchesExisting({
  required RideRequest existing,
  required String pickup,
  required String destination,
  required int passengers,
  required bool hasLuggage,
  required double? pickupLatitude,
  required double? pickupLongitude,
}) {
  return existing.pickup == pickup &&
      existing.destination == destination &&
      existing.passengers == passengers &&
      existing.hasLuggage == hasLuggage &&
      existing.pickupLatitude == pickupLatitude &&
      existing.pickupLongitude == pickupLongitude;
}
