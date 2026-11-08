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
import 'package:gocity6_backend/geography/district_matcher.dart';
import 'package:gocity6_backend/ride/ride_request.dart';
import 'package:gocity6_backend/routing/google_route_estimator.dart';
import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 12);
  late DistrictMatcher matcher;

  setUp(() {
    matcher = DistrictMatcher.fromGeoJsonString(
      jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          _districtFeature(316, 'НДК', 23, 23.5),
          _districtFeature(317, 'Център', 23.5, 24),
        ],
      }),
    );
  });

  test(
    'manual pickup coordinates use the same local FIFO as GPS pickup',
    () async {
      final routeEstimator = _FakeRouteEstimator(
        handler: (_, _) async =>
            RouteEstimate(distanceMeters: 40000, durationSeconds: 2400),
      );
      final localCandidates = [
        _candidate('later', now.subtract(const Duration(minutes: 1))),
        _candidate('first', now.subtract(const Duration(minutes: 5))),
      ];
      final repository = _FakeAtomicRideOfferRepository();
      final orchestrator = _orchestrator(
        matcher: matcher,
        routeEstimator: routeEstimator,
        repository: repository,
        candidates: localCandidates,
      );

      final offer = await orchestrator.createNextOffer(
        ride: RideRequest(
          id: 'ride-manual',
          pickup: 'ул. Верила 2, София',
          pickupLatitude: 42.69,
          pickupLongitude: 23.2,
          destination: 'Paradise Center',
          passengers: 1,
          requestedAt: now,
        ),
        offerId: 'offer-manual',
        now: now,
      );

      expect(offer?.driverId, 'first');
      expect(offer?.dispatchDistrictObjectId, 316);
      expect(offer?.etaSeconds, 2400);
      expect(routeEstimator.calls, 1);
    },
  );

  test('local FIFO has no 600 second ETA cutoff', () async {
    final repository = _FakeAtomicRideOfferRepository();
    final orchestrator = _orchestrator(
      matcher: matcher,
      routeEstimator: _FakeRouteEstimator(
        handler: (_, _) async =>
            RouteEstimate(distanceMeters: 50000, durationSeconds: 601),
      ),
      repository: repository,
      candidates: [_candidate('local-first', now)],
    );

    final offer = await orchestrator.createNextOffer(
      ride: _ride('ride-601', now),
      offerId: 'offer-601',
      now: now,
    );

    expect(offer?.driverId, 'local-first');
    expect(offer?.etaSeconds, 601);
  });

  test(
    'route failure does not skip the local FIFO head and stores null metrics',
    () async {
      final repository = _FakeAtomicRideOfferRepository();
      final orchestrator = _orchestrator(
        matcher: matcher,
        routeEstimator: _FakeRouteEstimator(
          handler: (_, _) async => throw RouteEstimationFailure(
            RouteEstimationFailureReason.networkUnavailable,
          ),
        ),
        repository: repository,
        candidates: [
          _candidate('first', now.subtract(const Duration(minutes: 2))),
          _candidate('second', now.subtract(const Duration(minutes: 1))),
        ],
      );

      final offer = await orchestrator.createNextOffer(
        ride: _ride('ride-route-error', now),
        offerId: 'offer-route-error',
        now: now,
      );

      expect(offer?.driverId, 'first');
      expect(offer?.etaSeconds, isNull);
      expect(offer?.distanceMeters, isNull);
      expect(offer?.driverId, 'first');
    },
  );

  test('Google transport StateError still offers the local FIFO head without metrics', () async {
    final repository = _FakeAtomicRideOfferRepository();
    final routeEstimator = GoogleRouteEstimator(
      apiKey: 'test-api-key',
      client: MockClient((_) async => throw StateError('transport state')),
    );
    final orchestrator = _orchestrator(
      matcher: matcher,
      routeEstimator: routeEstimator,
      repository: repository,
      candidates: [
        _candidate('first', now.subtract(const Duration(minutes: 2))),
        _candidate('second', now.subtract(const Duration(minutes: 1))),
      ],
    );

    final offer = await orchestrator.createNextOffer(
      ride: _ride('ride-google-state-error', now),
      offerId: 'offer-google-state-error',
      now: now,
    );

    expect(offer?.driverId, 'first');
    expect(offer?.etaSeconds, isNull);
    expect(offer?.distanceMeters, isNull);
    expect(repository.attemptedDriverIds, ['first']);
  });

  test('Google Routes timeout still offers the local FIFO head', () async {
    final repository = _FakeAtomicRideOfferRepository();
    final routeEstimator = GoogleRouteEstimator(
      apiKey: 'test-api-key',
      client: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return http.Response('too late', 200);
      }),
      requestTimeout: const Duration(milliseconds: 5),
    );
    final orchestrator = _orchestrator(
      matcher: matcher,
      routeEstimator: routeEstimator,
      repository: repository,
      candidates: [
        _candidate('first', now.subtract(const Duration(minutes: 2))),
        _candidate('second', now.subtract(const Duration(minutes: 1))),
      ],
    );

    final offer = await orchestrator.createNextOffer(
      ride: _ride('ride-google-timeout', now),
      offerId: 'offer-google-timeout',
      now: now,
    );

    expect(offer?.driverId, 'first');
    expect(offer?.etaSeconds, isNull);
    expect(offer?.distanceMeters, isNull);
    expect(repository.attemptedDriverIds, ['first']);
  });

  test('Google Routes HTTP failure still offers the local FIFO head', () async {
    final repository = _FakeAtomicRideOfferRepository();
    final routeEstimator = GoogleRouteEstimator(
      apiKey: 'test-api-key',
      client: MockClient((_) async => http.Response('unavailable', 503)),
    );
    final orchestrator = _orchestrator(
      matcher: matcher,
      routeEstimator: routeEstimator,
      repository: repository,
      candidates: [
        _candidate('first', now.subtract(const Duration(minutes: 2))),
        _candidate('second', now.subtract(const Duration(minutes: 1))),
      ],
    );

    final offer = await orchestrator.createNextOffer(
      ride: _ride('ride-google-http-failure', now),
      offerId: 'offer-google-http-failure',
      now: now,
    );

    expect(offer?.driverId, 'first');
    expect(offer?.etaSeconds, isNull);
    expect(offer?.distanceMeters, isNull);
    expect(repository.attemptedDriverIds, ['first']);
  });

  test('unclassified StateError is not swallowed as a route failure', () async {
    final repository = _FakeAtomicRideOfferRepository();
    final orchestrator = _orchestrator(
      matcher: matcher,
      routeEstimator: _FakeRouteEstimator(
        handler: (_, _) async => throw StateError('programming invariant'),
      ),
      repository: repository,
      candidates: [_candidate('first', now)],
    );

    await expectLater(
      orchestrator.createNextOffer(
        ride: _ride('ride-program-error', now),
        offerId: 'offer-program-error',
        now: now,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error is RouteEstimationFailure,
          'is classified as an external route failure',
          isFalse,
        ),
      ),
    );
    expect(repository.attemptedDriverIds, isEmpty);
  });

  test(
    'atomic candidate conflict advances only to the next local FIFO member',
    () async {
      final repository = _FakeAtomicRideOfferRepository(
        conflictDriverOnce: 'first',
      );
      final orchestrator = _orchestrator(
        matcher: matcher,
        routeEstimator: _FakeRouteEstimator(
          handler: (_, _) async =>
              RouteEstimate(distanceMeters: 1000, durationSeconds: 100),
        ),
        repository: repository,
        candidates: [
          _candidate('second', now.subtract(const Duration(minutes: 1))),
          _candidate('first', now.subtract(const Duration(minutes: 2))),
        ],
      );

      final offer = await orchestrator.createNextOffer(
        ride: _ride('ride-conflict', now),
        offerId: 'offer-conflict',
        now: now,
      );

      expect(offer?.driverId, 'second');
      expect(repository.attemptedDriverIds, ['first', 'second']);
    },
  );

  test('unknown or overlapping pickup does not guess a district', () async {
    final repository = _FakeAtomicRideOfferRepository();
    var candidateLookupCount = 0;
    final orchestrator = _orchestrator(
      matcher: matcher,
      routeEstimator: _FakeRouteEstimator(
        handler: (_, _) async =>
            RouteEstimate(distanceMeters: 1000, durationSeconds: 100),
      ),
      repository: repository,
      candidates: [_candidate('local', now)],
      onCandidateLookup: () => candidateLookupCount++,
    );

    final noCoordinates = await orchestrator.createNextOffer(
      ride: RideRequest(
        id: 'ride-no-coordinates',
        pickup: 'ул. без координати',
        destination: 'Paradise Center',
        passengers: 1,
        requestedAt: now,
      ),
      offerId: 'offer-no-coordinates',
      now: now,
    );
    final boundaryOverlap = await orchestrator.createNextOffer(
      ride: RideRequest(
        id: 'ride-overlap',
        pickup: 'на границата',
        pickupLatitude: 42.7,
        pickupLongitude: 23.5,
        destination: 'Paradise Center',
        passengers: 1,
        requestedAt: now,
      ),
      offerId: 'offer-overlap',
      now: now,
    );

    expect(noCoordinates, isNull);
    expect(boundaryOverlap, isNull);
    expect(candidateLookupCount, 0);
    expect(repository.createdOffers, isEmpty);
  });
}

Map<String, Object> _districtFeature(
  int objectId,
  String name,
  double west,
  double east,
) => {
  'type': 'Feature',
  'properties': {'object_id': objectId, 'id': 'uuid-$objectId', 'kvname': name},
  'geometry': {
    'type': 'Polygon',
    'coordinates': [
      [
        [west, 42.5],
        [east, 42.5],
        [east, 43],
        [west, 43],
        [west, 42.5],
      ],
    ],
  },
};

RideRequest _ride(String id, DateTime now) => RideRequest(
  id: id,
  pickup: 'Somewhere in NDK',
  pickupLatitude: 42.7,
  pickupLongitude: 23.2,
  destination: 'Paradise Center',
  passengers: 1,
  requestedAt: now,
);

DriverDistrictQueueCandidate _candidate(String id, DateTime fifoPriorityAt) =>
    DriverDistrictQueueCandidate(
      shiftId: 'shift-$id',
      driverId: id,
      vehicleId: 'vehicle-$id',
      districtObjectId: 316,
      enteredAt: fifoPriorityAt.subtract(const Duration(minutes: 1)),
      fifoPriorityAt: fifoPriorityAt,
      location: DriverLiveLocation(
        driverId: id,
        latitude: 42.69,
        longitude: 23.2,
        updatedAt: DateTime.utc(
          2026,
          11,
          4,
          12,
        ).subtract(const Duration(seconds: 2)),
        gpsFixAt: DateTime.utc(
          2026,
          11,
          4,
          12,
        ).subtract(const Duration(seconds: 2)),
      ),
    );

AutomaticDispatchOrchestrator _orchestrator({
  required DistrictMatcher matcher,
  required RouteEstimator routeEstimator,
  required _FakeAtomicRideOfferRepository repository,
  required List<DriverDistrictQueueCandidate> candidates,
  void Function()? onCandidateLookup,
}) => AutomaticDispatchOrchestrator(
  candidateService: DispatchCandidateService(
    shiftRepository: _UnusedDriverShiftRepository(),
    liveLocationRepository: _UnusedDriverLocationRepository(),
    routeEstimator: routeEstimator,
  ),
  offerRepository: _FakeRideOfferRepository(),
  atomicOfferRepository: repository,
  districtMatcher: matcher,
  findDistrictCandidates: ({required districtObjectId, required now}) async {
    onCandidateLookup?.call();
    return candidates
        .where((candidate) => candidate.districtObjectId == districtObjectId)
        .toList(growable: false);
  },
);

final class _FakeRouteEstimator implements RouteEstimator {
  _FakeRouteEstimator({required this.handler});

  final Future<RouteEstimate> Function(
    RouteWaypoint origin,
    RouteWaypoint destination,
  )
  handler;
  var calls = 0;

  @override
  Future<RouteEstimate> estimate({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) {
    calls++;
    return handler(origin, destination);
  }
}

final class _FakeAtomicRideOfferRepository
    implements AtomicRideOfferRepository {
  _FakeAtomicRideOfferRepository({this.conflictDriverOnce});

  final String? conflictDriverOnce;
  final List<String> attemptedDriverIds = [];
  final List<RideOffer> createdOffers = [];
  bool _didConflict = false;

  @override
  Future<RideOffer> createPendingOffer({required RideOffer offer}) async {
    attemptedDriverIds.add(offer.driverId);
    if (!_didConflict && offer.driverId == conflictDriverOnce) {
      _didConflict = true;
      throw const AtomicRideOfferConflictException(
        AtomicRideOfferConflict.driverLocationStale,
      );
    }
    createdOffers.add(offer);
    return offer;
  }

  @override
  Future<RideOffer> acceptPendingOffer({
    required String offerId,
    required DateTime now,
  }) => throw UnsupportedError('Not used in this test.');

  @override
  Future<RideOffer> rejectPendingOffer({
    required String offerId,
    required DateTime now,
  }) => throw UnsupportedError('Not used in this test.');

  @override
  Future<RideOffer> expirePendingOffer({
    required String offerId,
    required DateTime now,
  }) => throw UnsupportedError('Not used in this test.');

  @override
  Future<void> movePendingRideToWaitingForVehicle({required String rideId}) =>
      throw UnsupportedError('Not used in this test.');
}

final class _FakeRideOfferRepository implements RideOfferRepository {
  @override
  Future<List<RideOffer>> findByRideId(String rideId) async => const [];

  @override
  Future<RideOffer?> findById(String id) async => null;

  @override
  Future<List<RideOffer>> findPendingExpiredAt(DateTime now) async => const [];

  @override
  Future<void> create(RideOffer offer) =>
      throw UnsupportedError('Not used in this test.');

  @override
  Future<bool> resolve(RideOffer offer) =>
      throw UnsupportedError('Not used in this test.');

  @override
  Future<bool> markDisplayed({
    required String offerId,
    required String driverId,
    required DateTime displayedAt,
  }) => throw UnsupportedError('Not used in this test.');
}

final class _UnusedDriverShiftRepository implements DriverShiftRepository {
  @override
  Future<List<ActiveDriverShift>> findAllActive() async => const [];

  @override
  Future<ActiveDriverShift?> findActiveByDriverId(String driverId) async =>
      null;

  @override
  Future<ActiveDriverShift> startShift({
    required String shiftId,
    required String driverId,
    required String vehicleId,
    required DateTime startedAt,
  }) => throw UnsupportedError('Not used in this test.');

  @override
  Future<ActiveDriverShift> saveQueueState({
    required String shiftId,
    required DriverQueueState queueState,
  }) => throw UnsupportedError('Not used in this test.');

  @override
  Future<void> endShift({required String shiftId, required DateTime endedAt}) =>
      throw UnsupportedError('Not used in this test.');
}

final class _UnusedDriverLocationRepository
    implements DriverLiveLocationRepository {
  @override
  Future<DriverLiveLocation?> findByDriverId(String driverId) async => null;

  @override
  Future<DriverLiveLocation> save({
    required String driverId,
    required double latitude,
    required double longitude,
    required DateTime updatedAt,
  }) => throw UnsupportedError('Not used in this test.');
}
