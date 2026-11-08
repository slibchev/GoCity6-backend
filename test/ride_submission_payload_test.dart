import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_submission_payload.dart';
import 'package:test/test.dart';

void main() {
  final existing = RideRequest(
    id: 'ride-1',
    clientRequestId: 'request-1',
    pickup: 'My location',
    pickupLatitude: 42.7,
    pickupLongitude: 23.3,
    destination: 'Airport',
    destinationLatitude: 42.6,
    destinationLongitude: 23.2,
    passengers: 2,
    hasLuggage: true,
    requestedAt: DateTime.utc(2026),
  );

  Map<String, Object?> payload({
    double latitude = 42.7,
    double longitude = 23.3,
    double destinationLatitude = 42.6,
    double destinationLongitude = 23.2,
  }) => {
    'existing': existing,
    'pickup': 'My location',
    'destination': 'Airport',
    'passengers': 2,
    'hasLuggage': true,
    'pickupLatitude': latitude,
    'pickupLongitude': longitude,
    'destinationLatitude': destinationLatitude,
    'destinationLongitude': destinationLongitude,
  };

  bool matches(Map<String, Object?> values) => rideSubmissionMatchesExisting(
    existing: values['existing']! as RideRequest,
    pickup: values['pickup']! as String,
    destination: values['destination']! as String,
    passengers: values['passengers']! as int,
    hasLuggage: values['hasLuggage']! as bool,
    pickupLatitude: values['pickupLatitude']! as double,
    pickupLongitude: values['pickupLongitude']! as double,
    destinationLatitude: values['destinationLatitude']! as double,
    destinationLongitude: values['destinationLongitude']! as double,
  );

  test('same idempotency payload includes identical GPS coordinates', () {
    expect(matches(payload()), isTrue);
  });

  test(
    'a changed latitude or longitude makes the idempotency payload differ',
    () {
      expect(matches(payload(latitude: 42.7001)), isFalse);
      expect(matches(payload(longitude: 23.3001)), isFalse);
      expect(matches(payload(destinationLatitude: 42.6001)), isFalse);
      expect(matches(payload(destinationLongitude: 23.2001)), isFalse);
    },
  );

  test(
    'address-only legacy submissions continue to match without coordinates',
    () {
      final addressOnlyRide = existing.copyWith(
        pickup: 'Sofia Center',
        pickupLatitude: null,
        pickupLongitude: null,
        destinationLatitude: null,
        destinationLongitude: null,
      );

      expect(
        rideSubmissionMatchesExisting(
          existing: addressOnlyRide,
          pickup: 'Sofia Center',
          destination: 'Airport',
          passengers: 2,
          hasLuggage: true,
          pickupLatitude: null,
          pickupLongitude: null,
          destinationLatitude: null,
          destinationLongitude: null,
        ),
        isTrue,
      );
    },
  );

  test('legacy destination without coordinates differs from supplied pair', () {
    final legacyRide = existing.copyWith(
      destinationLatitude: null,
      destinationLongitude: null,
    );

    expect(
      rideSubmissionMatchesExisting(
        existing: legacyRide,
        pickup: 'My location',
        destination: 'Airport',
        passengers: 2,
        hasLuggage: true,
        pickupLatitude: 42.7,
        pickupLongitude: 23.3,
        destinationLatitude: 42.6,
        destinationLongitude: 23.2,
      ),
      isFalse,
    );
  });
}
