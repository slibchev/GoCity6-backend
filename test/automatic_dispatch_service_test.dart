import 'package:gocity6_backend/dispatch/automatic_dispatch_service.dart';
import 'package:gocity6_backend/dispatch/dispatch_candidate.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_history.dart';
import 'package:test/test.dart';

void main() {
  const service = AutomaticDispatchService();

  final now = DateTime.utc(2026, 9, 27, 12);

  DriverQueueState state({
    required String driverId,
    required int priorityMinute,
  }) {
    return DriverQueueState(
      driverId: driverId,
      queuePrioritySince: DateTime.utc(2026, 9, 27, 10, priorityMinute),
    );
  }

  DispatchCandidate candidate({
    required String driverId,
    required int etaSeconds,
    required int distanceMeters,
    required DateTime prioritySince,
  }) {
    return DispatchCandidate(
      driverId: driverId,
      vehicleId: 'vehicle-$driverId',
      etaSeconds: etaSeconds,
      distanceMeters: distanceMeters,
      queuePrioritySince: prioritySince,
    );
  }

  RideOfferHistory emptyHistory() {
    return RideOfferHistory(rideId: 'ride-001', offers: const []);
  }

  group('AutomaticDispatchService', () {
    test('creates offer for best eligible candidate', () {
      final driver1 = state(driverId: 'driver-001', priorityMinute: 5);

      final driver2 = state(driverId: 'driver-002', priorityMinute: 10);

      final result = service.createNextOffer(
        rideId: 'ride-001',
        offerId: 'offer-001',
        now: now,
        candidates: [
          candidate(
            driverId: 'driver-001',
            etaSeconds: 360,
            distanceMeters: 500,
            prioritySince: driver1.queuePrioritySince,
          ),
          candidate(
            driverId: 'driver-002',
            etaSeconds: 240,
            distanceMeters: 1500,
            prioritySince: driver2.queuePrioritySince,
          ),
        ],
        driverStates: {'driver-001': driver1, 'driver-002': driver2},
        history: emptyHistory(),
      );

      expect(result, isNotNull);
      expect(result?.offer.driverId, 'driver-001');
      expect(result?.offer.status, RideOfferStatus.pending);
      expect(result?.driverState.hasPendingOffer, isTrue);
      expect(result?.history.attemptsUsed, 1);
    });

    test('rejected driver is moved to back of queue', () {
      final driver = state(driverId: 'driver-001', priorityMinute: 0);

      final started = service.createNextOffer(
        rideId: 'ride-001',
        offerId: 'offer-001',
        now: now,
        candidates: [
          candidate(
            driverId: 'driver-001',
            etaSeconds: 300,
            distanceMeters: 700,
            prioritySince: driver.queuePrioritySince,
          ),
        ],
        driverStates: {'driver-001': driver},
        history: emptyHistory(),
      )!;

      final rejectedAt = now.add(const Duration(seconds: 5));

      final rejected = service.rejectOffer(
        offer: started.offer,
        now: rejectedAt,
        driverState: started.driverState,
        history: started.history,
      );

      expect(rejected.offer.status, RideOfferStatus.rejected);

      expect(rejected.driverState.queuePrioritySince, rejectedAt);

      expect(rejected.driverState.hasPendingOffer, isFalse);
    });

    test('expired offer also moves driver to back', () {
      final driver = state(driverId: 'driver-001', priorityMinute: 0);

      final started = service.createNextOffer(
        rideId: 'ride-001',
        offerId: 'offer-001',
        now: now,
        candidates: [
          candidate(
            driverId: 'driver-001',
            etaSeconds: 300,
            distanceMeters: 700,
            prioritySince: driver.queuePrioritySince,
          ),
        ],
        driverStates: {'driver-001': driver},
        history: emptyHistory(),
      )!;

      final expired = service.expireOffer(
        offer: started.offer,
        now: started.offer.expiresAt,
        driverState: started.driverState,
        history: started.history,
      );

      expect(expired.offer.status, RideOfferStatus.expired);

      expect(expired.driverState.queuePrioritySince, started.offer.expiresAt);
    });

    test('accepted offer makes driver busy', () {
      final driver = state(driverId: 'driver-001', priorityMinute: 0);

      final started = service.createNextOffer(
        rideId: 'ride-001',
        offerId: 'offer-001',
        now: now,
        candidates: [
          candidate(
            driverId: 'driver-001',
            etaSeconds: 300,
            distanceMeters: 700,
            prioritySince: driver.queuePrioritySince,
          ),
        ],
        driverStates: {'driver-001': driver},
        history: emptyHistory(),
      )!;

      final accepted = service.acceptOffer(
        offer: started.offer,
        now: now.add(const Duration(seconds: 5)),
        driverState: started.driverState,
        history: started.history,
      );

      expect(accepted.offer.status, RideOfferStatus.accepted);

      expect(accepted.driverState.availability, DriverQueueAvailability.busy);

      expect(accepted.driverState.hasPendingOffer, isFalse);

      expect(accepted.history.hasAcceptedOffer, isTrue);
    });

    test('rejected driver is skipped for same ride', () {
      final driver1 = state(driverId: 'driver-001', priorityMinute: 0);

      final driver2 = state(driverId: 'driver-002', priorityMinute: 5);

      final candidates = [
        candidate(
          driverId: 'driver-001',
          etaSeconds: 300,
          distanceMeters: 700,
          prioritySince: driver1.queuePrioritySince,
        ),
        candidate(
          driverId: 'driver-002',
          etaSeconds: 320,
          distanceMeters: 750,
          prioritySince: driver2.queuePrioritySince,
        ),
      ];

      final first = service.createNextOffer(
        rideId: 'ride-001',
        offerId: 'offer-001',
        now: now,
        candidates: candidates,
        driverStates: {'driver-001': driver1, 'driver-002': driver2},
        history: emptyHistory(),
      )!;

      expect(first.offer.driverId, 'driver-001');

      final rejected = service.rejectOffer(
        offer: first.offer,
        now: now.add(const Duration(seconds: 5)),
        driverState: first.driverState,
        history: first.history,
      );

      final second = service.createNextOffer(
        rideId: 'ride-001',
        offerId: 'offer-002',
        now: now.add(const Duration(seconds: 6)),
        candidates: candidates,
        driverStates: {
          'driver-001': rejected.driverState,
          'driver-002': driver2,
        },
        history: rejected.history,
      );

      expect(second, isNotNull);

      expect(second?.offer.driverId, 'driver-002');
    });
    test('driver rejected in round 1 can receive same ride again '
        'in round 2 with 500 cent bonus', () {
      final driver = state(driverId: 'driver-001', priorityMinute: 0);

      final candidates = [
        candidate(
          driverId: 'driver-001',
          etaSeconds: 300,
          distanceMeters: 700,
          prioritySince: driver.queuePrioritySince,
        ),
      ];

      final roundOneOffer = service.createNextOffer(
        rideId: 'ride-001',
        offerId: 'offer-round-1',
        now: now,
        candidates: candidates,
        driverStates: {'driver-001': driver},
        history: emptyHistory(),
        dispatchRound: RideOffer.normalDispatchRound,
        bonusMinor: RideOffer.noBonusMinor,
      )!;

      expect(roundOneOffer.offer.dispatchRound, RideOffer.normalDispatchRound);
      expect(roundOneOffer.offer.bonusMinor, RideOffer.noBonusMinor);

      final rejected = service.rejectOffer(
        offer: roundOneOffer.offer,
        now: now.add(const Duration(seconds: 5)),
        driverState: roundOneOffer.driverState,
        history: roundOneOffer.history,
      );

      final roundTwoOffer = service.createNextOffer(
        rideId: 'ride-001',
        offerId: 'offer-round-2',
        now: now.add(const Duration(seconds: 6)),
        candidates: candidates,
        driverStates: {'driver-001': rejected.driverState},
        history: rejected.history,
        dispatchRound: RideOffer.bonusDispatchRound,
        bonusMinor: RideOffer.shortRideBonusMinor,
      );

      expect(roundTwoOffer, isNotNull);
      expect(roundTwoOffer?.offer.driverId, 'driver-001');
      expect(roundTwoOffer?.offer.dispatchRound, RideOffer.bonusDispatchRound);
      expect(roundTwoOffer?.offer.bonusMinor, RideOffer.shortRideBonusMinor);
      expect(roundTwoOffer?.offer.status, RideOfferStatus.pending);
      expect(roundTwoOffer?.history.attemptsUsed, 2);
    });

    test('continues through all eligible untried drivers '
        'and stops only when none remain', () {
      final driverStates = <String, DriverQueueState>{};
      final candidates = <DispatchCandidate>[];

      for (var i = 1; i <= 8; i++) {
        final driverId = 'driver-${i.toString().padLeft(3, '0')}';

        final driver = state(driverId: driverId, priorityMinute: i);

        driverStates[driverId] = driver;

        candidates.add(
          candidate(
            driverId: driverId,
            etaSeconds: 300,
            distanceMeters: 700,
            prioritySince: driver.queuePrioritySince,
          ),
        );
      }

      var history = emptyHistory();
      var currentTime = now;

      // Първите 7 отказват.
      for (var i = 1; i <= 7; i++) {
        final expectedDriverId = 'driver-${i.toString().padLeft(3, '0')}';

        final started = service.createNextOffer(
          rideId: 'ride-001',
          offerId: 'offer-$i',
          now: currentTime,
          candidates: candidates,
          driverStates: driverStates,
          history: history,
        );

        expect(started, isNotNull);

        expect(started?.offer.driverId, expectedDriverId);

        final rejectedAt = currentTime.add(const Duration(seconds: 5));

        final rejected = service.rejectOffer(
          offer: started!.offer,
          now: rejectedAt,
          driverState: started.driverState,
          history: started.history,
        );

        driverStates[expectedDriverId] = rejected.driverState;

        history = rejected.history;

        currentTime = rejectedAt.add(const Duration(seconds: 1));
      }

      // Осмият все още трябва да получи поръчката.
      final eighth = service.createNextOffer(
        rideId: 'ride-001',
        offerId: 'offer-8',
        now: currentTime,
        candidates: candidates,
        driverStates: driverStates,
        history: history,
      );

      expect(eighth, isNotNull);

      expect(eighth?.offer.driverId, 'driver-008');

      expect(eighth?.history.attemptsUsed, 8);

      final eighthRejectedAt = currentTime.add(const Duration(seconds: 5));

      final eighthRejected = service.rejectOffer(
        offer: eighth!.offer,
        now: eighthRejectedAt,
        driverState: eighth.driverState,
        history: eighth.history,
      );

      driverStates['driver-008'] = eighthRejected.driverState;

      history = eighthRejected.history;

      // Всичките 8 допустими шофьори вече
      // са получили тази rideId веднъж.
      final noCandidateLeft = service.createNextOffer(
        rideId: 'ride-001',
        offerId: 'offer-9',
        now: eighthRejectedAt.add(const Duration(seconds: 1)),
        candidates: candidates,
        driverStates: driverStates,
        history: history,
      );

      expect(noCandidateLeft, isNull);

      expect(history.attemptsUsed, 8);
    });

    test('no car within automatic ETA limit returns null', () {
      final driver = state(driverId: 'driver-001', priorityMinute: 0);

      final result = service.createNextOffer(
        rideId: 'ride-001',
        offerId: 'offer-001',
        now: now,
        candidates: [
          candidate(
            driverId: 'driver-001',
            etaSeconds: 601,
            distanceMeters: 300,
            prioritySince: driver.queuePrioritySince,
          ),
        ],
        driverStates: {'driver-001': driver},
        history: emptyHistory(),
      );

      expect(result, isNull);
    });

    test('cannot create second offer while first is pending', () {
      final driver = state(driverId: 'driver-001', priorityMinute: 0);

      final started = service.createNextOffer(
        rideId: 'ride-001',
        offerId: 'offer-001',
        now: now,
        candidates: [
          candidate(
            driverId: 'driver-001',
            etaSeconds: 300,
            distanceMeters: 700,
            prioritySince: driver.queuePrioritySince,
          ),
        ],
        driverStates: {'driver-001': driver},
        history: emptyHistory(),
      )!;

      expect(
        () => service.createNextOffer(
          rideId: 'ride-001',
          offerId: 'offer-002',
          now: now.add(const Duration(seconds: 1)),
          candidates: const [],
          driverStates: const {},
          history: started.history,
        ),
        throwsA(
          isA<AutomaticDispatchConflictException>().having(
            (error) => error.conflict,
            'conflict',
            AutomaticDispatchConflict.pendingOfferExists,
          ),
        ),
      );
    });
  });
}
