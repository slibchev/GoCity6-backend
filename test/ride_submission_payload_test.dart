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
    passengers: 2,
    hasLuggage: true,
    requestedAt: DateTime.utc(2026),
  );

  Map<String, Object?> payload({
    double latitude = 42.7,
    double longitude = 23.3,
  }) => {
    'existing': existing,
    'pickup': 'My location',
    'destination': 'Airport',
    'passengers': 2,
    'hasLuggage': true,
    'pickupLatitude': latitude,
    'pickupLongitude': longitude,
  };

  bool matches(Map<String, Object?> values) => rideSubmissionMatchesExisting(
    existing: values['existing']! as RideRequest,
    pickup: values['pickup']! as String,
    destination: values['destination']! as String,
    passengers: values['passengers']! as int,
    hasLuggage: values['hasLuggage']! as bool,
    pickupLatitude: values['pickupLatitude']! as double,
    pickupLongitude: values['pickupLongitude']! as double,
  );

  test('same idempotency payload includes identical GPS coordinates', () {
    expect(matches(payload()), isTrue);
  });

  test(
    'a changed latitude or longitude makes the idempotency payload differ',
    () {
      expect(matches(payload(latitude: 42.7001)), isFalse);
      expect(matches(payload(longitude: 23.3001)), isFalse);
    },
  );

  test(
    'address-only legacy submissions continue to match without coordinates',
    () {
      final addressOnlyRide = existing.copyWith(
        pickup: 'Sofia Center',
        pickupLatitude: null,
        pickupLongitude: null,
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
        ),
        isTrue,
      );
    },
  );
}
