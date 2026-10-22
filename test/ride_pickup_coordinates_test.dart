import 'package:gocity6_backend/ride/ride_pickup_coordinates.dart';
import 'package:test/test.dart';

void main() {
  group('RidePickupCoordinates.parseJson', () {
    test('allows both coordinates to be omitted for a normal address', () {
      expect(
        RidePickupCoordinates.parseJson(const <String, dynamic>{}),
        isNull,
      );
    });

    test('accepts WGS84 boundary coordinates and normalizes to doubles', () {
      final coordinates = RidePickupCoordinates.parseJson({
        'pickupLatitude': 90,
        'pickupLongitude': -180,
      });

      expect(coordinates?.latitude, 90.0);
      expect(coordinates?.longitude, -180.0);
    });

    test('rejects a partial coordinate pair', () {
      expect(
        () => RidePickupCoordinates.parseJson({'pickupLatitude': 42.7}),
        throwsA(isA<InvalidRidePickupCoordinatesException>()),
      );
      expect(
        () => RidePickupCoordinates.parseJson({
          'pickupLatitude': null,
          'pickupLongitude': 23.3,
        }),
        throwsA(isA<InvalidRidePickupCoordinatesException>()),
      );
    });

    test(
      'rejects invalid types, non-finite values, and out-of-range values',
      () {
        for (final payload in <Map<String, dynamic>>[
          {'pickupLatitude': '42.7', 'pickupLongitude': 23.3},
          {'pickupLatitude': true, 'pickupLongitude': 23.3},
          {'pickupLatitude': double.nan, 'pickupLongitude': 23.3},
          {'pickupLatitude': 42.7, 'pickupLongitude': double.infinity},
          {'pickupLatitude': 90.0001, 'pickupLongitude': 23.3},
          {'pickupLatitude': 42.7, 'pickupLongitude': -180.0001},
        ]) {
          expect(
            () => RidePickupCoordinates.parseJson(payload),
            throwsA(isA<InvalidRidePickupCoordinatesException>()),
          );
        }
      },
    );
  });

  test(
    'recognizes current-location labels without treating arbitrary text so',
    () {
      expect(isCurrentLocationPickupLabel('Моето местоположение'), isTrue);
      expect(isCurrentLocationPickupLabel(' my location '), isTrue);
      expect(isCurrentLocationPickupLabel('Sofia Center'), isFalse);
    },
  );
}
