import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:test/test.dart';

void main() {
  RideRequest createRide() {
    return RideRequest(
      id: 'ride-001',
      pickup: 'Pickup',
      destination: 'Destination',
      passengers: 1,
      requestedAt: DateTime.utc(2026, 9, 28, 10),
    );
  }

  group('RideRequest dispatch bonus', () {
    test('new ride starts in round 1 without bonus', () {
      final ride = createRide();

      expect(ride.dispatchRound, RideRequest.normalDispatchRound);
      expect(ride.driverBonusMinor, RideRequest.noDriverBonusMinor);
      expect(ride.bonusDecision, RideBonusDecision.notOffered);
    });

    test('ride can wait for customer bonus decision', () {
      final ride = createRide().copyWith(
        bonusDecision: RideBonusDecision.awaitingCustomer,
      );

      expect(ride.dispatchRound, RideRequest.normalDispatchRound);
      expect(ride.driverBonusMinor, RideRequest.noDriverBonusMinor);
      expect(ride.bonusDecision, RideBonusDecision.awaitingCustomer);
    });

    test('customer can decline bonus and keep round 1', () {
      final ride = createRide().copyWith(
        bonusDecision: RideBonusDecision.declined,
      );

      expect(ride.dispatchRound, RideRequest.normalDispatchRound);
      expect(ride.driverBonusMinor, RideRequest.noDriverBonusMinor);
      expect(ride.bonusDecision, RideBonusDecision.declined);
    });

    test('customer can accept bonus and start round 2', () {
      final ride = createRide().copyWith(
        dispatchRound: RideRequest.bonusDispatchRound,
        driverBonusMinor: RideRequest.driverBonusFiveEuroMinor,
        bonusDecision: RideBonusDecision.accepted,
      );

      expect(ride.dispatchRound, RideRequest.bonusDispatchRound);
      expect(ride.driverBonusMinor, RideRequest.driverBonusFiveEuroMinor);
      expect(ride.bonusDecision, RideBonusDecision.accepted);
    });

    test('status transition preserves dispatch bonus state', () {
      final bonusRide = createRide().copyWith(
        dispatchRound: RideRequest.bonusDispatchRound,
        driverBonusMinor: RideRequest.driverBonusFiveEuroMinor,
        bonusDecision: RideBonusDecision.accepted,
      );

      final waitingRide = bonusRide.transitionTo(
        RideRequestStatus.waitingForVehicle,
      );

      expect(waitingRide.status, RideRequestStatus.waitingForVehicle);
      expect(waitingRide.dispatchRound, RideRequest.bonusDispatchRound);
      expect(
        waitingRide.driverBonusMinor,
        RideRequest.driverBonusFiveEuroMinor,
      );
      expect(waitingRide.bonusDecision, RideBonusDecision.accepted);
    });

    test('bonus decision database values round trip correctly', () {
      for (final decision in RideBonusDecision.values) {
        final restored = RideBonusDecision.fromDatabaseValue(
          decision.databaseValue,
        );

        expect(restored, decision);
      }
    });
  });
}
