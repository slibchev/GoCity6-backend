import 'package:gocity6_backend/dispatch/dispatch_candidate.dart';
import 'package:gocity6_backend/dispatch/dispatch_candidate_selector.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:test/test.dart';

void main() {
  const selector = DispatchCandidateSelector();

  DispatchCandidate candidateFromState({
    required DriverQueueState state,
    required DateTime now,
    int etaSeconds = 300,
    int distanceMeters = 700,
  }) {
    final candidate = DispatchCandidate.fromQueueState(
      queueState: state,
      vehicleId: 'vehicle-${state.driverId}',
      etaSeconds: etaSeconds,
      distanceMeters: distanceMeters,
      now: now,
    );

    if (candidate == null) {
      throw StateError('Expected ${state.driverId} to be eligible.');
    }

    return candidate;
  }

  group('Driver queue and dispatch integration', () {
    test('driver on active short break is not a dispatch candidate', () {
      final state = DriverQueueState(
        driverId: 'driver-001',
        queuePrioritySince: DateTime.utc(2026, 9, 27, 10),
      ).startShortBreak(DateTime.utc(2026, 9, 27, 11));

      final candidate = DispatchCandidate.fromQueueState(
        queueState: state,
        vehicleId: 'vehicle-001',
        etaSeconds: 300,
        distanceMeters: 700,
        now: DateTime.utc(2026, 9, 27, 11, 5),
      );

      expect(candidate, isNull);
    });

    test('driver becomes eligible automatically when short break expires', () {
      final originalPriority = DateTime.utc(2026, 9, 27, 10);

      final state = DriverQueueState(
        driverId: 'driver-001',
        queuePrioritySince: originalPriority,
      ).startShortBreak(DateTime.utc(2026, 9, 27, 11));

      final candidate = DispatchCandidate.fromQueueState(
        queueState: state,
        vehicleId: 'vehicle-001',
        etaSeconds: 300,
        distanceMeters: 700,
        now: DateTime.utc(2026, 9, 27, 11, 10),
      );

      expect(candidate, isNotNull);
      expect(candidate?.queuePrioritySince, originalPriority);
    });

    test('driver on long break is not a dispatch candidate', () {
      final state = DriverQueueState(
        driverId: 'driver-001',
        queuePrioritySince: DateTime.utc(2026, 9, 27, 10),
      ).startLongBreak(DateTime.utc(2026, 9, 27, 11));

      final candidate = DispatchCandidate.fromQueueState(
        queueState: state,
        vehicleId: 'vehicle-001',
        etaSeconds: 300,
        distanceMeters: 700,
        now: DateTime.utc(2026, 9, 27, 12),
      );

      expect(candidate, isNull);
    });

    test('driver with pending offer cannot receive another offer', () {
      final state = DriverQueueState(
        driverId: 'driver-001',
        queuePrioritySince: DateTime.utc(2026, 9, 27, 10),
      ).beginOffer();

      final candidate = DispatchCandidate.fromQueueState(
        queueState: state,
        vehicleId: 'vehicle-001',
        etaSeconds: 300,
        distanceMeters: 700,
        now: DateTime.utc(2026, 9, 27, 11),
      );

      expect(candidate, isNull);
    });

    test(
      'returning driver keeps old priority but position is recalculated',
      () {
        final now = DateTime.utc(2026, 9, 27, 11, 5);

        final driverB = DriverQueueState(
          driverId: 'driver-B',
          queuePrioritySince: DateTime.utc(2026, 9, 27, 10, 3),
        );

        final driverC = DriverQueueState(
          driverId: 'driver-C',
          queuePrioritySince: DateTime.utc(2026, 9, 27, 10, 5),
        ).startShortBreak(DateTime.utc(2026, 9, 27, 11)).returnFromBreak(now);

        final driverD = DriverQueueState(
          driverId: 'driver-D',
          queuePrioritySince: DateTime.utc(2026, 9, 27, 10, 8),
        );

        final ranked = selector.rank([
          candidateFromState(state: driverB, now: now),
          candidateFromState(state: driverC, now: now),
          candidateFromState(state: driverD, now: now),
        ]);

        expect(ranked.map((candidate) => candidate.driverId), [
          'driver-B',
          'driver-C',
          'driver-D',
        ]);
      },
    );

    test('driver formerly third becomes first when older cars have left', () {
      final now = DateTime.utc(2026, 9, 27, 11, 5);

      final returningDriver = DriverQueueState(
        driverId: 'driver-C',
        queuePrioritySince: DateTime.utc(2026, 9, 27, 10, 5),
      ).startShortBreak(DateTime.utc(2026, 9, 27, 11)).returnFromBreak(now);

      final remainingDriver = DriverQueueState(
        driverId: 'driver-D',
        queuePrioritySince: DateTime.utc(2026, 9, 27, 10, 8),
      );

      final ranked = selector.rank([
        candidateFromState(state: returningDriver, now: now),
        candidateFromState(state: remainingDriver, now: now),
      ]);

      expect(ranked[0].driverId, 'driver-C');
      expect(ranked[1].driverId, 'driver-D');
    });

    test('driver formerly third becomes second when one older car remains', () {
      final now = DateTime.utc(2026, 9, 27, 11, 5);

      final olderDriver = DriverQueueState(
        driverId: 'driver-B',
        queuePrioritySince: DateTime.utc(2026, 9, 27, 10, 3),
      );

      final returningDriver = DriverQueueState(
        driverId: 'driver-C',
        queuePrioritySince: DateTime.utc(2026, 9, 27, 10, 5),
      ).startShortBreak(DateTime.utc(2026, 9, 27, 11)).returnFromBreak(now);

      final ranked = selector.rank([
        candidateFromState(state: olderDriver, now: now),
        candidateFromState(state: returningDriver, now: now),
      ]);

      expect(ranked[0].driverId, 'driver-B');
      expect(ranked[1].driverId, 'driver-C');
    });
  });
}
