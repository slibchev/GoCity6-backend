import 'package:gocity6_backend/dispatch/dispatch_candidate.dart';
import 'package:gocity6_backend/dispatch/dispatch_candidate_selector.dart';
import 'package:test/test.dart';

void main() {
  DispatchCandidate candidate({
    required String driverId,
    required int etaSeconds,
    required int distanceMeters,
    required DateTime queuePrioritySince,
    bool hasCustomerCancellationPriority = false,
  }) {
    return DispatchCandidate(
      driverId: driverId,
      vehicleId: 'vehicle-$driverId',
      etaSeconds: etaSeconds,
      distanceMeters: distanceMeters,
      queuePrioritySince: queuePrioritySince,
      hasCustomerCancellationPriority: hasCustomerCancellationPriority,
    );
  }

  group('DispatchCandidateSelector', () {
    const selector = DispatchCandidateSelector();

    test('returns null when there are no candidates', () {
      expect(selector.select([]), isNull);
    });

    test('returns null when every car is over 10 minutes away', () {
      final result = selector.select([
        candidate(
          driverId: 'driver-001',
          etaSeconds: 601,
          distanceMeters: 500,
          queuePrioritySince: DateTime.utc(2026, 9, 27, 10),
        ),
        candidate(
          driverId: 'driver-002',
          etaSeconds: 900,
          distanceMeters: 300,
          queuePrioritySince: DateTime.utc(2026, 9, 27, 9),
        ),
      ]);

      expect(result, isNull);
    });

    test('closer car wins when ETA difference is within tolerance', () {
      final result = selector.select([
        candidate(
          driverId: 'driver-001',
          etaSeconds: 360,
          distanceMeters: 500,
          queuePrioritySince: DateTime.utc(2026, 9, 27, 10),
        ),
        candidate(
          driverId: 'driver-002',
          etaSeconds: 240,
          distanceMeters: 1500,
          queuePrioritySince: DateTime.utc(2026, 9, 27, 9),
        ),
      ]);

      expect(result?.driverId, 'driver-001');
    });

    test('car outside ETA tolerance cannot win because of distance', () {
      final result = selector.select([
        candidate(
          driverId: 'driver-001',
          etaSeconds: 480,
          distanceMeters: 300,
          queuePrioritySince: DateTime.utc(2026, 9, 27, 9),
        ),
        candidate(
          driverId: 'driver-002',
          etaSeconds: 240,
          distanceMeters: 1500,
          queuePrioritySince: DateTime.utc(2026, 9, 27, 10),
        ),
      ]);

      expect(result?.driverId, 'driver-002');
    });

    test('longest waiting driver wins inside ETA and distance tolerances', () {
      final result = selector.select([
        candidate(
          driverId: 'driver-001',
          etaSeconds: 240,
          distanceMeters: 600,
          queuePrioritySince: DateTime.utc(2026, 9, 27, 10, 20),
        ),
        candidate(
          driverId: 'driver-002',
          etaSeconds: 360,
          distanceMeters: 900,
          queuePrioritySince: DateTime.utc(2026, 9, 27, 10),
        ),
      ]);

      expect(result?.driverId, 'driver-002');
    });

    test(
      'driver too far from best distance is excluded before queue priority',
      () {
        final result = selector.select([
          candidate(
            driverId: 'driver-001',
            etaSeconds: 300,
            distanceMeters: 500,
            queuePrioritySince: DateTime.utc(2026, 9, 27, 10, 20),
          ),
          candidate(
            driverId: 'driver-002',
            etaSeconds: 300,
            distanceMeters: 1100,
            queuePrioritySince: DateTime.utc(2026, 9, 27, 9),
          ),
        ]);

        expect(result?.driverId, 'driver-001');
      },
    );

    test('customer cancellation priority wins among eligible cars', () {
      final result = selector.select([
        candidate(
          driverId: 'driver-001',
          etaSeconds: 300,
          distanceMeters: 600,
          queuePrioritySince: DateTime.utc(2026, 9, 27, 9),
        ),
        candidate(
          driverId: 'driver-002',
          etaSeconds: 320,
          distanceMeters: 700,
          queuePrioritySince: DateTime.utc(2026, 9, 27, 10),
          hasCustomerCancellationPriority: true,
        ),
      ]);

      expect(result?.driverId, 'driver-002');
    });

    test('customer cancellation priority cannot bypass maximum ETA', () {
      final result = selector.select([
        candidate(
          driverId: 'driver-001',
          etaSeconds: 300,
          distanceMeters: 600,
          queuePrioritySince: DateTime.utc(2026, 9, 27, 10),
        ),
        candidate(
          driverId: 'driver-002',
          etaSeconds: 700,
          distanceMeters: 200,
          queuePrioritySince: DateTime.utc(2026, 9, 27, 9),
          hasCustomerCancellationPriority: true,
        ),
      ]);

      expect(result?.driverId, 'driver-001');
    });
  });
}
