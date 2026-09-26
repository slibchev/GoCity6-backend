import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:gocity6_backend/ride/ride_state_machine.dart';
import 'package:test/test.dart';

void main() {
  group('RideStateMachine', () {
    test('allows exactly the expected transitions', () {
      const expectedTransitions = {
        RideRequestStatus.pending: {
          RideRequestStatus.waitingForVehicle,
          RideRequestStatus.accepted,
          RideRequestStatus.cancelled,
        },
        RideRequestStatus.waitingForVehicle: {
          RideRequestStatus.reserved,
          RideRequestStatus.accepted,
          RideRequestStatus.cancelled,
        },
        RideRequestStatus.reserved: {
          RideRequestStatus.accepted,
          RideRequestStatus.waitingForVehicle,
          RideRequestStatus.cancelled,
        },
        RideRequestStatus.accepted: {
          RideRequestStatus.driverArriving,
          RideRequestStatus.cancelled,
        },
        RideRequestStatus.driverArriving: {
          RideRequestStatus.inProgress,
          RideRequestStatus.cancelled,
        },
        RideRequestStatus.inProgress: {RideRequestStatus.completed},
        RideRequestStatus.completed: <RideRequestStatus>{},
        RideRequestStatus.cancelled: <RideRequestStatus>{},
      };

      for (final from in RideRequestStatus.values) {
        for (final to in RideRequestStatus.values) {
          final expected = expectedTransitions[from]!.contains(to);

          expect(
            RideStateMachine.canTransition(from: from, to: to),
            expected,
            reason: 'Unexpected result for ${from.name} -> ${to.name}',
          );
        }
      }
    });

    test('completed and cancelled are terminal states', () {
      expect(RideRequestStatus.completed.isTerminal, isTrue);
      expect(RideRequestStatus.cancelled.isTerminal, isTrue);

      expect(
        RideStateMachine.allowedTransitionsFrom(RideRequestStatus.completed),
        isEmpty,
      );

      expect(
        RideStateMachine.allowedTransitionsFrom(RideRequestStatus.cancelled),
        isEmpty,
      );
    });

    test('validateTransition accepts a valid transition', () {
      expect(
        () => RideStateMachine.validateTransition(
          from: RideRequestStatus.inProgress,
          to: RideRequestStatus.completed,
        ),
        returnsNormally,
      );
    });

    test('validateTransition rejects an invalid transition', () {
      expect(
        () => RideStateMachine.validateTransition(
          from: RideRequestStatus.waitingForVehicle,
          to: RideRequestStatus.completed,
        ),
        throwsA(isA<RideStateTransitionException>()),
      );
    });

    test('ride cannot transition to the same status', () {
      for (final status in RideRequestStatus.values) {
        expect(
          RideStateMachine.canTransition(from: status, to: status),
          isFalse,
          reason: '${status.name} must not transition to itself',
        );
      }
    });

    test('cancellation rules match ride lifecycle', () {
      expect(RideRequestStatus.pending.canBeCancelled, isTrue);
      expect(RideRequestStatus.waitingForVehicle.canBeCancelled, isTrue);
      expect(RideRequestStatus.reserved.canBeCancelled, isTrue);
      expect(RideRequestStatus.accepted.canBeCancelled, isTrue);
      expect(RideRequestStatus.driverArriving.canBeCancelled, isTrue);

      expect(RideRequestStatus.inProgress.canBeCancelled, isFalse);
      expect(RideRequestStatus.completed.canBeCancelled, isFalse);
      expect(RideRequestStatus.cancelled.canBeCancelled, isFalse);
    });
  });
}
