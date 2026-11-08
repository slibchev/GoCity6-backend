import '../bin/server.dart' as backend;

import 'package:gocity6_backend/ride/driver_ride_pickup_json.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:test/test.dart';

void main() {
  RideRequest ride({
    String? address,
    double? latitude,
    double? longitude,
    double? destinationLatitude,
    double? destinationLongitude,
    RideRequestStatus status = RideRequestStatus.pending,
  }) => RideRequest(
    id: 'ride-1',
    pickup: 'Моето местоположение',
    pickupDisplayAddress: address,
    pickupLatitude: latitude,
    pickupLongitude: longitude,
    destination: 'Paradise Center',
    destinationLatitude: destinationLatitude,
    destinationLongitude: destinationLongitude,
    passengers: 1,
    requestedAt: DateTime.utc(2026, 11, 3),
    status: status,
  );

  test(
    'central serializers expose destination coordinates only to Driver',
    () async {
      for (final status in [
        RideRequestStatus.pending,
        RideRequestStatus.waitingForVehicle,
        RideRequestStatus.accepted,
        RideRequestStatus.reserved,
        RideRequestStatus.driverArriving,
        RideRequestStatus.inProgress,
        RideRequestStatus.completed,
      ]) {
        final request = ride(
          destinationLatitude: 42.65,
          destinationLongitude: 23.38,
          status: status,
        );

        final driverJson = await backend.driverRideRequestToJson(request);
        expect(driverJson['destinationLatitude'], 42.65, reason: status.name);
        expect(driverJson['destinationLongitude'], 23.38, reason: status.name);

        final passengerJson = await backend.rideRequestToJson(request);
        expect(passengerJson.containsKey('destinationLatitude'), isFalse);
        expect(passengerJson.containsKey('destinationLongitude'), isFalse);
      }
    },
  );

  test(
    'Driver pickup payload includes resolved display and GPS coordinates',
    () {
      final result = driverRidePickupJson(
        ride(
          address: 'ул. Верила 2, София',
          latitude: 42.6977,
          longitude: 23.3219,
          destinationLatitude: 42.65,
          destinationLongitude: 23.38,
        ),
      );

      expect(result, {
        'pickupDisplayAddress': 'ул. Верила 2, София',
        'pickupLatitude': 42.6977,
        'pickupLongitude': 23.3219,
        'destinationLatitude': 42.65,
        'destinationLongitude': 23.38,
      });
    },
  );

  test('legacy or failed geocoding keeps a null address and GPS fallback', () {
    final result = driverRidePickupJson(
      ride(latitude: 42.6977, longitude: 23.3219),
    );

    expect(result['pickupDisplayAddress'], isNull);
    expect(result['pickupLatitude'], 42.6977);
    expect(result['pickupLongitude'], 23.3219);
    expect(result['destinationLatitude'], isNull);
    expect(result['destinationLongitude'], isNull);
  });

  test('legacy text-only rides keep null display and coordinate fields', () {
    expect(driverRidePickupJson(ride()), {
      'pickupDisplayAddress': isNull,
      'pickupLatitude': isNull,
      'pickupLongitude': isNull,
      'destinationLatitude': isNull,
      'destinationLongitude': isNull,
    });
  });

  test('destination coordinates serialize for offer/current/reserved/lifecycle rides', () {
    for (final status in [
      RideRequestStatus.pending,
      RideRequestStatus.waitingForVehicle,
      RideRequestStatus.accepted,
      RideRequestStatus.reserved,
      RideRequestStatus.driverArriving,
      RideRequestStatus.inProgress,
      RideRequestStatus.completed,
      RideRequestStatus.cancelled,
    ]) {
      final result = driverRidePickupJson(
        ride(
          destinationLatitude: 42.65,
          destinationLongitude: 23.38,
          status: status,
        ),
      );
      expect(result['destinationLatitude'], 42.65, reason: status.name);
      expect(result['destinationLongitude'], 23.38, reason: status.name);
    }
  });
}
