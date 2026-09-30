import 'dart:collection';

import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/atomic_ride_reservation_repository.dart';
import 'package:gocity6_backend/dispatch/atomic_waiting_ride_acceptance_repository.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/ride_reservation.dart';
import 'package:gocity6_backend/ride/ride_dispatch_service.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_repository.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:test/test.dart';

class FakeRideRequestRepository implements RideRequestRepository {
  final Map<String, RideRequest> rides;

  FakeRideRequestRepository(Iterable<RideRequest> rides)
    : rides = {for (final ride in rides) ride.id: ride};

  @override
  Future<RideRequest?> findById(String id) async => rides[id];

  @override
  Future<List<RideRequest>> findByAssignedDriverId(String driverId) async {
    return rides.values
        .where((ride) => ride.assignedDriverId == driverId)
        .toList();
  }

  @override
  Future<void> save(RideRequest request) async {
    rides[request.id] = request;
  }
}

class FakeDriverShiftRepository implements DriverShiftRepository {
  final ActiveDriverShift? shift;

  FakeDriverShiftRepository(this.shift);

  @override
  Future<ActiveDriverShift?> findActiveByDriverId(String driverId) async {
    if (shift?.driverId == driverId) {
      return shift;
    }

    return null;
  }

  @override
  Future<List<ActiveDriverShift>> findAllActive() async {
    return shift == null ? [] : [shift!];
  }

  @override
  Future<ActiveDriverShift> startShift({
    required String shiftId,
    required String driverId,
    required String vehicleId,
    required DateTime startedAt,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ActiveDriverShift> saveQueueState({
    required String shiftId,
    required DriverQueueState queueState,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> endShift({
    required String shiftId,
    required DateTime endedAt,
  }) {
    throw UnimplementedError();
  }
}

class FakeAtomicWaitingRideAcceptanceRepository
    implements AtomicWaitingRideAcceptanceRepository {
  final RideRequest result;

  bool called = false;

  FakeAtomicWaitingRideAcceptanceRepository(this.result);

  @override
  Future<RideRequest> acceptWaitingRide({
    required String rideId,
    required String driverId,
  }) async {
    called = true;
    return result;
  }
}

class FakeAtomicRideReservationRepository
    implements AtomicRideReservationRepository {
  int callCount = 0;
  String? reservationId;
  String? rideId;
  String? driverId;
  int? combinedEtaSeconds;
  DateTime? now;

  @override
  Future<RideReservation> reserveWaitingRide({
    required String reservationId,
    required String rideId,
    required String driverId,
    required int combinedEtaSeconds,
    required DateTime now,
  }) async {
    callCount += 1;
    this.reservationId = reservationId;
    this.rideId = rideId;
    this.driverId = driverId;
    this.combinedEtaSeconds = combinedEtaSeconds;
    this.now = now;

    return RideReservation.create(
      id: reservationId,
      rideId: rideId,
      driverId: driverId,
      vehicleId: 'vehicle-001',
      shiftId: 'shift-001',
      reservedAt: now,
    );
  }
}

class RouteCall {
  final RouteWaypoint origin;
  final RouteWaypoint destination;

  const RouteCall({
    required this.origin,
    required this.destination,
  });
}

class FakeRouteEstimator implements RouteEstimator {
  final Queue<RouteEstimate> estimates;
  final List<RouteCall> calls = [];

  FakeRouteEstimator(Iterable<RouteEstimate> estimates)
    : estimates = Queue<RouteEstimate>.from(estimates);

  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) async {
    calls.add(
      RouteCall(
        origin: origin,
        destination: destination,
      ),
    );

    if (estimates.isEmpty) {
      throw StateError('No fake route estimate configured.');
    }

    return estimates.removeFirst();
  }
}

void main() {
  final now = DateTime.utc(2026, 9, 30, 18, 0);

  RideRequest createRide({
    required String id,
    required RideRequestStatus status,
    String? assignedDriverId,
    String? assignedVehicleId,
    String? pickup,
    String? destination,
    bool withFiveEuroBonus = false,
  }) {
    return RideRequest(
      id: id,
      pickup: pickup ?? 'Pickup $id',
      destination: destination ?? 'Destination $id',
      passengers: 1,
      requestedAt: now.subtract(const Duration(minutes: 5)),
      status: status,
      assignedDriverId: assignedDriverId,
      assignedVehicleId: assignedVehicleId,
      dispatchRound: withFiveEuroBonus
          ? RideRequest.bonusDispatchRound
          : RideRequest.normalDispatchRound,
      driverBonusMinor: withFiveEuroBonus
          ? RideRequest.driverBonusFiveEuroMinor
          : RideRequest.noDriverBonusMinor,
      bonusDecision: withFiveEuroBonus
          ? RideBonusDecision.accepted
          : RideBonusDecision.notOffered,
    );
  }

  ActiveDriverShift createShift(DriverQueueAvailability availability) {
    return ActiveDriverShift.restore(
      id: 'shift-001',
      driverId: 'driver-001',
      vehicleId: 'vehicle-001',
      startedAt: now.subtract(const Duration(hours: 1)),
      queueState: DriverQueueState.restore(
        driverId: 'driver-001',
        queuePrioritySince: now.subtract(const Duration(hours: 1)),
        availability: availability,
        shortBreaksUsed: 0,
        breakStartedAt:
            availability == DriverQueueAvailability.shortBreak ||
                availability == DriverQueueAvailability.longBreak
            ? now.subtract(const Duration(minutes: 1))
            : null,
        hasPendingOffer: false,
      ),
    );
  }

  RouteEstimate estimate({
    required double durationSeconds,
    double? destinationLatitude,
    double? destinationLongitude,
  }) {
    return RouteEstimate(
      distanceMeters: 1000,
      durationSeconds: durationSeconds,
      destinationLatitude: destinationLatitude,
      destinationLongitude: destinationLongitude,
    );
  }

  test(
    'available queue state uses atomic waiting ride acceptance',
    () async {
      final waitingRide = createRide(
        id: 'ride-next',
        status: RideRequestStatus.waitingForVehicle,
      );

      final acceptedRide = waitingRide
          .transitionTo(RideRequestStatus.accepted)
          .copyWith(
            assignedDriverId: 'driver-001',
            assignedVehicleId: 'vehicle-001',
          );

      final rideRepository = FakeRideRequestRepository([waitingRide]);
      final acceptanceRepository =
          FakeAtomicWaitingRideAcceptanceRepository(acceptedRide);

      final service = RideDispatchService(
        repository: rideRepository,
        waitingRideAcceptanceRepository: acceptanceRepository,
        driverShiftRepository: FakeDriverShiftRepository(
          createShift(DriverQueueAvailability.available),
        ),
      );

      final result = await service.selectWaitingRide(
        rideId: waitingRide.id,
        driverId: 'driver-001',
        vehicleId: 'stale-client-vehicle',
      );

      expect(acceptanceRepository.called, isTrue);
      expect(result.status, RideRequestStatus.accepted);
      expect(result.assignedVehicleId, 'vehicle-001');
    },
  );

  test(
    'busy inProgress driver reserves with two-leg combined ETA',
    () async {
      final currentRide = createRide(
        id: 'ride-current',
        status: RideRequestStatus.inProgress,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
        destination: 'Current destination',
      );

      final waitingRide = createRide(
        id: 'ride-next',
        status: RideRequestStatus.waitingForVehicle,
        pickup: 'Next pickup',
        withFiveEuroBonus: true,
      );

      final routeEstimator = FakeRouteEstimator([
        estimate(
          durationSeconds: 300.2,
          destinationLatitude: 42.7001,
          destinationLongitude: 23.3001,
        ),
        estimate(durationSeconds: 299.1),
      ]);

      final reservationRepository =
          FakeAtomicRideReservationRepository();

      final service = RideDispatchService(
        repository: FakeRideRequestRepository([
          currentRide,
          waitingRide,
        ]),
        waitingRideAcceptanceRepository:
            FakeAtomicWaitingRideAcceptanceRepository(waitingRide),
        driverShiftRepository: FakeDriverShiftRepository(
          createShift(DriverQueueAvailability.busy),
        ),
        rideReservationRepository: reservationRepository,
        routeEstimator: routeEstimator,
      );

      final result = await service.selectWaitingRide(
        rideId: waitingRide.id,
        driverId: 'driver-001',
        vehicleId: 'stale-client-vehicle',
        driverLatitude: 42.6500,
        driverLongitude: 23.2500,
        reservationId: 'reservation-001',
        now: now,
      );

      expect(routeEstimator.calls, hasLength(2));

      expect(
        routeEstimator.calls.first.destination.address,
        'Current destination',
      );

      expect(
        routeEstimator.calls.last.origin.latitude,
        42.7001,
      );
      expect(
        routeEstimator.calls.last.origin.longitude,
        23.3001,
      );
      expect(
        routeEstimator.calls.last.destination.address,
        'Next pickup',
      );

      expect(reservationRepository.callCount, 1);
      expect(reservationRepository.combinedEtaSeconds, 600);

      expect(result.status, RideRequestStatus.reserved);
      expect(result.assignedDriverId, isNull);
      expect(result.assignedVehicleId, isNull);
      expect(
        result.driverBonusMinor,
        RideRequest.driverBonusFiveEuroMinor,
      );
      expect(result.bonusDecision, RideBonusDecision.accepted);
    },
  );

  test(
    'busy driverArriving driver includes current pickup in remaining ETA',
    () async {
      final currentRide = createRide(
        id: 'ride-current',
        status: RideRequestStatus.driverArriving,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
        pickup: 'Current pickup',
        destination: 'Current destination',
      );

      final waitingRide = createRide(
        id: 'ride-next',
        status: RideRequestStatus.waitingForVehicle,
        pickup: 'Next pickup',
      );

      final routeEstimator = FakeRouteEstimator([
        estimate(
          durationSeconds: 100.1,
          destinationLatitude: 42.6600,
          destinationLongitude: 23.2600,
        ),
        estimate(
          durationSeconds: 200.2,
          destinationLatitude: 42.6700,
          destinationLongitude: 23.2700,
        ),
        estimate(durationSeconds: 299.2),
      ]);

      final reservationRepository =
          FakeAtomicRideReservationRepository();

      final service = RideDispatchService(
        repository: FakeRideRequestRepository([
          currentRide,
          waitingRide,
        ]),
        waitingRideAcceptanceRepository:
            FakeAtomicWaitingRideAcceptanceRepository(waitingRide),
        driverShiftRepository: FakeDriverShiftRepository(
          createShift(DriverQueueAvailability.busy),
        ),
        rideReservationRepository: reservationRepository,
        routeEstimator: routeEstimator,
      );

      await service.selectWaitingRide(
        rideId: waitingRide.id,
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        driverLatitude: 42.6500,
        driverLongitude: 23.2500,
        reservationId: 'reservation-001',
        now: now,
      );

      expect(routeEstimator.calls, hasLength(3));
      expect(
        routeEstimator.calls[0].destination.address,
        'Current pickup',
      );
      expect(
        routeEstimator.calls[1].destination.address,
        'Current destination',
      );
      expect(
        routeEstimator.calls[2].destination.address,
        'Next pickup',
      );

      expect(reservationRepository.combinedEtaSeconds, 600);
    },
  );

  test(
    'externalRide driver uses current GPS to next pickup only',
    () async {
      final waitingRide = createRide(
        id: 'ride-next',
        status: RideRequestStatus.waitingForVehicle,
        pickup: 'Next pickup',
      );

      final routeEstimator = FakeRouteEstimator([
        estimate(durationSeconds: 420.4),
      ]);

      final reservationRepository =
          FakeAtomicRideReservationRepository();

      final service = RideDispatchService(
        repository: FakeRideRequestRepository([waitingRide]),
        waitingRideAcceptanceRepository:
            FakeAtomicWaitingRideAcceptanceRepository(waitingRide),
        driverShiftRepository: FakeDriverShiftRepository(
          createShift(DriverQueueAvailability.externalRide),
        ),
        rideReservationRepository: reservationRepository,
        routeEstimator: routeEstimator,
      );

      final result = await service.selectWaitingRide(
        rideId: waitingRide.id,
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        driverLatitude: 42.6500,
        driverLongitude: 23.2500,
        reservationId: 'reservation-001',
        now: now,
      );

      expect(routeEstimator.calls, hasLength(1));
      expect(routeEstimator.calls.single.origin.latitude, 42.6500);
      expect(routeEstimator.calls.single.origin.longitude, 23.2500);
      expect(
        routeEstimator.calls.single.destination.address,
        'Next pickup',
      );

      expect(reservationRepository.combinedEtaSeconds, 421);
      expect(result.status, RideRequestStatus.reserved);
      expect(result.assignedDriverId, isNull);
      expect(result.assignedVehicleId, isNull);
    },
  );

  test(
    'reservation ETA rounds up and rejects anything above 600 seconds',
    () async {
      final waitingRide = createRide(
        id: 'ride-next',
        status: RideRequestStatus.waitingForVehicle,
      );

      final routeEstimator = FakeRouteEstimator([
        estimate(durationSeconds: 600.01),
      ]);

      final reservationRepository =
          FakeAtomicRideReservationRepository();

      final service = RideDispatchService(
        repository: FakeRideRequestRepository([waitingRide]),
        waitingRideAcceptanceRepository:
            FakeAtomicWaitingRideAcceptanceRepository(waitingRide),
        driverShiftRepository: FakeDriverShiftRepository(
          createShift(DriverQueueAvailability.externalRide),
        ),
        rideReservationRepository: reservationRepository,
        routeEstimator: routeEstimator,
      );

      expect(
        () => service.selectWaitingRide(
          rideId: waitingRide.id,
          driverId: 'driver-001',
          vehicleId: 'vehicle-001',
          driverLatitude: 42.6500,
          driverLongitude: 23.2500,
          reservationId: 'reservation-001',
          now: now,
        ),
        throwsA(
          isA<RideDispatchConflictException>().having(
            (error) => error.conflict,
            'conflict',
            RideDispatchConflict.reservationEtaTooHigh,
          ),
        ),
      );

      expect(reservationRepository.callCount, 0);
    },
  );

  test(
    'busy or external reservation requires valid driver GPS',
    () async {
      final waitingRide = createRide(
        id: 'ride-next',
        status: RideRequestStatus.waitingForVehicle,
      );

      final service = RideDispatchService(
        repository: FakeRideRequestRepository([waitingRide]),
        waitingRideAcceptanceRepository:
            FakeAtomicWaitingRideAcceptanceRepository(waitingRide),
        driverShiftRepository: FakeDriverShiftRepository(
          createShift(DriverQueueAvailability.externalRide),
        ),
        rideReservationRepository:
            FakeAtomicRideReservationRepository(),
        routeEstimator: FakeRouteEstimator([
          estimate(durationSeconds: 100),
        ]),
      );

      expect(
        () => service.selectWaitingRide(
          rideId: waitingRide.id,
          driverId: 'driver-001',
          vehicleId: 'vehicle-001',
          reservationId: 'reservation-001',
          now: now,
        ),
        throwsA(
          isA<RideDispatchInputException>().having(
            (error) => error.conflict,
            'conflict',
            RideDispatchInputConflict.driverLocationRequired,
          ),
        ),
      );

      expect(
        () => service.selectWaitingRide(
          rideId: waitingRide.id,
          driverId: 'driver-001',
          vehicleId: 'vehicle-001',
          driverLatitude: 95,
          driverLongitude: 23.25,
          reservationId: 'reservation-002',
          now: now,
        ),
        throwsA(
          isA<RideDispatchInputException>().having(
            (error) => error.conflict,
            'conflict',
            RideDispatchInputConflict.invalidDriverLocation,
          ),
        ),
      );
    },
  );
}
