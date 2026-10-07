import 'package:gocity6_backend/ride/atomic_ride_completion_repository.dart';
import 'package:gocity6_backend/ride/ride_lifecycle_service.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:test/test.dart';
import 'package:gocity6_backend/ride/atomic_ride_cancellation_repository.dart';
import 'package:gocity6_backend/ride/atomic_reserved_ride_cancellation_repository.dart';

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

class AtomicFakeRideRequestRepository extends FakeRideRequestRepository
    implements AtomicRideCompletionRepository {
  bool atomicCompletionCalled = false;
  RideRequest? atomicCompletedRide;
  AtomicRideCompletionConflict? conflictToThrow;

  AtomicFakeRideRequestRepository([
    super.rides = const [],
    this.conflictToThrow,
  ]);

  @override
  Future<void> save(RideRequest request) async {
    throw StateError(
      'save() must not be called when atomic completion is available.',
    );
  }

  @override
  Future<RideRequest> completeRideAndPromoteReservedRide({
    required RideRequest completedRide,
  }) async {
    atomicCompletionCalled = true;
    atomicCompletedRide = completedRide;

    final conflict = conflictToThrow;

    if (conflict != null) {
      throw AtomicRideCompletionConflictException(conflict);
    }

    return completedRide;
  }
}

class AtomicCancellationFakeRideRequestRepository
    extends FakeRideRequestRepository
    implements AtomicRideCancellationRepository {
  bool atomicCancellationCalled = false;
  RideRequest? atomicCancelledRide;
  DateTime? atomicCancelledAt;
  AtomicRideCancellationConflict? conflictToThrow;

  AtomicCancellationFakeRideRequestRepository([
    super.rides = const [],
    this.conflictToThrow,
  ]);

  @override
  Future<void> save(RideRequest request) async {
    throw StateError(
      'save() must not be called when atomic cancellation is available.',
    );
  }

  @override
  Future<RideRequest> cancelAssignedRideAndPromoteReservedRide({
    required RideRequest cancelledRide,
    required DateTime cancelledAt,
  }) async {
    atomicCancellationCalled = true;
    atomicCancelledRide = cancelledRide;
    atomicCancelledAt = cancelledAt;

    final conflict = conflictToThrow;

    if (conflict != null) {
      throw AtomicRideCancellationConflictException(conflict);
    }

    return cancelledRide;
  }
}

class AtomicReservedCancellationFakeRideRequestRepository
    extends FakeRideRequestRepository
    implements AtomicReservedRideCancellationRepository {
  bool atomicReservedCancellationCalled = false;
  String? cancelledRideId;
  DateTime? atomicCancelledAt;
  AtomicReservedRideCancellationConflict? conflictToThrow;

  AtomicReservedCancellationFakeRideRequestRepository([
    super.rides = const [],
    this.conflictToThrow,
  ]);

  @override
  Future<void> save(RideRequest request) async {
    throw StateError(
      'save() must not be called when atomic reserved cancellation is available.',
    );
  }

  @override
  Future<RideRequest> cancelReservedRide({
    required String rideId,
    required DateTime cancelledAt,
  }) async {
    atomicReservedCancellationCalled = true;
    cancelledRideId = rideId;
    atomicCancelledAt = cancelledAt;

    final conflict = conflictToThrow;

    if (conflict != null) {
      throw AtomicReservedRideCancellationConflictException(conflict);
    }

    final ride = await findById(rideId);

    if (ride == null) {
      throw StateError('Test ride not found.');
    }

    return ride.transitionTo(RideRequestStatus.cancelled);
  }
}

void main() {
  RideRequest createRide({
    String id = 'ride-001',
    RideRequestStatus status = RideRequestStatus.pending,
    String? assignedDriverId,
    String? assignedVehicleId,
    String? completedByDriverId,
    DateTime? completedAt,
  }) {
    return RideRequest(
      id: id,
      pickup: 'Pickup $id',
      destination: 'Destination $id',
      passengers: 1,
      requestedAt: DateTime(2026, 9, 26, 16, 0),
      status: status,
      assignedDriverId: assignedDriverId,
      assignedVehicleId: assignedVehicleId,
      completedByDriverId: completedByDriverId,
      completedAt: completedAt,
    );
  }

  test('submitRide moves new ride from pending to waitingForVehicle', () async {
    final repository = FakeRideRequestRepository();

    final service = RideLifecycleService(repository: repository);

    final result = await service.submitRide(createRide());

    expect(result.status, RideRequestStatus.waitingForVehicle);

    final storedRide = await repository.findById('ride-001');

    expect(storedRide?.status, RideRequestStatus.waitingForVehicle);
  });
  test('submitPendingRide keeps new ride pending', () async {
    final repository = FakeRideRequestRepository();

    final service = RideLifecycleService(repository: repository);

    final result = await service.submitPendingRide(createRide());

    expect(result.status, RideRequestStatus.pending);

    final storedRide = await repository.findById('ride-001');

    expect(storedRide?.status, RideRequestStatus.pending);
  });

  test('submitRide rejects duplicate ride id', () async {
    final existingRide = createRide(
      status: RideRequestStatus.waitingForVehicle,
    );

    final repository = FakeRideRequestRepository([existingRide]);

    final service = RideLifecycleService(repository: repository);

    expect(
      () => service.submitRide(createRide()),
      throwsA(
        isA<RideLifecycleConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideLifecycleConflict.rideAlreadyExists,
        ),
      ),
    );
  });

  test('submitRide rejects ride that is not pending', () async {
    final repository = FakeRideRequestRepository();

    final service = RideLifecycleService(repository: repository);

    expect(
      () => service.submitRide(createRide(status: RideRequestStatus.accepted)),
      throwsA(
        isA<RideLifecycleConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideLifecycleConflict.rideMustBePending,
        ),
      ),
    );
  });

  test('getRide throws when ride does not exist', () async {
    final repository = FakeRideRequestRepository();

    final service = RideLifecycleService(repository: repository);

    expect(
      () => service.getRide('missing'),
      throwsA(isA<RideLifecycleNotFoundException>()),
    );
  });

  test('cancelRide cancels a waiting ride', () async {
    final waitingRide = createRide(status: RideRequestStatus.waitingForVehicle);

    final repository = FakeRideRequestRepository([waitingRide]);

    final service = RideLifecycleService(repository: repository);

    final result = await service.cancelRide('ride-001');

    expect(result.status, RideRequestStatus.cancelled);
  });
  test(
    'cancelRide uses atomic cancellation for accepted assigned ride',
    () async {
      final acceptedRide = createRide(
        status: RideRequestStatus.accepted,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
      );

      final repository = AtomicCancellationFakeRideRequestRepository([
        acceptedRide,
      ]);

      final cancelledAt = DateTime.utc(2026, 10, 3, 12, 30);

      final service = RideLifecycleService(
        repository: repository,
        now: () => cancelledAt,
      );

      final result = await service.cancelRide('ride-001');

      expect(repository.atomicCancellationCalled, isTrue);
      expect(
        repository.atomicCancelledRide?.status,
        RideRequestStatus.cancelled,
      );
      expect(repository.atomicCancelledRide?.assignedDriverId, 'driver-001');
      expect(repository.atomicCancelledRide?.assignedVehicleId, 'vehicle-001');
      expect(repository.atomicCancelledAt, cancelledAt);

      expect(result.status, RideRequestStatus.cancelled);
    },
  );

  test(
    'cancelRide maps atomic cancellation conflict to lifecycle conflict',
    () async {
      final acceptedRide = createRide(
        status: RideRequestStatus.accepted,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
      );

      final repository = AtomicCancellationFakeRideRequestRepository([
        acceptedRide,
      ], AtomicRideCancellationConflict.queueStateMismatch);

      final service = RideLifecycleService(repository: repository);

      expect(
        () => service.cancelRide('ride-001'),
        throwsA(
          isA<RideLifecycleConflictException>().having(
            (error) => error.conflict,
            'conflict',
            RideLifecycleConflict.rideCancellationConflict,
          ),
        ),
      );
    },
  );

  test('cancelRide rejects ride already in progress', () async {
    final activeRide = createRide(
      status: RideRequestStatus.inProgress,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final repository = FakeRideRequestRepository([activeRide]);

    final service = RideLifecycleService(repository: repository);

    expect(
      () => service.cancelRide('ride-001'),
      throwsA(
        isA<RideLifecycleConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideLifecycleConflict.rideCannotBeCancelled,
        ),
      ),
    );
  });
  test(
    'cancelRide uses atomic reserved cancellation for reserved ride',
    () async {
      final reservedRide = createRide(status: RideRequestStatus.reserved);

      final repository = AtomicReservedCancellationFakeRideRequestRepository([
        reservedRide,
      ]);

      final cancelledAt = DateTime.utc(2026, 10, 3, 14, 0);

      final service = RideLifecycleService(
        repository: repository,
        now: () => cancelledAt,
      );

      final result = await service.cancelRide('ride-001');

      expect(repository.atomicReservedCancellationCalled, isTrue);
      expect(repository.cancelledRideId, 'ride-001');
      expect(repository.atomicCancelledAt, cancelledAt);
      expect(result.status, RideRequestStatus.cancelled);
    },
  );

  test(
    'cancelRide maps reserved cancellation conflict to lifecycle conflict',
    () async {
      final reservedRide = createRide(status: RideRequestStatus.reserved);

      final repository = AtomicReservedCancellationFakeRideRequestRepository([
        reservedRide,
      ], AtomicReservedRideCancellationConflict.reservationStateMismatch);

      final service = RideLifecycleService(repository: repository);

      expect(
        () => service.cancelRide('ride-001'),
        throwsA(
          isA<RideLifecycleConflictException>().having(
            (error) => error.conflict,
            'conflict',
            RideLifecycleConflict.rideCancellationConflict,
          ),
        ),
      );
    },
  );

  test(
    'releaseReservedRide returns ride to waiting and clears assignment',
    () async {
      final reservedRide = createRide(
        status: RideRequestStatus.reserved,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
      );

      final repository = FakeRideRequestRepository([reservedRide]);

      final service = RideLifecycleService(repository: repository);

      final result = await service.releaseReservedRide(
        rideId: 'ride-001',
        driverId: 'driver-001',
      );

      expect(result.status, RideRequestStatus.waitingForVehicle);
      expect(result.assignedDriverId, isNull);
      expect(result.assignedVehicleId, isNull);
    },
  );

  test('different driver cannot release reserved ride', () async {
    final reservedRide = createRide(
      status: RideRequestStatus.reserved,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final repository = FakeRideRequestRepository([reservedRide]);

    final service = RideLifecycleService(repository: repository);

    expect(
      () => service.releaseReservedRide(
        rideId: 'ride-001',
        driverId: 'driver-002',
      ),
      throwsA(
        isA<RideLifecycleConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideLifecycleConflict.rideAssignedToAnotherDriver,
        ),
      ),
    );
  });

  test('assigned driver can mark accepted ride as driverArriving', () async {
    final acceptedRide = createRide(
      status: RideRequestStatus.accepted,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final repository = FakeRideRequestRepository([acceptedRide]);

    final service = RideLifecycleService(repository: repository);

    final result = await service.markDriverArriving(
      rideId: 'ride-001',
      driverId: 'driver-001',
    );

    expect(result.status, RideRequestStatus.driverArriving);
  });

  test('assigned driver can start ride from driverArriving', () async {
    final arrivingRide = createRide(
      status: RideRequestStatus.driverArriving,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final repository = FakeRideRequestRepository([arrivingRide]);

    final service = RideLifecycleService(repository: repository);

    final result = await service.startRide(
      rideId: 'ride-001',
      driverId: 'driver-001',
    );

    expect(result.status, RideRequestStatus.inProgress);
  });

  test('different driver cannot advance assigned ride', () async {
    final acceptedRide = createRide(
      status: RideRequestStatus.accepted,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final repository = FakeRideRequestRepository([acceptedRide]);

    final service = RideLifecycleService(repository: repository);

    expect(
      () => service.markDriverArriving(
        rideId: 'ride-001',
        driverId: 'driver-002',
      ),
      throwsA(
        isA<RideLifecycleConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideLifecycleConflict.rideAssignedToAnotherDriver,
        ),
      ),
    );
  });
  test('assigned driver can complete in-progress ride', () async {
    final inProgressRide = createRide(
      status: RideRequestStatus.inProgress,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final repository = FakeRideRequestRepository([inProgressRide]);

    final completedAt = DateTime.utc(2026, 9, 26, 16, 45);

    final service = RideLifecycleService(
      repository: repository,
      commissionRateBps: 1000,
      now: () => completedAt,
    );

    final result = await service.completeRide(
      rideId: 'ride-001',
      driverId: 'driver-001',
      meterFareMinor: 1234,
    );

    expect(result.status, RideRequestStatus.completed);

    expect(result.currency, 'EUR');
    expect(result.meterFareMinor, 1234);
    expect(result.commissionRateBps, 1000);
    expect(result.commissionAmountMinor, 123);

    expect(result.completedByDriverId, 'driver-001');
    expect(result.completedAt, completedAt);

    expect(result.assignedDriverId, 'driver-001');
    expect(result.assignedVehicleId, 'vehicle-001');
  });

  test('completeRide applies commission rounding', () async {
    final inProgressRide = createRide(
      status: RideRequestStatus.inProgress,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final repository = FakeRideRequestRepository([inProgressRide]);

    final service = RideLifecycleService(
      repository: repository,
      commissionRateBps: 1000,
    );

    final result = await service.completeRide(
      rideId: 'ride-001',
      driverId: 'driver-001',
      meterFareMinor: 1235,
    );

    expect(result.meterFareMinor, 1235);
    expect(result.commissionAmountMinor, 124);
  });

  test('different driver cannot complete ride', () async {
    final inProgressRide = createRide(
      status: RideRequestStatus.inProgress,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final repository = FakeRideRequestRepository([inProgressRide]);

    final service = RideLifecycleService(repository: repository);

    expect(
      () => service.completeRide(
        rideId: 'ride-001',
        driverId: 'driver-002',
        meterFareMinor: 1234,
      ),
      throwsA(
        isA<RideLifecycleConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideLifecycleConflict.rideAssignedToAnotherDriver,
        ),
      ),
    );
  });

  test('ride outside inProgress cannot be completed', () async {
    final acceptedRide = createRide(
      status: RideRequestStatus.accepted,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final repository = FakeRideRequestRepository([acceptedRide]);

    final service = RideLifecycleService(repository: repository);

    expect(
      () => service.completeRide(
        rideId: 'ride-001',
        driverId: 'driver-001',
        meterFareMinor: 1234,
      ),
      throwsA(
        isA<RideLifecycleConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideLifecycleConflict.rideMustBeInProgress,
        ),
      ),
    );
  });

  test('completeRide rejects zero meter fare', () async {
    final inProgressRide = createRide(
      status: RideRequestStatus.inProgress,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final repository = FakeRideRequestRepository([inProgressRide]);

    final service = RideLifecycleService(repository: repository);

    expect(
      () => service.completeRide(
        rideId: 'ride-001',
        driverId: 'driver-001',
        meterFareMinor: 0,
      ),
      throwsA(
        isA<RideLifecycleConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideLifecycleConflict.invalidMeterFare,
        ),
      ),
    );
  });

  test('completeRide rejects negative meter fare', () async {
    final inProgressRide = createRide(
      status: RideRequestStatus.inProgress,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final repository = FakeRideRequestRepository([inProgressRide]);

    final service = RideLifecycleService(repository: repository);

    expect(
      () => service.completeRide(
        rideId: 'ride-001',
        driverId: 'driver-001',
        meterFareMinor: -1,
      ),
      throwsA(
        isA<RideLifecycleConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideLifecycleConflict.invalidMeterFare,
        ),
      ),
    );
  });

  test('completed ride cannot be completed twice', () async {
    final inProgressRide = createRide(
      status: RideRequestStatus.inProgress,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
    );

    final repository = FakeRideRequestRepository([inProgressRide]);

    final service = RideLifecycleService(repository: repository);

    final firstResult = await service.completeRide(
      rideId: 'ride-001',
      driverId: 'driver-001',
      meterFareMinor: 1234,
    );

    expect(firstResult.status, RideRequestStatus.completed);

    expect(
      () => service.completeRide(
        rideId: 'ride-001',
        driverId: 'driver-001',
        meterFareMinor: 1500,
      ),
      throwsA(
        isA<RideLifecycleConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideLifecycleConflict.rideMustBeInProgress,
        ),
      ),
    );
  });
  test(
    'completeRide uses atomic completion repository when available',
    () async {
      final inProgressRide = createRide(
        status: RideRequestStatus.inProgress,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
      );

      final repository = AtomicFakeRideRequestRepository([inProgressRide]);

      final completedAt = DateTime.utc(2026, 9, 26, 16, 45);

      final service = RideLifecycleService(
        repository: repository,
        commissionRateBps: 1000,
        now: () => completedAt,
      );

      final result = await service.completeRide(
        rideId: 'ride-001',
        driverId: 'driver-001',
        meterFareMinor: 1234,
      );

      expect(repository.atomicCompletionCalled, isTrue);

      expect(
        repository.atomicCompletedRide?.status,
        RideRequestStatus.completed,
      );
      expect(repository.atomicCompletedRide?.meterFareMinor, 1234);
      expect(repository.atomicCompletedRide?.commissionAmountMinor, 123);
      expect(repository.atomicCompletedRide?.completedByDriverId, 'driver-001');
      expect(repository.atomicCompletedRide?.completedAt, completedAt);

      expect(result.status, RideRequestStatus.completed);
    },
  );

  test(
    'completeRide maps atomic completion conflict to lifecycle conflict',
    () async {
      final inProgressRide = createRide(
        status: RideRequestStatus.inProgress,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
      );

      final repository = AtomicFakeRideRequestRepository([
        inProgressRide,
      ], AtomicRideCompletionConflict.queueStateMismatch);

      final service = RideLifecycleService(repository: repository);

      expect(
        () => service.completeRide(
          rideId: 'ride-001',
          driverId: 'driver-001',
          meterFareMinor: 1234,
        ),
        throwsA(
          isA<RideLifecycleConflictException>().having(
            (error) => error.conflict,
            'conflict',
            RideLifecycleConflict.rideCompletionConflict,
          ),
        ),
      );
    },
  );
}
