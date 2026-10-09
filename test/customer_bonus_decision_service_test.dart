import 'package:gocity6_backend/dispatch/atomic_ride_bonus_decision_repository.dart';
import 'package:gocity6_backend/dispatch/customer_bonus_decision_service.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:test/test.dart';

void main() {
  test('accepts bonus and continues automatic dispatch', () async {
    final repository = _FakeBonusDecisionRepository();

    String? continuedRideId;

    final service = CustomerBonusDecisionService(
      bonusDecisionRepository: repository,
      continueRide: ({required String rideId}) async {
        continuedRideId = rideId;
        return null;
      },
    );

    await service.accept(
      rideId: 'ride-001',
    );

    expect(repository.acceptedRideIds, ['ride-001']);
    expect(repository.declinedRideIds, isEmpty);
    expect(continuedRideId, 'ride-001');
  });

  test('declines bonus without continuing automatic dispatch', () async {
    final repository = _FakeBonusDecisionRepository();

    var continuationCalled = false;

    final service = CustomerBonusDecisionService(
      bonusDecisionRepository: repository,
      continueRide: ({required String rideId}) async {
        continuationCalled = true;
        return null;
      },
    );

    await service.decline(
      rideId: 'ride-002',
    );

    expect(repository.declinedRideIds, ['ride-002']);
    expect(repository.acceptedRideIds, isEmpty);
    expect(continuationCalled, isFalse);
  });
}

class _FakeBonusDecisionRepository
    implements AtomicRideBonusDecisionRepository {
  final List<String> acceptedRideIds = [];
  final List<String> declinedRideIds = [];

  @override
  Future<void> acceptFiveEuroBonus({
    required String rideId,
  }) async {
    acceptedRideIds.add(rideId);
  }

  @override
  Future<void> declineBonusAndMoveToWaitingForVehicle({
    required String rideId,
  }) async {
    declinedRideIds.add(rideId);
  }

  @override
  Future<void> markAwaitingCustomer({
    required String rideId,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<void> moveRoundOneWithoutOffersToWaitingForVehicle({
    required String rideId,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }

  @override
  Future<void> moveRoundTwoBonusToWaitingForVehicle({
    required String rideId,
  }) {
    throw UnsupportedError('Not needed by this test.');
  }
}