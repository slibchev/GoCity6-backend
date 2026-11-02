import 'dart:collection';

import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/atomic_ride_reservation_repository.dart';
import 'package:gocity6_backend/dispatch/atomic_waiting_ride_acceptance_repository.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_live_location.dart';
import 'package:gocity6_backend/dispatch/driver_live_location_repository.dart';
import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/driver_work_state_repository.dart';
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
  Future<RideRequest?> findByClientRequestId(String clientRequestId) async {
    for (final ride in rides.values) {
      if (ride.clientRequestId == clientRequestId) {
        return ride;
      }
    }
    return null;
  }

  @override
  Future<RideRequest?> findById(String id) async => rides[id];

  @override
  Future<List<RideRequest>> findByAssignedDriverId(String driverId) async {
    return rides.values
        .where((ride) => ride.assignedDriverId == driverId)
        .toList();
  }

  @override
  Future<List<RideRequest>> findWaitingForVehicle() async {
    final waiting = rides.values
        .where(
          (ride) =>
              ride.status == RideRequestStatus.waitingForVehicle &&
              ride.assignedDriverId == null &&
              ride.assignedVehicleId == null,
        )
        .toList();

    waiting.sort((a, b) {
      final byTime = a.requestedAt.compareTo(b.requestedAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });

    return waiting;
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
  Future<void> endShift({required String shiftId, required DateTime endedAt}) {
    throw UnimplementedError();
  }
}

class FakeDriverWorkStateRepository implements DriverWorkStateRepository {
  final DriverWorkStateSnapshot snapshot;

  FakeDriverWorkStateRepository(this.snapshot);

  @override
  Future<DriverWorkStateSnapshot> loadByDriverId(String driverId) async =>
      snapshot;
}

class FakeDriverLiveLocationRepository implements DriverLiveLocationRepository {
  DriverLiveLocation? location;

  FakeDriverLiveLocationRepository(this.location);

  @override
  Future<DriverLiveLocation?> findByDriverId(String driverId) async => location;

  @override
  Future<DriverLiveLocation> save({
    required String driverId,
    required double latitude,
    required double longitude,
    required DateTime updatedAt,
  }) async {
    final next = DriverLiveLocation(
      driverId: driverId,
      latitude: latitude,
      longitude: longitude,
      updatedAt: updatedAt,
    );
    location = next;
    return next;
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
    DateTime? now,
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
  DriverLiveLocation? expectedDriverLocation;
  String? expectedCurrentRideId;
  AtomicRideReservationConflict? conflict;

  @override
  Future<RideReservation> reserveWaitingRide({
    required String reservationId,
    required String rideId,
    required String driverId,
    required int combinedEtaSeconds,
    required DateTime now,
    DriverLiveLocation? expectedDriverLocation,
    String? expectedCurrentRideId,
  }) async {
    callCount += 1;
    this.reservationId = reservationId;
    this.rideId = rideId;
    this.driverId = driverId;
    this.combinedEtaSeconds = combinedEtaSeconds;
    this.now = now;
    this.expectedDriverLocation = expectedDriverLocation;
    this.expectedCurrentRideId = expectedCurrentRideId;

    if (conflict != null) {
      throw AtomicRideReservationConflictException(conflict!);
    }

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

  const RouteCall({required this.origin, required this.destination});
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
    calls.add(RouteCall(origin: origin, destination: destination));

    if (estimates.isEmpty) {
      throw StateError('No fake route estimate configured.');
    }

    return estimates.removeFirst();
  }
}

class _LocationAwareRouteEstimator implements RouteEstimator {
  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) async {
    final seconds = origin.latitude == null
        ? 100.0
        : (origin.latitude == 42.65 ? 501.0 : 300.0);
    return RouteEstimate(distanceMeters: 1000, durationSeconds: seconds);
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
    double? pickupLatitude,
    double? pickupLongitude,
    String? destination,
    bool withFiveEuroBonus = false,
  }) {
    return RideRequest(
      id: id,
      pickup: pickup ?? 'Pickup $id',
      pickupLatitude: pickupLatitude,
      pickupLongitude: pickupLongitude,
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

  test('available queue state uses atomic waiting ride acceptance', () async {
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
    final acceptanceRepository = FakeAtomicWaitingRideAcceptanceRepository(
      acceptedRide,
    );

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
  });

  test('busy inProgress driver reserves with two-leg combined ETA', () async {
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
      pickupLatitude: 42.711,
      pickupLongitude: 23.302,
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

    final reservationRepository = FakeAtomicRideReservationRepository();

    final service = RideDispatchService(
      repository: FakeRideRequestRepository([currentRide, waitingRide]),
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

    expect(routeEstimator.calls.last.origin.latitude, 42.7001);
    expect(routeEstimator.calls.last.origin.longitude, 23.3001);
    expect(routeEstimator.calls.last.destination.latitude, 42.711);
    expect(routeEstimator.calls.last.destination.longitude, 23.302);
    expect(routeEstimator.calls.last.destination.address, isNull);

    expect(reservationRepository.callCount, 1);
    expect(reservationRepository.combinedEtaSeconds, 600);
    expect(reservationRepository.expectedCurrentRideId, currentRide.id);

    expect(result.status, RideRequestStatus.reserved);
    expect(result.assignedDriverId, isNull);
    expect(result.assignedVehicleId, isNull);
    expect(result.driverBonusMinor, RideRequest.driverBonusFiveEuroMinor);
    expect(result.bonusDecision, RideBonusDecision.accepted);
  });

  test(
    'busy driverArriving driver includes current pickup in remaining ETA',
    () async {
      final currentRide = createRide(
        id: 'ride-current',
        status: RideRequestStatus.driverArriving,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
        pickup: 'Current pickup',
        pickupLatitude: 42.661,
        pickupLongitude: 23.261,
        destination: 'Current destination',
      );

      final waitingRide = createRide(
        id: 'ride-next',
        status: RideRequestStatus.waitingForVehicle,
        pickup: 'Next pickup',
        pickupLatitude: 42.671,
        pickupLongitude: 23.271,
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

      final reservationRepository = FakeAtomicRideReservationRepository();

      final service = RideDispatchService(
        repository: FakeRideRequestRepository([currentRide, waitingRide]),
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
      expect(routeEstimator.calls[0].destination.latitude, 42.661);
      expect(routeEstimator.calls[0].destination.longitude, 23.261);
      expect(routeEstimator.calls[0].destination.address, isNull);
      expect(
        routeEstimator.calls[1].destination.address,
        'Current destination',
      );
      expect(routeEstimator.calls[2].destination.latitude, 42.671);
      expect(routeEstimator.calls[2].destination.longitude, 23.271);
      expect(routeEstimator.calls[2].destination.address, isNull);

      expect(reservationRepository.combinedEtaSeconds, 600);
    },
  );

  test('scheduled break blocks atomic reservation as unavailable', () async {
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
      pickupLatitude: 42.711,
      pickupLongitude: 23.302,
    );
    final reservationRepository = FakeAtomicRideReservationRepository()
      ..conflict = AtomicRideReservationConflict.driverBreakScheduled;
    final service = RideDispatchService(
      repository: FakeRideRequestRepository([currentRide, waitingRide]),
      waitingRideAcceptanceRepository:
          FakeAtomicWaitingRideAcceptanceRepository(waitingRide),
      driverShiftRepository: FakeDriverShiftRepository(
        createShift(DriverQueueAvailability.busy),
      ),
      rideReservationRepository: reservationRepository,
      routeEstimator: FakeRouteEstimator([
        estimate(
          durationSeconds: 100,
          destinationLatitude: 42.70,
          destinationLongitude: 23.30,
        ),
        estimate(durationSeconds: 100),
      ]),
    );

    await expectLater(
      service.selectWaitingRide(
        rideId: waitingRide.id,
        driverId: 'driver-001',
        vehicleId: 'vehicle-001',
        driverLatitude: 42.65,
        driverLongitude: 23.25,
        reservationId: 'reservation-001',
        now: now,
      ),
      throwsA(
        isA<RideDispatchConflictException>().having(
          (error) => error.conflict,
          'conflict',
          RideDispatchConflict.driverNotAvailable,
        ),
      ),
    );
    expect(reservationRepository.callCount, 1);
  });

  test('externalRide driver uses current GPS to next pickup only', () async {
    final waitingRide = createRide(
      id: 'ride-next',
      status: RideRequestStatus.waitingForVehicle,
      pickup: 'Next pickup',
    );

    final routeEstimator = FakeRouteEstimator([
      estimate(durationSeconds: 420.4),
    ]);

    final reservationRepository = FakeAtomicRideReservationRepository();

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
    expect(routeEstimator.calls.single.destination.address, 'Next pickup');

    expect(reservationRepository.combinedEtaSeconds, 421);
    expect(result.status, RideRequestStatus.reserved);
    expect(result.assignedDriverId, isNull);
    expect(result.assignedVehicleId, isNull);
  });

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

      final reservationRepository = FakeAtomicRideReservationRepository();

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

  test('busy or external reservation requires valid driver GPS', () async {
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
      rideReservationRepository: FakeAtomicRideReservationRepository(),
      routeEstimator: FakeRouteEstimator([estimate(durationSeconds: 100)]),
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
  });

  test(
    'waiting assessment accepts busy ETA 599 and 600, rejects 601',
    () async {
      final currentRide = createRide(
        id: 'ride-current',
        status: RideRequestStatus.inProgress,
        assignedDriverId: 'driver-001',
        assignedVehicleId: 'vehicle-001',
        destination: 'Current destination',
      );
      final location = DriverLiveLocation(
        driverId: 'driver-001',
        latitude: 42.65,
        longitude: 23.25,
        updatedAt: now.subtract(const Duration(seconds: 1)),
        gpsFixAt: now.subtract(const Duration(seconds: 1)),
      );

      for (final seconds in [599, 600, 601]) {
        final waitingRide = createRide(
          id: 'ride-$seconds',
          status: RideRequestStatus.waitingForVehicle,
          pickupLatitude: 42.66,
          pickupLongitude: 23.26,
        );
        final service = RideDispatchService(
          repository: FakeRideRequestRepository([waitingRide]),
          driverShiftRepository: FakeDriverShiftRepository(
            createShift(DriverQueueAvailability.busy),
          ),
          workStateRepository: FakeDriverWorkStateRepository(
            DriverWorkStateSnapshot(
              activeShift: createShift(DriverQueueAvailability.busy),
              pendingOffer: null,
              currentRide: currentRide,
              reservedRide: null,
            ),
          ),
          liveLocationRepository: FakeDriverLiveLocationRepository(location),
          routeEstimator: FakeRouteEstimator([
            estimate(durationSeconds: 0),
            estimate(durationSeconds: seconds.toDouble()),
          ]),
        );

        final assessment = (await service.assessWaitingRides(
          driverId: 'driver-001',
          rides: [waitingRide],
          now: now,
        )).single;

        expect(assessment.combinedEtaSeconds, seconds);
        expect(assessment.canSelect, seconds <= 600);
        expect(
          assessment.reasonCode,
          seconds <= 600 ? isNull : 'combined_eta_too_high',
        );
      }
    },
  );

  test(
    'waiting assessment reacts to GPS freshness and new saved fixes',
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
        pickupLatitude: 42.66,
        pickupLongitude: 23.26,
      );
      final locationRepository = FakeDriverLiveLocationRepository(
        DriverLiveLocation(
          driverId: 'driver-001',
          latitude: 42.65,
          longitude: 23.25,
          updatedAt: now.subtract(const Duration(seconds: 31)),
          gpsFixAt: now.subtract(const Duration(seconds: 31)),
        ),
      );
      final service = RideDispatchService(
        repository: FakeRideRequestRepository([waitingRide]),
        driverShiftRepository: FakeDriverShiftRepository(
          createShift(DriverQueueAvailability.busy),
        ),
        workStateRepository: FakeDriverWorkStateRepository(
          DriverWorkStateSnapshot(
            activeShift: createShift(DriverQueueAvailability.busy),
            pendingOffer: null,
            currentRide: currentRide,
            reservedRide: null,
          ),
        ),
        liveLocationRepository: locationRepository,
        routeEstimator: FakeRouteEstimator([
          estimate(durationSeconds: 0),
          estimate(durationSeconds: 120),
        ]),
      );

      final stale = (await service.assessWaitingRides(
        driverId: 'driver-001',
        rides: [waitingRide],
        now: now,
      )).single;
      expect(stale.canSelect, isFalse);
      expect(stale.reasonCode, 'gps_unavailable');

      locationRepository.location = DriverLiveLocation(
        driverId: 'driver-001',
        latitude: 42.651,
        longitude: 23.251,
        updatedAt: now,
        gpsFixAt: now,
      );
      final fresh = (await service.assessWaitingRides(
        driverId: 'driver-001',
        rides: [waitingRide],
        now: now,
      )).single;
      expect(fresh.canSelect, isTrue);
      expect(fresh.combinedEtaSeconds, 120);
    },
  );

  test('waiting assessment recomputes when the GPS position changes', () async {
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
      pickupLatitude: 42.66,
      pickupLongitude: 23.26,
    );
    final locationRepository = FakeDriverLiveLocationRepository(
      DriverLiveLocation(
        driverId: 'driver-001',
        latitude: 42.65,
        longitude: 23.25,
        updatedAt: now,
        gpsFixAt: now,
      ),
    );
    final shift = createShift(DriverQueueAvailability.busy);
    final service = RideDispatchService(
      repository: FakeRideRequestRepository([waitingRide]),
      driverShiftRepository: FakeDriverShiftRepository(shift),
      workStateRepository: FakeDriverWorkStateRepository(
        DriverWorkStateSnapshot(
          activeShift: shift,
          pendingOffer: null,
          currentRide: currentRide,
          reservedRide: null,
        ),
      ),
      liveLocationRepository: locationRepository,
      routeEstimator: _LocationAwareRouteEstimator(),
    );

    final first = (await service.assessWaitingRides(
      driverId: 'driver-001',
      rides: [waitingRide],
      now: now,
    )).single;
    expect(first.canSelect, isFalse);
    expect(first.combinedEtaSeconds, 601);

    final later = now.add(const Duration(seconds: 1));
    locationRepository.location = DriverLiveLocation(
      driverId: 'driver-001',
      latitude: 42.651,
      longitude: 23.251,
      updatedAt: later,
      gpsFixAt: later,
    );
    final updated = (await service.assessWaitingRides(
      driverId: 'driver-001',
      rides: [waitingRide],
      now: later,
    )).single;
    expect(updated.canSelect, isTrue);
    expect(updated.combinedEtaSeconds, 400);
  });

  test('available driver keeps existing no-ETA selection behavior', () async {
    final waitingRide = createRide(
      id: 'ride-next',
      status: RideRequestStatus.waitingForVehicle,
    );
    final service = RideDispatchService(
      repository: FakeRideRequestRepository([waitingRide]),
      driverShiftRepository: FakeDriverShiftRepository(
        createShift(DriverQueueAvailability.available),
      ),
      workStateRepository: FakeDriverWorkStateRepository(
        DriverWorkStateSnapshot(
          activeShift: createShift(DriverQueueAvailability.available),
          pendingOffer: null,
          currentRide: null,
          reservedRide: null,
        ),
      ),
      routeEstimator: FakeRouteEstimator([]),
    );

    final assessment = (await service.assessWaitingRides(
      driverId: 'driver-001',
      rides: [waitingRide],
      now: now,
    )).single;
    expect(assessment.canSelect, isTrue);
    expect(assessment.combinedEtaSeconds, isNull);
    expect(assessment.reasonCode, isNull);
  });

  test(
    'waiting assessment blocks breaks, reservations and pending breaks',
    () async {
      final waitingRide = createRide(
        id: 'ride-next',
        status: RideRequestStatus.waitingForVehicle,
      );
      final availableShift = createShift(DriverQueueAvailability.available);
      final pendingOfferShift = ActiveDriverShift.restore(
        id: availableShift.id,
        driverId: availableShift.driverId,
        vehicleId: availableShift.vehicleId,
        startedAt: availableShift.startedAt,
        queueState: DriverQueueState.restore(
          driverId: 'driver-001',
          queuePrioritySince: now,
          availability: DriverQueueAvailability.available,
          shortBreaksUsed: 0,
          breakStartedAt: null,
          hasPendingOffer: true,
        ),
      );
      final cases = <(DriverWorkStateSnapshot, String)>[
        (
          DriverWorkStateSnapshot(
            activeShift: pendingOfferShift,
            pendingOffer: null,
            currentRide: null,
            reservedRide: null,
          ),
          'pending_offer',
        ),
        (
          DriverWorkStateSnapshot(
            activeShift: ActiveDriverShift.restore(
              id: availableShift.id,
              driverId: availableShift.driverId,
              vehicleId: availableShift.vehicleId,
              startedAt: availableShift.startedAt,
              queueState: DriverQueueState.restore(
                driverId: 'driver-001',
                queuePrioritySince: now,
                availability: DriverQueueAvailability.shortBreak,
                shortBreaksUsed: 1,
                breakStartedAt: now.subtract(const Duration(minutes: 1)),
                hasPendingOffer: false,
              ),
            ),
            pendingOffer: null,
            currentRide: null,
            reservedRide: null,
          ),
          'driver_on_break',
        ),
        (
          DriverWorkStateSnapshot(
            activeShift: availableShift,
            pendingOffer: null,
            currentRide: null,
            reservedRide: waitingRide,
          ),
          'reserved_ride_exists',
        ),
        (
          DriverWorkStateSnapshot(
            activeShift: availableShift,
            pendingOffer: null,
            currentRide: null,
            reservedRide: null,
            pendingBreakKind: 'short',
            pendingBreakRequestId: 'break-request-1',
          ),
          'break_scheduled',
        ),
      ];

      for (final (snapshot, expectedReason) in cases) {
        final service = RideDispatchService(
          repository: FakeRideRequestRepository([waitingRide]),
          driverShiftRepository: FakeDriverShiftRepository(availableShift),
          workStateRepository: FakeDriverWorkStateRepository(snapshot),
          routeEstimator: FakeRouteEstimator([]),
        );
        final assessment = (await service.assessWaitingRides(
          driverId: 'driver-001',
          rides: [waitingRide],
          now: now,
        )).single;
        expect(assessment.canSelect, isFalse);
        expect(assessment.reasonCode, expectedReason);
      }
    },
  );

  test('waiting assessment isolates invalid pickup routes per ride', () async {
    final currentRide = createRide(
      id: 'ride-current',
      status: RideRequestStatus.inProgress,
      assignedDriverId: 'driver-001',
      assignedVehicleId: 'vehicle-001',
      destination: 'Current destination',
    );
    final badPickup = createRide(
      id: 'ride-bad-pickup',
      status: RideRequestStatus.waitingForVehicle,
      pickupLatitude: 95,
      pickupLongitude: 23.26,
    );
    final goodPickup = createRide(
      id: 'ride-good-pickup',
      status: RideRequestStatus.waitingForVehicle,
      pickupLatitude: 42.66,
      pickupLongitude: 23.26,
    );
    final shift = createShift(DriverQueueAvailability.busy);
    final service = RideDispatchService(
      repository: FakeRideRequestRepository([badPickup, goodPickup]),
      driverShiftRepository: FakeDriverShiftRepository(shift),
      workStateRepository: FakeDriverWorkStateRepository(
        DriverWorkStateSnapshot(
          activeShift: shift,
          pendingOffer: null,
          currentRide: currentRide,
          reservedRide: null,
        ),
      ),
      liveLocationRepository: FakeDriverLiveLocationRepository(
        DriverLiveLocation(
          driverId: 'driver-001',
          latitude: 42.65,
          longitude: 23.25,
          updatedAt: now,
          gpsFixAt: now,
        ),
      ),
      routeEstimator: FakeRouteEstimator([
        estimate(durationSeconds: 0),
        estimate(durationSeconds: 100),
      ]),
    );

    final assessments = await service.assessWaitingRides(
      driverId: 'driver-001',
      rides: [badPickup, goodPickup],
      now: now,
    );
    expect(assessments[0].canSelect, isFalse);
    expect(assessments[0].reasonCode, 'route_unavailable');
    expect(assessments[1].canSelect, isTrue);
    expect(assessments[1].combinedEtaSeconds, 100);
  });
}
