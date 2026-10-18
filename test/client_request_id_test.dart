import 'package:test/test.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:gocity6_backend/ride/in_memory_ride_request_repository.dart';

void main() {
  const clientId = '11111111-2222-4333-8444-555555555555';

  RideRequest createRide() => RideRequest(
    id: 'ride-test-001',
    clientRequestId: clientId,
    pickup: 'Sofia Center',
    destination: 'Sofia Airport',
    passengers: 2,
    requestedAt: DateTime.utc(2026, 10, 18),
  );

  test('client request ID survives status transition', () {
    final ride = createRide();

    final updated = ride.transitionTo(RideRequestStatus.waitingForVehicle);

    expect(updated.clientRequestId, clientId);
    expect(updated.status, RideRequestStatus.waitingForVehicle);
  });

  test('existing ride can be found by client request ID', () async {
    final repository = InMemoryRideRequestRepository();
    final ride = createRide();

    await repository.save(ride);

    final found = await repository.findByClientRequestId(clientId);

    expect(found, isNotNull);
    expect(found!.id, ride.id);

    await repository.save(
      ride.transitionTo(RideRequestStatus.waitingForVehicle),
    );

    final updated = await repository.findByClientRequestId(clientId);

    expect(updated!.id, ride.id);
    expect(updated.status, RideRequestStatus.waitingForVehicle);
  });

  test('unknown client request ID returns null', () async {
    final repository = InMemoryRideRequestRepository();

    expect(await repository.findByClientRequestId('unknown'), isNull);
  });
}
