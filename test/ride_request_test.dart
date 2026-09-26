import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:gocity6_backend/ride/ride_state_machine.dart';
import 'package:test/test.dart';

void main() {
  RideRequest createRequest({
    RideRequestStatus status = RideRequestStatus.pending,
    String? assignedDriverId,
    String? assignedVehicleId,
    String? completedByDriverId,
    DateTime? completedAt,
  }) {
    return RideRequest(
      id: 'ride-001',
      pickup: 'Pickup address',
      destination: 'Destination address',
      passengers: 2,
      hasLuggage: true,
      requestedAt: DateTime(2026, 9, 26, 14, 0),
      status: status,
      assignedDriverId: assignedDriverId,
      assignedVehicleId: assignedVehicleId,
      completedByDriverId: completedByDriverId,
      completedAt: completedAt,
    );
  }

  test('RideRequest stores basic ride data', () {
    final request = createRequest();

    expect(request.id, 'ride-001');
    expect(request.pickup, 'Pickup address');
    expect(request.destination, 'Destination address');
    expect(request.passengers, 2);
    expect(request.hasLuggage, isTrue);
    expect(request.requestedAt, DateTime(2026, 9, 26, 14, 0));
    expect(request.status, RideRequestStatus.pending);
  });

  test('RideRequest stores driver and vehicle assignment', () {
    final request = createRequest(
      status: RideRequestStatus.reserved,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    expect(request.status, RideRequestStatus.reserved);
    expect(request.assignedDriverId, 'driver-001');
    expect(request.assignedVehicleId, 'vehicle-001');
  });

  test('RideRequest stores completion data', () {
    final completedAt = DateTime(2026, 9, 26, 14, 45);

    final request = createRequest(
      status: RideRequestStatus.completed,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
      completedByDriverId: 'driver-001',
      completedAt: completedAt,
    );

    expect(request.completedByDriverId, 'driver-001');
    expect(request.completedAt, completedAt);
  });

  test('copyWith keeps nullable values when values are not provided', () {
    final completedAt = DateTime(2026, 9, 26, 14, 45);

    final request = createRequest(
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
      completedByDriverId: 'driver-001',
      completedAt: completedAt,
    );

    final updated = request.copyWith(pickup: 'Updated pickup');

    expect(updated.pickup, 'Updated pickup');

    expect(updated.assignedDriverId, 'driver-001');
    expect(updated.assignedVehicleId, 'vehicle-001');
    expect(updated.completedByDriverId, 'driver-001');
    expect(updated.completedAt, completedAt);

    expect(updated.status, request.status);
  });

  test('copyWith can clear driver and vehicle assignment', () {
    final request = createRequest(
      status: RideRequestStatus.reserved,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final updated = request.copyWith(
      assignedDriverId: null,
      assignedVehicleId: null,
    );

    expect(updated.status, RideRequestStatus.reserved);
    expect(updated.assignedDriverId, isNull);
    expect(updated.assignedVehicleId, isNull);
  });

  test('copyWith can clear completion data', () {
    final request = createRequest(
      completedByDriverId: 'driver-001',
      completedAt: DateTime(2026, 9, 26, 14, 45),
    );

    final updated = request.copyWith(
      completedByDriverId: null,
      completedAt: null,
    );

    expect(updated.completedByDriverId, isNull);
    expect(updated.completedAt, isNull);
  });

  test('copyWith updates ordinary ride data without changing status', () {
    final request = createRequest(status: RideRequestStatus.waitingForVehicle);

    final updated = request.copyWith(
      pickup: 'New pickup',
      destination: 'New destination',
      passengers: 3,
      hasLuggage: false,
    );

    expect(updated.pickup, 'New pickup');
    expect(updated.destination, 'New destination');
    expect(updated.passengers, 3);
    expect(updated.hasLuggage, isFalse);

    expect(updated.id, request.id);
    expect(updated.requestedAt, request.requestedAt);
    expect(updated.status, RideRequestStatus.waitingForVehicle);
  });

  test('transitionTo performs a valid status transition', () {
    final request = createRequest(
      status: RideRequestStatus.inProgress,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final updated = request.transitionTo(RideRequestStatus.completed);

    expect(updated.status, RideRequestStatus.completed);

    expect(updated.id, request.id);
    expect(updated.pickup, request.pickup);
    expect(updated.destination, request.destination);
    expect(updated.assignedDriverId, 'driver-001');
    expect(updated.assignedVehicleId, 'vehicle-001');

    expect(request.status, RideRequestStatus.inProgress);
  });

  test('transitionTo rejects an invalid transition', () {
    final request = createRequest(status: RideRequestStatus.waitingForVehicle);

    expect(
      () => request.transitionTo(RideRequestStatus.completed),
      throwsA(isA<RideStateTransitionException>()),
    );
  });

  test('transitionTo rejects transition to the same status', () {
    final request = createRequest(status: RideRequestStatus.accepted);

    expect(
      () => request.transitionTo(RideRequestStatus.accepted),
      throwsA(isA<RideStateTransitionException>()),
    );
  });

  test('terminal rides cannot transition to another status', () {
    final completed = createRequest(status: RideRequestStatus.completed);

    final cancelled = createRequest(status: RideRequestStatus.cancelled);

    expect(
      () => completed.transitionTo(RideRequestStatus.inProgress),
      throwsA(isA<RideStateTransitionException>()),
    );

    expect(
      () => cancelled.transitionTo(RideRequestStatus.accepted),
      throwsA(isA<RideStateTransitionException>()),
    );
  });
  test('RideRequest uses EUR by default', () {
    final request = createRequest();

    expect(request.currency, 'EUR');
  });

  test('RideRequest stores and preserves financial data', () {
    final request = createRequest().copyWith(
      meterFareMinor: 1234,
      commissionRateBps: 1000,
      commissionAmountMinor: 123,
    );

    final updated = request.copyWith(pickup: 'Updated pickup');

    expect(updated.currency, 'EUR');
    expect(updated.meterFareMinor, 1234);
    expect(updated.commissionRateBps, 1000);
    expect(updated.commissionAmountMinor, 123);
  });
}
