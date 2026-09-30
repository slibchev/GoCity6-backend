import 'package:gocity6_backend/dispatch/atomic_waiting_ride_acceptance_repository.dart';
import 'package:gocity6_backend/ride/ride_dispatch_service.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:test/test.dart';

class FakeRideRequestRepository implements RideRequestRepository {
  final Map<String, RideRequest> _rides = {};

  FakeRideRequestRepository([Iterable<RideRequest> rides = const []]) {
    for (final ride in rides) {
      _rides[ride.id] = ride;
    }
  }

  @override
  Future<RideRequest?> findById(String id) async {
    return _rides[id];
  }

  @override
  Future<List<RideRequest>> findByAssignedDriverId(String driverId) async {
    return _rides.values
        .where((ride) => ride.assignedDriverId == driverId)
        .toList();
  }

  @override
  Future<void> save(RideRequest request) async {
    _rides[request.id] = request;
  }
}

class FakeAtomicWaitingRideAcceptanceRepository
    implements AtomicWaitingRideAcceptanceRepository {
  final RideRequest acceptedRide;
  final AtomicWaitingRideAcceptanceConflict? conflictToThrow;

  bool called = false;
  String? receivedRideId;
  String? receivedDriverId;

  FakeAtomicWaitingRideAcceptanceRepository({
    required this.acceptedRide,
    this.conflictToThrow,
  });

  @override
  Future<RideRequest> acceptWaitingRide({
    required String rideId,
    required String driverId,
  }) async {
    called = true;
    receivedRideId = rideId;
    receivedDriverId = driverId;

    final conflict = conflictToThrow;

    if (conflict != null) {
      throw AtomicWaitingRideAcceptanceConflictException(conflict);
    }

    return acceptedRide;
  }
}

void main() {
  RideRequest createRide({
    required String id,
    required RideRequestStatus status,
    String? assignedDriverId,
    String? assignedVehicleId,
  }) {
    return RideRequest(
      id: id,
      pickup: 'Pickup $id',
      destination: 'Destination $id',
      passengers: 1,
      requestedAt: DateTime(2026, 9, 26, 15, 0),
      status: status,
      assignedDriverId: assignedDriverId,
      assignedVehicleId: assignedVehicleId,
    );
  }

  test(
    'selectWaitingRide accepts ride when driver has no active ride',
    () async {
      final waitingRide = createRide(
        id: 'ride-001',
        status: RideRequestStatus.waitingForVehicle,
      );

      final repository = FakeRideRequestRepository([waitingRide]);

      final service = RideDispatchService(repository: repository);

      final result = await service.selectWaitingRide(
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
      );

      expect(result.status, RideRequestStatus.accepted);
      expect(result.assignedDriverId, 'driver-001');
      expect(result.assignedVehicleId, 'vehicle-001');
    },
  );

  test(
    'selectWaitingRide uses atomic acceptance when free-driver path is available',
    () async {
      final waitingRide = createRide(
        id: 'ride-atomic',
        status: RideRequestStatus.waitingForVehicle,
      );

      final acceptedRide = createRide(
        id: 'ride-atomic',
        status: RideRequestStatus.accepted,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-from-active-shift',
      );

      final repository = FakeRideRequestRepository([waitingRide]);

      final atomicRepository = FakeAtomicWaitingRideAcceptanceRepository(
        acceptedRide: acceptedRide,
      );

      final service = RideDispatchService(
        repository: repository,
        waitingRideAcceptanceRepository: atomicRepository,
      );

      final result = await service.selectWaitingRide(
        rideId: 'ride-atomic',
        driverId: 'driver-001',
        vehicleId: 'stale-client-vehicle',
      );

      expect(atomicRepository.called, isTrue);
      expect(atomicRepository.receivedRideId, 'ride-atomic');
      expect(atomicRepository.receivedDriverId, 'driver-001');

      expect(result.status, RideRequestStatus.accepted);
      expect(result.assignedDriverId, 'driver-001');
      expect(result.assignedVehicleId, 'vehicle-from-active-shift');
    },
  );

  test(
    'selectWaitingRide maps atomic unavailable driver to dispatch conflict',
    () async {
      final waitingRide = createRide(
        id: 'ride-atomic-conflict',
        status: RideRequestStatus.waitingForVehicle,
      );

      final repository = FakeRideRequestRepository([waitingRide]);

      final atomicRepository = FakeAtomicWaitingRideAcceptanceRepository(
        acceptedRide: waitingRide,
        conflictToThrow:
            AtomicWaitingRideAcceptanceConflict.driverNotAvailable,
      );

      final service = RideDispatchService(
        repository: repository,
        waitingRideAcceptanceRepository: atomicRepository,
      );

      expect(
        () => service.selectWaitingRide(
          rideId: 'ride-atomic-conflict',
          driverId: 'driver-001',
          vehicleId: 'vehicle-001',
        ),
        throwsA(
          isA<RideDispatchConflictException>().having(
            (error) => error.conflict,
            'conflict',
            RideDispatchConflict.driverNotAvailable,
          ),
        ),
      );
    },
  );

  test('selectWaitingRide reserves ride when driver has active ride', () async {
    final activeRide = createRide(
      id: 'ride-active',
      status: RideRequestStatus.inProgress,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final waitingRide = createRide(
      id: 'ride-waiting',
      status: RideRequestStatus.waitingForVehicle,
    );

    final repository = FakeRideRequestRepository([activeRide, waitingRide]);

    final service = RideDispatchService(repository: repository);

    final result = await service.selectWaitingRide(
      rideId: 'ride-waiting',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
    );

    expect(result.status, RideRequestStatus.reserved);
    expect(result.assignedDriverId, 'driver-001');
    expect(result.assignedVehicleId, 'vehicle-001');
  });

  test('driver cannot reserve a second next ride', () async {
    final activeRide = createRide(
      id: 'ride-active',
      status: RideRequestStatus.inProgress,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final reservedRide = createRide(
      id: 'ride-reserved',
      status: RideRequestStatus.reserved,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final waitingRide = createRide(
      id: 'ride-waiting',
      status: RideRequestStatus.waitingForVehicle,
    );

    final repository = FakeRideRequestRepository([
      activeRide,
      reservedRide,
      waitingRide,
    ]);

    final service = RideDispatchService(repository: repository);

    expect(
      () => service.selectWaitingRide(
        rideId: 'ride-waiting',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
      ),
      throwsA(
        isA<RideDispatchConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideDispatchConflict.driverAlreadyHasReservedRide,
        ),
      ),
    );
  });

  test(
    'reserved ride can be promoted after active ride is completed',
    () async {
      final completedRide = createRide(
        id: 'ride-completed',
        status: RideRequestStatus.completed,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
      );

      final reservedRide = createRide(
        id: 'ride-reserved',
        status: RideRequestStatus.reserved,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
      );

      final repository = FakeRideRequestRepository([
        completedRide,
        reservedRide,
      ]);

      final service = RideDispatchService(repository: repository);

      final result = await service.promoteReservedRide(
        rideId: 'ride-reserved',
        driverId: 'driver-001',
      );

      expect(result.status, RideRequestStatus.accepted);
      expect(result.assignedDriverId, 'driver-001');
      expect(result.assignedVehicleId, 'vehicle-001');
    },
  );

  test(
    'reserved ride cannot be promoted while driver has active ride',
    () async {
      final activeRide = createRide(
        id: 'ride-active',
        status: RideRequestStatus.inProgress,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
      );

      final reservedRide = createRide(
        id: 'ride-reserved',
        status: RideRequestStatus.reserved,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
      );

      final repository = FakeRideRequestRepository([activeRide, reservedRide]);

      final service = RideDispatchService(repository: repository);

      expect(
        () => service.promoteReservedRide(
          rideId: 'ride-reserved',
          driverId: 'driver-001',
        ),
        throwsA(
          isA<RideDispatchConflictException>().having(
            (error) => error.conflict,
            'conflict',
            RideDispatchConflict.driverStillHasActiveRide,
          ),
        ),
      );
    },
  );

  test('different driver cannot promote reserved ride', () async {
    final reservedRide = createRide(
      id: 'ride-reserved',
      status: RideRequestStatus.reserved,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final repository = FakeRideRequestRepository([reservedRide]);

    final service = RideDispatchService(repository: repository);

    expect(
      () => service.promoteReservedRide(
        rideId: 'ride-reserved',
        driverId: 'driver-002',
      ),
      throwsA(
        isA<RideDispatchConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideDispatchConflict.rideAssignedToAnotherDriver,
        ),
      ),
    );
  });

  test('selectWaitingRide rejects ride that is not waiting', () async {
    final ride = createRide(
      id: 'ride-001',
      status: RideRequestStatus.accepted,
      assignedDriverId: 'driver-002',
      assignedVehicleId: 'vehicle-002',
    );

    final repository = FakeRideRequestRepository([ride]);

    final service = RideDispatchService(repository: repository);

    expect(
      () => service.selectWaitingRide(
        rideId: 'ride-001',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
      ),
      throwsA(
        isA<RideDispatchConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideDispatchConflict.rideNotWaitingForVehicle,
        ),
      ),
    );
  });

  test('missing ride throws RideNotFoundException', () async {
    final repository = FakeRideRequestRepository();

    final service = RideDispatchService(repository: repository);

    expect(
      () => service.selectWaitingRide(
        rideId: 'missing',
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
      ),
      throwsA(isA<RideNotFoundException>()),
    );
  });
}
