import 'package:gocity6_backend/ride/resolve_pickup_display_address.dart';
import 'package:gocity6_backend/ride/ride_pickup_coordinates.dart';
import 'package:test/test.dart';

void main() {
  const coordinates = RidePickupCoordinates(
    latitude: 42.6977,
    longitude: 23.3219,
  );

  test(
    'resolves only current-location labels using the submitted GPS pair',
    () async {
      double? seenLatitude;
      double? seenLongitude;

      final address = await resolvePickupDisplayAddress(
        pickup: 'Моето местоположение',
        coordinates: coordinates,
        reverseGeocode: ({required latitude, required longitude}) async {
          seenLatitude = latitude;
          seenLongitude = longitude;
          return 'ул. Верила 2, София';
        },
      );

      expect(address, 'ул. Верила 2, София');
      expect(seenLatitude, coordinates.latitude);
      expect(seenLongitude, coordinates.longitude);
    },
  );

  test(
    'preserves a manually selected address without reverse geocoding',
    () async {
      var called = false;

      final address = await resolvePickupDisplayAddress(
        pickup: 'ул. Верила 2, София',
        coordinates: coordinates,
        reverseGeocode: ({required latitude, required longitude}) async {
          called = true;
          return 'unexpected replacement';
        },
      );

      expect(address, isNull);
      expect(called, isFalse);
    },
  );

  test(
    'geocoding failure leaves a null display address and does not throw',
    () async {
      final address = await resolvePickupDisplayAddress(
        pickup: 'My location',
        coordinates: coordinates,
        reverseGeocode: ({required latitude, required longitude}) async {
          throw StateError('provider unavailable');
        },
      );

      expect(address, isNull);
    },
  );

  test('missing coordinates never fall back to a different location', () async {
    var called = false;

    final address = await resolvePickupDisplayAddress(
      pickup: 'My location',
      coordinates: null,
      reverseGeocode: ({required latitude, required longitude}) async {
        called = true;
        return 'unexpected replacement';
      },
    );

    expect(address, isNull);
    expect(called, isFalse);
  });
}
