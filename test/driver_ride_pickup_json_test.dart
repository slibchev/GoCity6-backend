import 'package:gocity6_backend/ride/driver_ride_pickup_json.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:test/test.dart';

void main() {
  RideRequest ride({String? address, double? latitude, double? longitude}) =>
      RideRequest(
        id: 'ride-1',
        pickup: 'Моето местоположение',
        pickupDisplayAddress: address,
        pickupLatitude: latitude,
        pickupLongitude: longitude,
        destination: 'Paradise Center',
        passengers: 1,
        requestedAt: DateTime.utc(2026, 11, 3),
      );

  test(
    'Driver pickup payload includes resolved display and GPS coordinates',
    () {
      final result = driverRidePickupJson(
        ride(
          address: 'ул. Верила 2, София',
          latitude: 42.6977,
          longitude: 23.3219,
        ),
      );

      expect(result, {
        'pickupDisplayAddress': 'ул. Верила 2, София',
        'pickupLatitude': 42.6977,
        'pickupLongitude': 23.3219,
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
  });

  test('legacy text-only rides keep null display and coordinate fields', () {
    expect(driverRidePickupJson(ride()), {
      'pickupDisplayAddress': isNull,
      'pickupLatitude': isNull,
      'pickupLongitude': isNull,
    });
  });
}
