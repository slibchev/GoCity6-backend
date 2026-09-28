import 'package:gocity6_backend/dispatch/external_ride_session.dart';
import 'package:test/test.dart';

void main() {
  final startedAt = DateTime.utc(2026, 9, 29, 10);

  group('ExternalRideSession', () {
    test('new external ride starts active at zero meters', () {
      final session = ExternalRideSession.create(
        id: 'external-001',
        driverId: 'driver-001',
        startedAt: startedAt,
      );

      expect(session.isActive, isTrue);
      expect(session.distanceMeters, 0);
      expect(session.qualifiesAsExternalRide, isFalse);
      expect(session.remainingMetersToQualify, 500);
      expect(session.wasTriggeredByPendingOffer, isFalse);
      expect(session.triggerOfferId, isNull);
      expect(session.triggerRideId, isNull);
    });

    test(
      'external ride can remember pending offer that triggered busy mode',
      () {
        final session = ExternalRideSession.create(
          id: 'external-001',
          driverId: 'driver-001',
          startedAt: startedAt,
          triggerOfferId: 'offer-001',
          triggerRideId: 'ride-001',
        );

        expect(session.wasTriggeredByPendingOffer, isTrue);
        expect(session.triggerOfferId, 'offer-001');
        expect(session.triggerRideId, 'ride-001');
      },
    );

    test(
      'verified route segments accumulate instead of using endpoint distance',
      () {
        var session = ExternalRideSession.create(
          id: 'external-001',
          driverId: 'driver-001',
          startedAt: startedAt,
        );

        session = session.addVerifiedDistance(90);
        session = session.addVerifiedDistance(140);
        session = session.addVerifiedDistance(180);
        session = session.addVerifiedDistance(120);

        expect(session.distanceMeters, 530);
        expect(session.qualifiesAsExternalRide, isTrue);
        expect(session.remainingMetersToQualify, 0);
      },
    );

    test('499 meters does not qualify but exactly 500 meters does', () {
      var session = ExternalRideSession.create(
        id: 'external-001',
        driverId: 'driver-001',
        startedAt: startedAt,
      );

      session = session.addVerifiedDistance(499);

      expect(session.distanceMeters, 499);
      expect(session.qualifiesAsExternalRide, isFalse);
      expect(session.remainingMetersToQualify, 1);

      session = session.addVerifiedDistance(1);

      expect(session.distanceMeters, 500);
      expect(session.qualifiesAsExternalRide, isTrue);
      expect(session.remainingMetersToQualify, 0);
    });

    test('finishing external ride preserves accumulated data', () {
      final finishedAt = DateTime.utc(2026, 9, 29, 10, 20);

      final session = ExternalRideSession.create(
        id: 'external-001',
        driverId: 'driver-001',
        startedAt: startedAt,
        triggerOfferId: 'offer-001',
        triggerRideId: 'ride-001',
      ).addVerifiedDistance(650).finish(finishedAt);

      expect(session.isActive, isFalse);
      expect(session.endedAt, finishedAt);
      expect(session.distanceMeters, 650);
      expect(session.qualifiesAsExternalRide, isTrue);
      expect(session.triggerOfferId, 'offer-001');
      expect(session.triggerRideId, 'ride-001');
    });

    test('finished session cannot receive more distance or finish twice', () {
      final session = ExternalRideSession.create(
        id: 'external-001',
        driverId: 'driver-001',
        startedAt: startedAt,
      ).finish(startedAt.add(const Duration(minutes: 10)));

      expect(
        () => session.addVerifiedDistance(100),
        throwsA(
          isA<ExternalRideSessionConflictException>().having(
            (error) => error.conflict,
            'conflict',
            ExternalRideSessionConflict.alreadyFinished,
          ),
        ),
      );

      expect(
        () => session.finish(startedAt.add(const Duration(minutes: 20))),
        throwsA(
          isA<ExternalRideSessionConflictException>().having(
            (error) => error.conflict,
            'conflict',
            ExternalRideSessionConflict.alreadyFinished,
          ),
        ),
      );
    });

    test('negative verified distance is rejected', () {
      final session = ExternalRideSession.create(
        id: 'external-001',
        driverId: 'driver-001',
        startedAt: startedAt,
      );

      expect(() => session.addVerifiedDistance(-1), throwsArgumentError);
    });

    test('trigger offer and ride ids must always be provided together', () {
      expect(
        () => ExternalRideSession.create(
          id: 'external-001',
          driverId: 'driver-001',
          startedAt: startedAt,
          triggerOfferId: 'offer-001',
        ),
        throwsArgumentError,
      );

      expect(
        () => ExternalRideSession.create(
          id: 'external-002',
          driverId: 'driver-001',
          startedAt: startedAt,
          triggerRideId: 'ride-001',
        ),
        throwsArgumentError,
      );
    });

    test('restore performs production validation', () {
      expect(
        () => ExternalRideSession.restore(
          id: 'external-001',
          driverId: 'driver-001',
          startedAt: startedAt,
          endedAt: null,
          distanceMeters: -1,
          triggerOfferId: null,
          triggerRideId: null,
        ),
        throwsArgumentError,
      );

      expect(
        () => ExternalRideSession.restore(
          id: 'external-002',
          driverId: 'driver-001',
          startedAt: startedAt,
          endedAt: startedAt.subtract(const Duration(seconds: 1)),
          distanceMeters: 500,
          triggerOfferId: null,
          triggerRideId: null,
        ),
        throwsArgumentError,
      );
    });
  });
}
