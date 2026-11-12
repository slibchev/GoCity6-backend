import 'dart:async';
import 'dart:convert';

import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_orchestrator.dart';
import 'package:gocity6_backend/dispatch/dispatch_candidate_service.dart';
import 'package:gocity6_backend/dispatch/driver_district_queue.dart';
import 'package:gocity6_backend/dispatch/driver_live_location.dart';
import 'package:gocity6_backend/dispatch/driver_live_location_repository.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/waiting_board_redispatch_service.dart';
import 'package:gocity6_backend/dispatch/waiting_ride_redispatch_repository.dart';
import 'package:gocity6_backend/geography/district_matcher.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:test/test.dart';

typedef DistrictCandidatesAt =
    Future<List<DriverDistrictQueueCandidate>> Function({
      required int districtObjectId,
      required DateTime now,
    });

void main() {
  final now = DateTime.utc(2026, 10, 21, 12);

  test(
    'offers the oldest local ride first and preserves an accepted bonus',
    () async {
      final oldest = _ride(
        id: 'ride-oldest',
        pickup: 'Oldest local pickup',
        requestedAt: now.subtract(const Duration(minutes: 8)),
      );
      final bonusRide = _ride(
        id: 'ride-bonus',
        pickup: 'near',
        requestedAt: now.subtract(const Duration(minutes: 6)),
        dispatchRound: RideRequest.bonusDispatchRound,
        driverBonusMinor: RideRequest.driverBonusFiveEuroMinor,
        bonusDecision: RideBonusDecision.accepted,
      );
      final offerRepository = _FakeRideOfferRepository();
      final service = _service(
        now: now,
        rides: [oldest, bonusRide],
        drivers: [_driver('driver-1', now), _driver('driver-2', now)],
        offerRepository: offerRepository,
      );

      final offers = await service.dispatchAvailableWaiters();

      expect(offers.map((offer) => offer.rideId), [oldest.id, bonusRide.id]);
      expect(offers.first.source, RideOfferSource.waitingBoard);
      expect(offers.last.dispatchRound, RideOffer.bonusDispatchRound);
      expect(offers.last.bonusMinor, RideOffer.shortRideBonusMinor);
      expect(
        offers.last.expiresAt.difference(offers.last.offeredAt),
        const Duration(seconds: 15),
      );
      expect(bonusRide.bonusDecision, RideBonusDecision.accepted);
    },
  );

  test(
    'leaves an unlocated ride manual and continues to localized waiters',
    () async {
      final unlocatedRide = _ride(
        id: 'ride-unresolvable',
        pickup: 'Private pickup address',
        requestedAt: now.subtract(const Duration(minutes: 9)),
        pickupLatitude: null,
        pickupLongitude: null,
      );
      final localizedRide = _ride(
        id: 'ride-valid',
        pickup: 'Valid pickup',
        requestedAt: now.subtract(const Duration(minutes: 7)),
      );
      final offersRepository = _FakeRideOfferRepository();
      final service = _service(
        now: now,
        rides: [unlocatedRide, localizedRide],
        drivers: [_driver('driver-1', now), _driver('driver-2', now)],
        offerRepository: offersRepository,
      );

      final offers = await service.dispatchAvailableWaiters();

      expect(offers.map((offer) => offer.rideId), [localizedRide.id]);
      expect(
        offersRepository.offers.map((offer) => offer.rideId),
        isNot(contains(unlocatedRide.id)),
      );
    },
  );

  test(
    'skips legacy current-location labels and continues to later rides',
    () async {
      final legacyRide = _ride(
        id: 'ride-legacy-location',
        pickup: 'My location',
        requestedAt: now.subtract(const Duration(minutes: 8)),
        pickupLatitude: null,
        pickupLongitude: null,
      );
      final validRide = _ride(
        id: 'ride-valid-after-legacy',
        pickup: 'Valid pickup',
        requestedAt: now.subtract(const Duration(minutes: 7)),
      );
      final service = _service(
        now: now,
        rides: [legacyRide, validRide],
        drivers: [_driver('driver-1', now)],
      );

      final offers = await service.dispatchAvailableWaiters();

      expect(offers.map((offer) => offer.rideId), [validRide.id]);
    },
  );

  test(
    'a free driver in another district receives no automatic offer',
    () async {
      final ride = _ride(
        id: 'ride-local-only',
        pickup: 'District 316 pickup',
        requestedAt: now.subtract(const Duration(minutes: 5)),
      );
      final offerRepository = _FakeRideOfferRepository();
      final service = _service(
        now: now,
        rides: [ride],
        drivers: [_driver('driver-other-district', now)],
        districtByDriver: const {'driver-other-district': 317},
        offerRepository: offerRepository,
      );

      expect(await service.dispatchAvailableWaiters(), isEmpty);
      expect(offerRepository.offers, isEmpty);
    },
  );

  test(
    'an ambiguous pickup remains manual instead of guessing a district',
    () async {
      final ride = _ride(
        id: 'ride-ambiguous-pickup',
        pickup: 'District boundary pickup',
        requestedAt: now.subtract(const Duration(minutes: 5)),
        pickupLongitude: 23.45,
      );
      final offerRepository = _FakeRideOfferRepository();
      final service = _service(
        now: now,
        rides: [ride],
        drivers: [_driver('driver-a', now), _driver('driver-b', now)],
        matcher: _overlappingDistrictMatcher(),
        offerRepository: offerRepository,
      );

      expect(await service.dispatchAvailableWaiters(), isEmpty);
      expect(offerRepository.offers, isEmpty);
    },
  );

  test('a newly available local driver receives the next scan offer', () async {
    final ride = _ride(
      id: 'ride-waits-for-local-car',
      pickup: 'District 316 pickup',
      requestedAt: now.subtract(const Duration(minutes: 5)),
    );
    final driver = _driver('driver-local', now);
    final candidate = _candidate(
      driver: driver,
      districtObjectId: 316,
      now: now,
    );
    var localDriverAvailable = false;
    final offers = _FakeRideOfferRepository();
    final service = _service(
      now: now,
      rides: [ride],
      drivers: [driver, _driver('driver-other', now)],
      districtByDriver: const {'driver-other': 317},
      districtCandidates: ({required districtObjectId, required now}) async =>
          districtObjectId == 316 && localDriverAvailable
          ? [candidate]
          : const [],
      offerRepository: offers,
    );

    expect(await service.dispatchAvailableWaiters(), isEmpty);
    localDriverAvailable = true;
    final nextScan = await service.dispatchAvailableWaiters(
      at: now.add(const Duration(seconds: 10)),
    );

    expect(nextScan, hasLength(1));
    expect(nextScan.single.driverId, 'driver-local');
    expect(nextScan.single.dispatchDistrictObjectId, 316);
  });

  test(
    'local offer order is FIFO and ETA cannot promote a later driver',
    () async {
      final ride = _ride(
        id: 'ride-fifo',
        pickup: 'District 316 pickup',
        requestedAt: now.subtract(const Duration(minutes: 5)),
      );
      final first = _candidate(
        driver: _driver('driver-first', now),
        districtObjectId: 316,
        now: now,
        fifoPriorityAt: now.subtract(const Duration(minutes: 20)),
        longitude: 23.2,
      );
      final second = _candidate(
        driver: _driver('driver-second', now),
        districtObjectId: 316,
        now: now,
        fifoPriorityAt: now.subtract(const Duration(minutes: 10)),
        longitude: 23.3,
      );
      final service = _service(
        now: now,
        rides: [ride],
        drivers: [_driver('driver-first', now), _driver('driver-second', now)],
        districtCandidates: ({required districtObjectId, required now}) async =>
            [second, first],
        routeEstimator: _EtaOpposesFifoRouteEstimator(),
      );

      final offers = await service.dispatchAvailableWaiters();

      expect(offers, hasLength(1));
      expect(offers.single.driverId, 'driver-first');
      expect(offers.single.etaSeconds, 900);
    },
  );

  test(
    'customer-cancellation priority precedes ordinary local FIFO rank',
    () async {
      final ride = _ride(
        id: 'ride-cancellation-priority',
        pickup: 'District 316 pickup',
        requestedAt: now.subtract(const Duration(minutes: 5)),
      );
      final ordinary = _candidate(
        driver: _driver('driver-ordinary', now),
        districtObjectId: 316,
        now: now,
        fifoPriorityAt: now.subtract(const Duration(hours: 1)),
      );
      final cancellationPriority = _candidate(
        driver: _driver('driver-cancellation-priority', now),
        districtObjectId: 316,
        now: now,
        fifoPriorityAt: now.subtract(const Duration(minutes: 1)),
        hasCustomerCancellationPriority: true,
      );
      final service = _service(
        now: now,
        rides: [ride],
        drivers: [
          _driver('driver-ordinary', now),
          _driver('driver-cancellation-priority', now),
        ],
        districtCandidates: ({required districtObjectId, required now}) async =>
            [ordinary, cancellationPriority],
      );

      final offers = await service.dispatchAvailableWaiters();

      expect(offers.single.driverId, 'driver-cancellation-priority');
    },
  );

  test(
    'route estimation failure leaves ETA null and keeps FIFO head',
    () async {
      final ride = _ride(
        id: 'ride-no-eta',
        pickup: 'District 316 pickup',
        requestedAt: now.subtract(const Duration(minutes: 5)),
      );
      final first = _candidate(
        driver: _driver('driver-first-no-eta', now),
        districtObjectId: 316,
        now: now,
        fifoPriorityAt: now.subtract(const Duration(minutes: 20)),
      );
      final second = _candidate(
        driver: _driver('driver-second-no-eta', now),
        districtObjectId: 316,
        now: now,
        fifoPriorityAt: now.subtract(const Duration(minutes: 10)),
      );
      final service = _service(
        now: now,
        rides: [ride],
        drivers: [
          _driver('driver-first-no-eta', now),
          _driver('driver-second-no-eta', now),
        ],
        districtCandidates: ({required districtObjectId, required now}) async =>
            [second, first],
        routeEstimator: _RouteEstimationFailureEstimator(),
      );

      final offers = await service.dispatchAvailableWaiters();

      expect(offers.single.driverId, 'driver-first-no-eta');
      expect(offers.single.etaSeconds, isNull);
      expect(offers.single.distanceMeters, isNull);
    },
  );

  test('does not hide unexpected route-estimator StateError', () async {
    final ride = _ride(
      id: 'ride-program-error',
      pickup: 'Valid pickup',
      requestedAt: now.subtract(const Duration(minutes: 5)),
    );
    final service = _service(
      now: now,
      rides: [ride],
      drivers: [_driver('driver-1', now)],
      routeEstimator: _StateErrorRouteEstimator(),
    );

    await expectLater(
      service.dispatchAvailableWaiters(),
      throwsA(isA<StateError>()),
    );
  });

  test('does not create offers at or after the 30-minute boundary', () async {
    final oldRide = _ride(
      id: 'ride-old',
      pickup: 'near',
      requestedAt: now.subtract(const Duration(minutes: 30)),
    );
    final service = _service(
      now: now,
      rides: [oldRide],
      drivers: [_driver('driver-1', now)],
    );

    expect(await service.dispatchAvailableWaiters(), isEmpty);
  });

  test(
    'a rejected waiting-board offer is not repeated to the same driver',
    () async {
      final ride = _ride(
        id: 'ride-1',
        pickup: 'near',
        requestedAt: now.subtract(const Duration(minutes: 5)),
      );
      final offerRepository = _FakeRideOfferRepository();
      final service = _service(
        now: now,
        rides: [ride],
        drivers: [_driver('driver-1', now)],
        offerRepository: offerRepository,
      );

      final offers = await service.dispatchAvailableWaiters();
      await offerRepository.reject(
        offers.single,
        now.add(const Duration(seconds: 1)),
      );

      expect(await service.dispatchAvailableWaiters(), isEmpty);
    },
  );

  test(
    'one waiting ride receives at most one active offer per reconciliation',
    () async {
      final ride = _ride(
        id: 'ride-1',
        pickup: 'near',
        requestedAt: now.subtract(const Duration(minutes: 5)),
      );
      final service = _service(
        now: now,
        rides: [ride],
        drivers: [_driver('driver-1', now), _driver('driver-2', now)],
      );

      final offers = await service.dispatchAvailableWaiters();

      expect(offers, hasLength(1));
      expect(offers.single.rideId, ride.id);
    },
  );
}

RideRequest _ride({
  required String id,
  required String pickup,
  required DateTime requestedAt,
  double? pickupLatitude = 42.7,
  double? pickupLongitude = 23.3,
  int dispatchRound = RideRequest.normalDispatchRound,
  int driverBonusMinor = RideRequest.noDriverBonusMinor,
  RideBonusDecision bonusDecision = RideBonusDecision.notOffered,
}) {
  return RideRequest(
    id: id,
    pickup: pickup,
    pickupLatitude: pickupLatitude,
    pickupLongitude: pickupLongitude,
    destination: 'destination',
    passengers: 1,
    requestedAt: requestedAt,
    status: RideRequestStatus.waitingForVehicle,
    dispatchRound: dispatchRound,
    driverBonusMinor: driverBonusMinor,
    bonusDecision: bonusDecision,
  );
}

ActiveDriverShift _driver(String driverId, DateTime now) {
  return ActiveDriverShift.restore(
    id: 'shift-$driverId',
    driverId: driverId,
    vehicleId: 'vehicle-$driverId',
    startedAt: now.subtract(const Duration(hours: 1)),
    queueState: DriverQueueState.restore(
      driverId: driverId,
      queuePrioritySince: now.subtract(const Duration(minutes: 10)),
      availability: DriverQueueAvailability.available,
      shortBreaksUsed: 0,
      breakStartedAt: null,
      hasPendingOffer: false,
    ),
  );
}

WaitingBoardRedispatchService _service({
  required DateTime now,
  required List<RideRequest> rides,
  required List<ActiveDriverShift> drivers,
  _FakeRideOfferRepository? offerRepository,
  RouteEstimator? routeEstimator,
  Map<String, int> districtByDriver = const {},
  DistrictCandidatesAt? districtCandidates,
  DistrictMatcher? matcher,
}) {
  final districtMatcher = matcher ?? _testDistrictMatcher();
  final shiftRepository = _FakeShiftRepository(drivers);
  final locationRepository = _FakeLocationRepository(
    drivers.map(
      (shift) => _locationForDriver(
        driverId: shift.driverId,
        districtObjectId: districtByDriver[shift.driverId] ?? 316,
        now: now,
      ),
    ),
  );
  final offers = offerRepository ?? _FakeRideOfferRepository();
  final candidates = DispatchCandidateService(
    shiftRepository: shiftRepository,
    liveLocationRepository: locationRepository,
    routeEstimator: routeEstimator ?? _FakeRouteEstimator(),
  );
  final atomicOffers = _FakeAtomicOfferRepository(offers);
  final orchestrator = AutomaticDispatchOrchestrator(
    candidateService: candidates,
    offerRepository: offers,
    atomicOfferRepository: atomicOffers,
    districtMatcher: districtMatcher,
    findDistrictCandidates:
        districtCandidates ??
        ({required districtObjectId, required now}) async => [
          for (final shift in drivers)
            if ((districtByDriver[shift.driverId] ?? 316) == districtObjectId)
              _candidate(
                driver: shift,
                districtObjectId: districtObjectId,
                now: now,
              ),
        ],
  );

  return WaitingBoardRedispatchService(
    rideRepository: _FakeWaitingRideRepository(rides, offers),
    candidateService: candidates,
    dispatchOrchestrator: orchestrator,
    offerIdFactory: () => 'offer-${offers.offers.length + 1}',
    now: () => now,
  );
}

DistrictMatcher _testDistrictMatcher() => DistrictMatcher.fromGeoJsonString(
  jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      _districtFeature(316, 23.0, 23.5),
      _districtFeature(317, 23.5, 24.0),
    ],
  }),
);

DistrictMatcher _overlappingDistrictMatcher() =>
    DistrictMatcher.fromGeoJsonString(
      jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          _districtFeature(316, 23.0, 23.6),
          _districtFeature(317, 23.4, 24.0),
        ],
      }),
    );

Map<String, Object> _districtFeature(int objectId, double west, double east) =>
    {
      'type': 'Feature',
      'properties': {
        'object_id': objectId,
        'id': 'district-$objectId',
        'kvname': 'District $objectId',
      },
      'geometry': {
        'type': 'Polygon',
        'coordinates': [
          [
            [west, 42.5],
            [east, 42.5],
            [east, 43.0],
            [west, 43.0],
            [west, 42.5],
          ],
        ],
      },
    };

DriverDistrictQueueCandidate _candidate({
  required ActiveDriverShift driver,
  required int districtObjectId,
  required DateTime now,
  DateTime? fifoPriorityAt,
  bool hasCustomerCancellationPriority = false,
  double? longitude,
}) {
  final location = _locationForDriver(
    driverId: driver.driverId,
    districtObjectId: districtObjectId,
    now: now,
    longitude: longitude,
  );
  return DriverDistrictQueueCandidate(
    shiftId: driver.id,
    driverId: driver.driverId,
    vehicleId: driver.vehicleId,
    districtObjectId: districtObjectId,
    enteredAt: now.subtract(const Duration(hours: 1)),
    fifoPriorityAt: fifoPriorityAt ?? driver.queueState.queuePrioritySince,
    location: location,
    hasCustomerCancellationPriority: hasCustomerCancellationPriority,
  );
}

DriverLiveLocation _locationForDriver({
  required String driverId,
  required int districtObjectId,
  required DateTime now,
  double? longitude,
}) => DriverLiveLocation(
  driverId: driverId,
  latitude: 42.7,
  longitude: longitude ?? (districtObjectId == 317 ? 23.8 : 23.3),
  updatedAt: now.subtract(const Duration(seconds: 1)),
  gpsFixAt: now.subtract(const Duration(seconds: 1)),
);

class _FakeWaitingRideRepository implements WaitingRideRedispatchRepository {
  final List<RideRequest> rides;
  final _FakeRideOfferRepository offers;

  _FakeWaitingRideRepository(this.rides, this.offers);

  @override
  Future<List<RideRequest>> findOldestPage({
    required DateTime notBefore,
    DateTime? afterRequestedAt,
    String? afterRideId,
    int limit = 50,
  }) async {
    final filtered =
        rides.where((ride) {
          if (!ride.requestedAt.isAfter(notBefore)) return false;
          if (offers.offers.any(
            (offer) => offer.rideId == ride.id && offer.isPending,
          )) {
            return false;
          }
          if (afterRequestedAt == null) return true;
          return ride.requestedAt.isAfter(afterRequestedAt) ||
              (ride.requestedAt.isAtSameMomentAs(afterRequestedAt) &&
                  ride.id.compareTo(afterRideId!) > 0);
        }).toList()..sort((a, b) {
          final timeOrder = a.requestedAt.compareTo(b.requestedAt);
          return timeOrder == 0 ? a.id.compareTo(b.id) : timeOrder;
        });

    return filtered.take(limit).toList();
  }
}

class _FakeShiftRepository implements DriverShiftRepository {
  final List<ActiveDriverShift> shifts;

  _FakeShiftRepository(this.shifts);

  @override
  Future<List<ActiveDriverShift>> findAllActive() async => shifts;

  @override
  Future<ActiveDriverShift?> findActiveByDriverId(String driverId) async {
    for (final shift in shifts) {
      if (shift.driverId == driverId) return shift;
    }
    return null;
  }

  @override
  Future<ActiveDriverShift> startShift({
    required String shiftId,
    required String driverId,
    required String vehicleId,
    required DateTime startedAt,
  }) => throw UnimplementedError();

  @override
  Future<ActiveDriverShift> saveQueueState({
    required String shiftId,
    required DriverQueueState queueState,
  }) => throw UnimplementedError();

  @override
  Future<void> endShift({required String shiftId, required DateTime endedAt}) =>
      throw UnimplementedError();
}

class _FakeLocationRepository implements DriverLiveLocationRepository {
  final Map<String, DriverLiveLocation> locations;

  _FakeLocationRepository(Iterable<DriverLiveLocation> values)
    : locations = {for (final value in values) value.driverId: value};

  @override
  Future<DriverLiveLocation?> findByDriverId(String driverId) async =>
      locations[driverId];

  @override
  Future<DriverLiveLocation> save({
    required String driverId,
    required double latitude,
    required double longitude,
    required DateTime updatedAt,
  }) => throw UnimplementedError();
}

class _FakeRouteEstimator implements RouteEstimator {
  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) async {
    return RouteEstimate(distanceMeters: 500, durationSeconds: 120);
  }
}

class _EtaOpposesFifoRouteEstimator implements RouteEstimator {
  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) async {
    final fifoHead = origin.longitude == 23.2;
    return RouteEstimate(
      distanceMeters: fifoHead ? 30000 : 10,
      durationSeconds: fifoHead ? 900 : 1,
    );
  }
}

class _RouteEstimationFailureEstimator implements RouteEstimator {
  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) async {
    throw RouteEstimationFailure(RouteEstimationFailureReason.timeout);
  }
}

class _StateErrorRouteEstimator implements RouteEstimator {
  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) async {
    throw StateError('Unexpected route-estimator failure.');
  }
}

class _FakeRideOfferRepository implements RideOfferRepository {
  final List<RideOffer> offers = [];

  Future<void> reject(RideOffer offer, DateTime at) async {
    final index = offers.indexWhere((existing) => existing.id == offer.id);
    offers[index] = offer.reject(at);
  }

  @override
  Future<RideOffer?> findById(String id) async {
    for (final offer in offers) {
      if (offer.id == id) return offer;
    }
    return null;
  }

  @override
  Future<List<RideOffer>> findByRideId(String rideId) async =>
      offers.where((offer) => offer.rideId == rideId).toList();

  @override
  Future<List<RideOffer>> findPendingExpiredAt(DateTime now) async => offers
      .where((offer) => offer.isPending && offer.isExpiredAt(now))
      .toList();

  @override
  Future<void> create(RideOffer offer) async => offers.add(offer);

  @override
  Future<bool> resolve(RideOffer offer) async {
    final index = offers.indexWhere((existing) => existing.id == offer.id);
    if (index == -1) return false;
    offers[index] = offer;
    return true;
  }

  @override
  Future<bool> markDisplayed({
    required String offerId,
    required String driverId,
    required DateTime displayedAt,
  }) async => false;
}

class _FakeAtomicOfferRepository implements AtomicRideOfferRepository {
  final _FakeRideOfferRepository offers;

  _FakeAtomicOfferRepository(this.offers);

  @override
  Future<RideOffer> createPendingOffer({required RideOffer offer}) async {
    offers.offers.add(offer);
    return offer;
  }

  @override
  Future<RideOffer> acceptPendingOffer({
    required String offerId,
    required DateTime now,
  }) => throw UnimplementedError();

  @override
  Future<RideOffer> rejectPendingOffer({
    required String offerId,
    required DateTime now,
  }) => throw UnimplementedError();

  @override
  Future<RideOffer> expirePendingOffer({
    required String offerId,
    required DateTime now,
  }) => throw UnimplementedError();

  @override
  Future<void> movePendingRideToWaitingForVehicle({required String rideId}) =>
      throw UnimplementedError();
}
