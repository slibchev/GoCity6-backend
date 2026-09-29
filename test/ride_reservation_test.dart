import 'package:gocity6_backend/dispatch/ride_reservation.dart';
import 'package:test/test.dart';

void main() {
  final reservedAt = DateTime.utc(2026, 9, 29, 12);

  group('RideReservation', () {
    test('new reservation starts active and preserves identity fields', () {
      final reservation = RideReservation.create(
        id: 'reservation-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        shiftId: 'shift-001',
        reservedAt: reservedAt,
      );

      expect(reservation.id, 'reservation-001');
      expect(reservation.rideId, 'ride-001');
      expect(reservation.driverId, 'driver-001');
      expect(reservation.vehicleId, 'vehicle-001');
      expect(reservation.shiftId, 'shift-001');
      expect(reservation.reservedAt, reservedAt);
      expect(reservation.endedAt, isNull);
      expect(reservation.isActive, isTrue);
    });

    test('ending reservation preserves reservation data', () {
      final endedAt = reservedAt.add(const Duration(minutes: 20));

      final reservation = RideReservation.create(
        id: 'reservation-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        shiftId: 'shift-001',
        reservedAt: reservedAt,
      ).end(endedAt);

      expect(reservation.id, 'reservation-001');
      expect(reservation.rideId, 'ride-001');
      expect(reservation.driverId, 'driver-001');
      expect(reservation.vehicleId, 'vehicle-001');
      expect(reservation.shiftId, 'shift-001');
      expect(reservation.reservedAt, reservedAt);
      expect(reservation.endedAt, endedAt);
      expect(reservation.isActive, isFalse);
    });

    test('ended reservation cannot be ended twice', () {
      final reservation = RideReservation.create(
        id: 'reservation-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        shiftId: 'shift-001',
        reservedAt: reservedAt,
      ).end(reservedAt.add(const Duration(minutes: 10)));

      expect(
        () => reservation.end(
          reservedAt.add(const Duration(minutes: 20)),
        ),
        throwsA(
          isA<RideReservationConflictException>().having(
            (error) => error.conflict,
            'conflict',
            RideReservationConflict.alreadyEnded,
          ),
        ),
      );
    });

    test('reservation cannot end before it was created', () {
      final reservation = RideReservation.create(
        id: 'reservation-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        shiftId: 'shift-001',
        reservedAt: reservedAt,
      );

      expect(
        () => reservation.end(
          reservedAt.subtract(const Duration(seconds: 1)),
        ),
        throwsArgumentError,
      );
    });

    test('restore can rebuild an active reservation', () {
      final reservation = RideReservation.restore(
        id: 'reservation-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        shiftId: 'shift-001',
        reservedAt: reservedAt,
        endedAt: null,
      );

      expect(reservation.isActive, isTrue);
      expect(reservation.endedAt, isNull);
    });

    test('restore can rebuild an ended reservation', () {
      final endedAt = reservedAt.add(const Duration(minutes: 15));

      final reservation = RideReservation.restore(
        id: 'reservation-001',
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        shiftId: 'shift-001',
        reservedAt: reservedAt,
        endedAt: endedAt,
      );

      expect(reservation.isActive, isFalse);
      expect(reservation.endedAt, endedAt);
    });

    test('restore rejects endedAt before reservedAt', () {
      expect(
        () => RideReservation.restore(
          id: 'reservation-001',
          rideId: 'ride-001',
          driverId: 'driver-001',
          vehicleId: 'vehicle-001',
          shiftId: 'shift-001',
          reservedAt: reservedAt,
          endedAt: reservedAt.subtract(const Duration(seconds: 1)),
        ),
        throwsArgumentError,
      );
    });
  });
}