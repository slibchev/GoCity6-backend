import 'dart:async';
import 'dart:convert';

import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_orchestrator.dart';
import 'package:gocity6_backend/dispatch/dispatch_candidate_service.dart';
import 'package:gocity6_backend/dispatch/driver_live_location.dart';
import 'package:gocity6_backend/dispatch/driver_live_location_repository.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/waiting_board_redispatch_service.dart';
import 'package:gocity6_backend/dispatch/waiting_ride_redispatch_repository.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/ride/ride_request_status.dart';
import 'package:gocity6_backend/routing/google_route_estimator.dart';
import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 21, 12);

  test(
    'skips an unsuitable oldest ride and preserves an accepted bonus',
    () async {
      final tooFar = _ride(
        id: 'ride-oldest',
        pickup: 'far',
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
        rides: [tooFar, bonusRide],
        drivers: [_driver('driver-1', now)],
        offerRepository: offerRepository,
      );

      final offers = await service.dispatchAvailableWaiters();

      expect(offers, hasLength(1));
      expect(offers.single.rideId, bonusRide.id);
      expect(offers.single.source, RideOfferSource.waitingBoard);
      expect(offers.single.dispatchRound, RideOffer.bonusDispatchRound);
      expect(offers.single.bonusMinor, RideOffer.shortRideBonusMinor);
      expect(
        offers.single.expiresAt.difference(offers.single.offeredAt),
        const Duration(seconds: 15),
      );
      expect(bonusRide.bonusDecision, RideBonusDecision.accepted);
    },
  );

  test(
    'skips one unresolvable ride once and continues through later waiters',
    () async {
      final invalidAddress = 'Private pickup address';
      final invalidRide = _ride(
        id: 'ride-unresolvable',
        pickup: invalidAddress,
        requestedAt: now.subtract(const Duration(minutes: 9)),
      );
      final firstValidRide = _ride(
        id: 'ride-valid-1',
        pickup: 'Valid pickup one',
        requestedAt: now.subtract(const Duration(minutes: 8)),
      );
      final secondValidRide = _ride(
        id: 'ride-valid-2',
        pickup: 'Valid pickup two',
        requestedAt: now.subtract(const Duration(minutes: 7)),
      );
      final geocodeCalls = <String, int>{};
      final routeEstimator = GoogleRouteEstimator(
        apiKey: 'test-api-key',
        client: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.host == 'maps.googleapis.com') {
            final address = request.url.queryParameters['address']!;
            geocodeCalls.update(
              address,
              (count) => count + 1,
              ifAbsent: () => 1,
            );

            if (address == invalidAddress) {
              return http.Response(
                jsonEncode({'status': 'ZERO_RESULTS', 'results': <Object>[]}),
                200,
              );
            }

            return http.Response(
              jsonEncode({
                'status': 'OK',
                'results': [
                  {
                    'geometry': {
                      'location': {'lat': 42.7, 'lng': 23.3},
                    },
                  },
                ],
              }),
              200,
            );
          }

          final requestBody = jsonDecode(request.body) as Map<String, dynamic>;
          final origins = requestBody['origins'] as List<dynamic>;
          final elements = List.generate(
            origins.length,
            (index) => {
              'originIndex': index,
              'destinationIndex': 0,
              'condition': 'ROUTE_EXISTS',
              'duration': '120s',
              'distanceMeters': 1000,
            },
          );
          return http.Response(jsonEncode(elements), 200);
        }),
      );
      final offersRepository = _FakeRideOfferRepository();
      final service = _service(
        now: now,
        rides: [invalidRide, firstValidRide, secondValidRide],
        drivers: [_driver('driver-1', now), _driver('driver-2', now)],
        offerRepository: offersRepository,
        routeEstimator: routeEstimator,
      );
      final logMessages = <String>[];

      final offers = await runZoned(
        () => service.dispatchAvailableWaiters(),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => logMessages.add(line),
        ),
      );

      expect(offers.map((offer) => offer.rideId), [
        firstValidRide.id,
        secondValidRide.id,
      ]);
      expect(geocodeCalls[invalidAddress], 1);
      expect(
        logMessages,
        contains(
          'Waiting-board ride skipped: '
          'rideId=${invalidRide.id}; '
          'reason=${RouteWaypointFailureReason.geocodingNoResults.name}.',
        ),
      );
      expect(logMessages.join('\n'), isNot(contains(invalidAddress)));
      expect(
        offersRepository.offers.map((offer) => offer.rideId),
        isNot(contains(invalidRide.id)),
      );
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
  int dispatchRound = RideRequest.normalDispatchRound,
  int driverBonusMinor = RideRequest.noDriverBonusMinor,
  RideBonusDecision bonusDecision = RideBonusDecision.notOffered,
}) {
  return RideRequest(
    id: id,
    pickup: pickup,
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
}) {
  final shiftRepository = _FakeShiftRepository(drivers);
  final locationRepository = _FakeLocationRepository(
    drivers.map(
      (shift) => DriverLiveLocation(
        driverId: shift.driverId,
        latitude: shift.driverId.endsWith('2') ? 42.1 : 42.0,
        longitude: 23.3,
        updatedAt: now.subtract(const Duration(seconds: 1)),
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
  );

  return WaitingBoardRedispatchService(
    rideRepository: _FakeWaitingRideRepository(rides, offers),
    candidateService: candidates,
    dispatchOrchestrator: orchestrator,
    offerIdFactory: () => 'offer-${offers.offers.length + 1}',
    now: () => now,
  );
}

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
    final tooFar = destination.address == 'far';
    return RouteEstimate(
      distanceMeters: tooFar ? 20000 : 500,
      durationSeconds: tooFar ? 700 : 120,
    );
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
