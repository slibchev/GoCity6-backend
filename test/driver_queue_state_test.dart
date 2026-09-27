import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:test/test.dart';

void main() {
  final originalPriority = DateTime.utc(2026, 9, 27, 10);

  DriverQueueState createState({int shortBreaksUsed = 0}) {
    return DriverQueueState(
      driverId: 'driver-001',
      queuePrioritySince: originalPriority,
      shortBreaksUsed: shortBreaksUsed,
    );
  }

  group('DriverQueueState', () {
    test('short break consumes one allowance and preserves priority', () {
      final breakStartedAt = DateTime.utc(2026, 9, 27, 11);

      final state = createState().startShortBreak(breakStartedAt);

      expect(state.availability, DriverQueueAvailability.shortBreak);
      expect(state.shortBreaksUsed, 1);
      expect(state.shortBreaksRemaining, 2);
      expect(state.breakStartedAt, breakStartedAt);
      expect(state.queuePrioritySince, originalPriority);
    });

    test('returning early from short break preserves priority', () {
      final state = createState()
          .startShortBreak(DateTime.utc(2026, 9, 27, 11))
          .returnFromBreak(DateTime.utc(2026, 9, 27, 11, 5));

      expect(state.availability, DriverQueueAvailability.available);
      expect(state.queuePrioritySince, originalPriority);
      expect(state.breakStartedAt, isNull);
    });

    test('short break remains active before ten minutes', () {
      final state = createState().startShortBreak(
        DateTime.utc(2026, 9, 27, 11),
      );

      final effectiveState = state.effectiveAt(
        DateTime.utc(2026, 9, 27, 11, 9, 59),
      );

      expect(effectiveState.availability, DriverQueueAvailability.shortBreak);
    });

    test('short break automatically ends at ten minutes', () {
      final state = createState().startShortBreak(
        DateTime.utc(2026, 9, 27, 11),
      );

      final effectiveState = state.effectiveAt(
        DateTime.utc(2026, 9, 27, 11, 10),
      );

      expect(effectiveState.availability, DriverQueueAvailability.available);
      expect(effectiveState.queuePrioritySince, originalPriority);
      expect(effectiveState.breakStartedAt, isNull);
    });

    test('three short breaks are allowed but fourth is rejected', () {
      var state = createState();

      for (var i = 0; i < 3; i++) {
        final start = DateTime.utc(2026, 9, 27, 11 + i);

        state = state
            .startShortBreak(start)
            .returnFromBreak(start.add(const Duration(minutes: 5)));
      }

      expect(state.shortBreaksUsed, 3);
      expect(state.shortBreaksRemaining, 0);

      expect(
        () => state.startShortBreak(DateTime.utc(2026, 9, 27, 15)),
        throwsA(
          isA<DriverQueueConflictException>().having(
            (error) => error.conflict,
            'conflict',
            DriverQueueConflict.noShortBreaksRemaining,
          ),
        ),
      );
    });

    test('long break does not consume short break allowance', () {
      final state = createState(shortBreaksUsed: 2)
          .startLongBreak(DateTime.utc(2026, 9, 27, 11));

      expect(state.availability, DriverQueueAvailability.longBreak);
      expect(state.shortBreaksUsed, 2);
      expect(state.shortBreaksRemaining, 1);
    });

    test('returning from long break moves driver to back', () {
      final returnedAt = DateTime.utc(2026, 9, 27, 12);

      final state = createState()
          .startLongBreak(DateTime.utc(2026, 9, 27, 11))
          .returnFromBreak(returnedAt);

      expect(state.availability, DriverQueueAvailability.available);
      expect(state.queuePrioritySince, returnedAt);
    });

    test('driver cannot start short break with pending offer', () {
      final state = createState().beginOffer();

      expect(
        () => state.startShortBreak(DateTime.utc(2026, 9, 27, 11)),
        throwsA(
          isA<DriverQueueConflictException>().having(
            (error) => error.conflict,
            'conflict',
            DriverQueueConflict.activeOffer,
          ),
        ),
      );
    });

    test('driver cannot start long break with pending offer', () {
      final state = createState().beginOffer();

      expect(
        () => state.startLongBreak(DateTime.utc(2026, 9, 27, 11)),
        throwsA(
          isA<DriverQueueConflictException>().having(
            (error) => error.conflict,
            'conflict',
            DriverQueueConflict.activeOffer,
          ),
        ),
      );
    });

    test('explicit offer rejection moves driver to back', () {
      final rejectedAt = DateTime.utc(2026, 9, 27, 11);

      final state = createState().beginOffer().rejectOffer(rejectedAt);

      expect(state.hasPendingOffer, isFalse);
      expect(state.queuePrioritySince, rejectedAt);
    });

    test('offer timeout moves driver to back', () {
      final expiredAt = DateTime.utc(2026, 9, 27, 11);

      final state = createState().beginOffer().expireOffer(expiredAt);

      expect(state.hasPendingOffer, isFalse);
      expect(state.queuePrioritySince, expiredAt);
    });

    test('driver is exposed to timeout penalty after short break expires', () {
      final shortBreakStartedAt = DateTime.utc(2026, 9, 27, 11);

      final offerExpiredAt = DateTime.utc(2026, 9, 27, 11, 10, 15);

      final state = createState()
          .startShortBreak(shortBreakStartedAt)
          .effectiveAt(DateTime.utc(2026, 9, 27, 11, 10))
          .beginOffer()
          .expireOffer(offerExpiredAt);

      expect(state.availability, DriverQueueAvailability.available);

      expect(state.queuePrioritySince, offerExpiredAt);
    });
  });
}
