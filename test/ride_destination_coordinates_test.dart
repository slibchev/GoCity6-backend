import 'package:gocity6_backend/ride/ride_destination_coordinates.dart';
import 'package:test/test.dart';

void main() {
  test('both omitted or both null preserve legacy address-only rides', () {
    expect(RideDestinationCoordinates.parseJson({}), isNull);
    expect(
      RideDestinationCoordinates.parseJson({
        'destinationLatitude': null,
        'destinationLongitude': null,
      }),
      isNull,
    );
  });

  test('valid WGS84 destination coordinates are parsed as doubles', () {
    final coordinates = RideDestinationCoordinates.parseJson({
      'destinationLatitude': 90,
      'destinationLongitude': -180,
    });

    expect(coordinates?.latitude, 90.0);
    expect(coordinates?.longitude, -180.0);
  });

  test(
    'partial, nonnumeric, nonfinite and out-of-range pairs are rejected',
    () {
      for (final body in <Map<String, Object?>>[
        {'destinationLatitude': 42.7},
        {'destinationLongitude': 23.3},
        {'destinationLatitude': 42.7, 'destinationLongitude': null},
        {'destinationLatitude': null, 'destinationLongitude': 23.3},
        {'destinationLatitude': '42.7', 'destinationLongitude': 23.3},
        {'destinationLatitude': double.nan, 'destinationLongitude': 23.3},
        {'destinationLatitude': 91, 'destinationLongitude': 23.3},
        {'destinationLatitude': 42.7, 'destinationLongitude': 180.001},
      ]) {
        expect(
          () => RideDestinationCoordinates.parseJson(body),
          throwsA(isA<InvalidRideDestinationCoordinatesException>()),
          reason: body.toString(),
        );
      }
    },
  );
}
