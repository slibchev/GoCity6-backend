import 'package:gocity6_backend/ride/in_memory_ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:test/test.dart';

void main() {
  RideRequest createRide({
    required String id,
    RideRequestStatus status = RideRequestStatus.waitingForVehicle,
    String? assignedDriverId,
    String? assignedVehicleId,
  }) {
    return RideRequest(
      id: id,
      pickup: 'Pickup $id',
      destination: 'Destination $id',
      passengers: 1,
      requestedAt: DateTime(2026, 9, 26, 17, 0),
      status: status,
      assignedDriverId: assignedDriverId,
      assignedVehicleId: assignedVehicleId,
    );
  }

  test('findById returns stored ride', () async {
    final ride = createRide(id: 'ride-001');

    final repository = InMemoryRideRequestRepository([ride]);

    final result = await repository.findById('ride-001');

    expect(result, same(ride));
  });

  test('findById returns null for missing ride', () async {
    final repository = InMemoryRideRequestRepository();

    final result = await repository.findById('missing');

    expect(result, isNull);
  });

  test('save stores a new ride', () async {
    final repository = InMemoryRideRequestRepository();

    final ride = createRide(id: 'ride-001');

    await repository.save(ride);

    final stored = await repository.findById('ride-001');

    expect(stored, same(ride));
  });

  test('save replaces ride with the same id', () async {
    final originalRide = createRide(id: 'ride-001');

    final repository = InMemoryRideRequestRepository([originalRide]);

    final updatedRide = originalRide.transitionTo(RideRequestStatus.accepted);

    await repository.save(updatedRide);

    final stored = await repository.findById('ride-001');

    expect(stored?.status, RideRequestStatus.accepted);
  });

  test(
    'findByAssignedDriverId returns only rides assigned to driver',
    () async {
      final firstDriverRide = createRide(
        id: 'ride-001',
        status: RideRequestStatus.inProgress,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
      );

      final secondDriverRide = createRide(
        id: 'ride-002',
        status: RideRequestStatus.reserved,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
      );

      final otherDriverRide = createRide(
        id: 'ride-003',
        status: RideRequestStatus.accepted,
        assignedDriverId: 'driver-002',
        assignedVehicleId: 'vehicle-002',
      );

      final unassignedRide = createRide(id: 'ride-004');

      final repository = InMemoryRideRequestRepository([
        firstDriverRide,
        secondDriverRide,
        otherDriverRide,
        unassignedRide,
      ]);

      final result = await repository.findByAssignedDriverId('driver-001');

      expect(result, hasLength(2));

      expect(result.map((ride) => ride.id).toSet(), {'ride-001', 'ride-002'});
    },
  );
}
