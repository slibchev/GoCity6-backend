import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/driver_district_queue.dart';
import 'package:gocity6_backend/dispatch/driver_district_queue_repository.dart';
import 'package:gocity6_backend/dispatch/driver_district_queue_service.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_state.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_state_repository.dart';
import 'package:gocity6_backend/dispatch/driver_live_location.dart';
import 'package:gocity6_backend/dispatch/driver_live_location_repository.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';
import 'package:gocity6_backend/geography/district_matcher.dart';
import 'package:test/test.dart';

void main() {
  group('DriverDistrictQueueMembership', () {
    const policy = DriverDistrictTransitionPolicy();
    final start = DateTime.utc(2026, 10, 28, 10);

    test('initial membership needs 3 distinct fixes in the dwell window', () {
      var membership = const DriverDistrictQueueMembership();
      final first = membership.observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start,
        confirmedAt: start.add(const Duration(seconds: 2)),
        policy: policy,
      );
      expect(
        first.result,
        DriverDistrictObservationResult.awaitingConfirmation,
      );
      expect(first.membership.districtObjectId, isNull);

      final second = first.membership.observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start.add(const Duration(seconds: 5)),
        confirmedAt: start.add(const Duration(seconds: 7)),
        policy: policy,
      );
      expect(
        second.result,
        DriverDistrictObservationResult.awaitingConfirmation,
      );
      expect(second.membership.districtObjectId, isNull);

      final confirmedAt = start.add(const Duration(seconds: 12));
      final third = second.membership.observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start.add(const Duration(seconds: 10)),
        confirmedAt: confirmedAt,
        policy: policy,
      );
      expect(third.result, DriverDistrictObservationResult.confirmedTransition);
      expect(third.membership.districtObjectId, 316);
      // FIFO entry uses Backend confirmation/receipt time, not phone fix time.
      expect(third.membership.enteredAt, confirmedAt);
      expect(
        third.membership.lastObservedAt,
        start.add(const Duration(seconds: 10)),
      );
    });

    test('same GPS fix timestamp cannot be counted twice', () {
      final first = const DriverDistrictQueueMembership().observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start,
        confirmedAt: start.add(const Duration(seconds: 1)),
        policy: policy,
      );
      final duplicate = first.membership.observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start,
        confirmedAt: start.add(const Duration(seconds: 3)),
        policy: policy,
      );
      expect(
        duplicate.result,
        DriverDistrictObservationResult.staleObservation,
      );
      expect(duplicate.membership, same(first.membership));
      expect(duplicate.membership.pendingObservations, 1);
    });

    test('two fixes are insufficient even when separated by ten seconds', () {
      final first = const DriverDistrictQueueMembership().observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start,
        confirmedAt: start,
        policy: policy,
      );
      final second = first.membership.observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start.add(const Duration(seconds: 10)),
        confirmedAt: start.add(const Duration(seconds: 10)),
        policy: policy,
      );

      expect(
        second.result,
        DriverDistrictObservationResult.awaitingConfirmation,
      );
      expect(second.membership.districtObjectId, isNull);
      expect(second.membership.pendingObservations, 2);
    });

    test('out-of-order GPS cannot advance a transition', () {
      final first = const DriverDistrictQueueMembership().observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start,
        confirmedAt: start,
        policy: policy,
      );
      final second = first.membership.observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start.add(const Duration(seconds: 5)),
        confirmedAt: start.add(const Duration(seconds: 5)),
        policy: policy,
      );
      final delayed = second.membership.observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start.add(const Duration(seconds: 4)),
        confirmedAt: start.add(const Duration(seconds: 6)),
        policy: policy,
      );
      expect(delayed.result, DriverDistrictObservationResult.staleObservation);
      expect(delayed.membership.pendingObservations, 2);
      expect(
        delayed.membership.lastObservedAt,
        start.add(const Duration(seconds: 5)),
      );
    });

    test('pending transition restarts if total span exceeds 30 seconds', () {
      final first = const DriverDistrictQueueMembership().observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start,
        confirmedAt: start,
        policy: policy,
      );
      final second = first.membership.observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start.add(const Duration(seconds: 15)),
        confirmedAt: start.add(const Duration(seconds: 15)),
        policy: policy,
      );
      final tooLate = second.membership.observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start.add(const Duration(seconds: 31)),
        confirmedAt: start.add(const Duration(seconds: 31)),
        policy: policy,
      );
      expect(
        tooLate.result,
        DriverDistrictObservationResult.awaitingConfirmation,
      );
      expect(
        tooLate.membership.pendingSince,
        start.add(const Duration(seconds: 31)),
      );
      expect(tooLate.membership.pendingObservations, 1);
    });

    test('long observation gap restarts confirmation', () {
      final pending = const DriverDistrictQueueMembership().observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start,
        confirmedAt: start,
        policy: policy,
      );
      final afterGap = pending.membership.observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start.add(const Duration(seconds: 31)),
        confirmedAt: start.add(const Duration(seconds: 31)),
        policy: policy,
      );
      expect(
        afterGap.membership.pendingSince,
        start.add(const Duration(seconds: 31)),
      );
      expect(afterGap.membership.pendingObservations, 1);
    });

    test(
      'boundary jitter restarts candidate without moving confirmed queue',
      () {
        final first = const DriverDistrictQueueMembership().observe(
          observedDistrictObjectId: 317,
          gpsFixAt: start,
          confirmedAt: start,
          policy: policy,
        );
        final back = first.membership.observe(
          observedDistrictObjectId: 318,
          gpsFixAt: start.add(const Duration(seconds: 2)),
          confirmedAt: start.add(const Duration(seconds: 2)),
          policy: policy,
        );
        expect(back.membership.pendingDistrictObjectId, 318);
        expect(back.membership.pendingObservations, 1);
        final forward = back.membership.observe(
          observedDistrictObjectId: 317,
          gpsFixAt: start.add(const Duration(seconds: 4)),
          confirmedAt: start.add(const Duration(seconds: 4)),
          policy: policy,
        );
        expect(forward.membership.pendingDistrictObjectId, 317);
        expect(forward.membership.pendingObservations, 1);
        expect(forward.membership.districtObjectId, isNull);
      },
    );

    test('same district preserves backend entry time and clears pending', () {
      final entryAt = start.subtract(const Duration(minutes: 4));
      final membership = DriverDistrictQueueMembership.restore(
        districtObjectId: 316,
        enteredAt: entryAt,
        lastObservedAt: start,
        pendingDistrictObjectId: 317,
        pendingSince: start.subtract(const Duration(seconds: 5)),
        pendingLastSeenAt: start,
        pendingObservations: 2,
      );
      final result = membership.observe(
        observedDistrictObjectId: 316,
        gpsFixAt: start.add(const Duration(seconds: 1)),
        confirmedAt: start.add(const Duration(seconds: 3)),
        policy: policy,
      );
      expect(result.result, DriverDistrictObservationResult.alreadyInDistrict);
      expect(result.membership.enteredAt, entryAt);
      expect(result.membership.pendingDistrictObjectId, isNull);
    });

    test('outside map coverage retains confirmed membership', () {
      final membership = DriverDistrictQueueMembership.restore(
        districtObjectId: 316,
        enteredAt: start,
        lastObservedAt: start.add(const Duration(seconds: 2)),
        pendingDistrictObjectId: 317,
        pendingSince: start.add(const Duration(seconds: 1)),
        pendingLastSeenAt: start.add(const Duration(seconds: 2)),
        pendingObservations: 2,
      );
      final outside = membership.observe(
        observedDistrictObjectId: null,
        gpsFixAt: start.add(const Duration(seconds: 3)),
        confirmedAt: start.add(const Duration(seconds: 3)),
        policy: policy,
      );
      expect(
        outside.result,
        DriverDistrictObservationResult.outsideDistrictCoverage,
      );
      expect(outside.membership.districtObjectId, 316);
      expect(outside.membership.enteredAt, start);
      expect(outside.membership.pendingDistrictObjectId, isNull);
    });

    test('transition entry time is backend time, not fix time', () {
      final entered = start;
      final membership = DriverDistrictQueueMembership.restore(
        districtObjectId: 316,
        enteredAt: entered,
        lastObservedAt: start.add(const Duration(seconds: 6)),
        pendingDistrictObjectId: 317,
        pendingSince: start.add(const Duration(seconds: 1)),
        pendingLastSeenAt: start.add(const Duration(seconds: 6)),
        pendingObservations: 2,
      );
      final backendConfirmedAt = start.add(const Duration(seconds: 12));
      final result = membership.observe(
        observedDistrictObjectId: 317,
        gpsFixAt: start.add(const Duration(seconds: 11)),
        confirmedAt: backendConfirmedAt,
        policy: policy,
      );
      expect(
        result.result,
        DriverDistrictObservationResult.confirmedTransition,
      );
      expect(result.membership.districtObjectId, 317);
      expect(result.membership.enteredAt, backendConfirmedAt);
      expect(result.membership.pendingDistrictObjectId, isNull);
    });
  });

  group('Driver GPS timestamp contract', () {
    test('accepts ISO-8601 UTC Z with millisecond precision', () {
      expect(
        parseDriverGpsFixTimestamp('2026-10-28T12:34:56.789Z'),
        DateTime.utc(2026, 10, 28, 12, 34, 56, 789),
      );
    });

    test('accepts Dart UTC ISO string with microseconds', () {
      expect(
        parseDriverGpsFixTimestamp('2026-10-28T12:34:56.789123Z'),
        DateTime.utc(2026, 10, 28, 12, 34, 56, 789, 123),
      );
    });

    test('rejects missing, malformed and non-UTC timestamps', () {
      expect(parseDriverGpsFixTimestamp(null), isNull);
      expect(parseDriverGpsFixTimestamp(123), isNull);
      expect(parseDriverGpsFixTimestamp('not-a-date'), isNull);
      expect(parseDriverGpsFixTimestamp('2026-10-28T12:34:56'), isNull);
      expect(parseDriverGpsFixTimestamp('2026-10-28T12:34:56+03:00'), isNull);
      expect(parseDriverGpsFixTimestamp('2026-02-30T12:34:56Z'), isNull);
    });
  });

  group('DriverDistrictQueueService', () {
    final matcher = DistrictMatcher.fromGeoJsonString(_twoDistrictGeoJson);
    final now = DateTime.utc(2026, 10, 28, 12);

    test(
      'sorts by max(district entry, legacy queue priority), then driver ID',
      () async {
        final entryAt = now.subtract(const Duration(hours: 1));
        final entries = <DriverDistrictQueueEntry>[
          _entry(
            's-short-break',
            'driver-short-break',
            entryAt,
            entryAt.subtract(const Duration(minutes: 5)),
          ),
          _entry(
            's-initial',
            'driver-initial',
            now.subtract(const Duration(minutes: 55)),
            now.subtract(const Duration(minutes: 55)),
          ),
          _entry(
            's-long-break',
            'driver-long-break',
            entryAt,
            now.subtract(const Duration(minutes: 50)),
          ),
          _entry(
            's-external',
            'driver-external-return',
            entryAt,
            now.subtract(const Duration(minutes: 40)),
          ),
          _entry(
            's-course-a',
            'driver-course-a',
            entryAt,
            now.subtract(const Duration(minutes: 30)),
          ),
          _entry(
            's-course-b',
            'driver-course-b',
            entryAt,
            now.subtract(const Duration(minutes: 30)),
          ),
          _entry(
            's-reject',
            'driver-normal-reject',
            entryAt,
            now.subtract(const Duration(minutes: 20)),
          ),
          _entry(
            's-timeout',
            'driver-expired-offer',
            entryAt,
            now.subtract(const Duration(minutes: 10)),
          ),
          _entry(
            's-bonus',
            'driver-bonus-reject',
            entryAt,
            now.subtract(const Duration(minutes: 5)),
          ),
        ];
        final repository = _FakeDistrictQueueRepository()
          ..entries[316] = entries;
        final shifts = [
          for (final entry in entries)
            _activeShift(entry.shiftId, entry.driverId, enteredAt: now),
        ];
        final locations = _FakeLiveLocationRepository({
          for (final entry in entries)
            entry.driverId: _location(entry.driverId, now),
        });
        final service = _service(
          matcher: matcher,
          repository: repository,
          shifts: shifts,
          locations: locations,
        );

        final candidates = await service.findAvailableDrivers(
          districtObjectId: 316,
          now: now,
        );
        expect(candidates.map((candidate) => candidate.driverId), [
          'driver-short-break',
          'driver-initial',
          'driver-long-break',
          'driver-external-return',
          'driver-course-a',
          'driver-course-b',
          'driver-normal-reject',
          'driver-expired-offer',
          'driver-bonus-reject',
        ]);
        expect(candidates[0].fifoPriorityAt, entryAt);
        expect(
          candidates[2].fifoPriorityAt,
          now.subtract(const Duration(minutes: 50)),
        );
      },
    );

    test('excludes candidates without a fresh timestamped GPS fix', () async {
      final entryAt = now.subtract(const Duration(minutes: 2));
      final repository = _FakeDistrictQueueRepository()
        ..entries[316] = [
          _entry('s-ok', 'driver-ok', entryAt, entryAt),
          _entry('s-old-fix', 'driver-old-fix', entryAt, entryAt),
          _entry('s-missing-fix', 'driver-missing-fix', entryAt, entryAt),
          DriverDistrictQueueEntry(
            shiftId: 's-out-of-order',
            driverId: 'driver-out-of-order',
            districtObjectId: 316,
            enteredAt: entryAt,
            queuePrioritySince: entryAt,
            lastObservedAt: now.subtract(const Duration(seconds: 1)),
          ),
        ];
      final shifts = [
        _activeShift('s-ok', 'driver-ok', enteredAt: now),
        _activeShift('s-old-fix', 'driver-old-fix', enteredAt: now),
        _activeShift('s-missing-fix', 'driver-missing-fix', enteredAt: now),
        _activeShift('s-out-of-order', 'driver-out-of-order', enteredAt: now),
      ];
      final locations = _FakeLiveLocationRepository({
        'driver-ok': _location('driver-ok', now),
        'driver-old-fix': _location(
          'driver-old-fix',
          now,
          gpsFixAt: now.subtract(const Duration(seconds: 16)),
        ),
        'driver-missing-fix': _location(
          'driver-missing-fix',
          now,
          useReceiveTimeAsGpsFix: false,
        ),
        'driver-out-of-order': _location(
          'driver-out-of-order',
          now,
          gpsFixAt: now.subtract(const Duration(seconds: 2)),
        ),
      });

      final candidates = await _service(
        matcher: matcher,
        repository: repository,
        shifts: shifts,
        locations: locations,
      ).findAvailableDrivers(districtObjectId: 316, now: now);
      expect(candidates.map((candidate) => candidate.driverId), ['driver-ok']);
    });

    test(
      'missing, stale and implausibly future GPS time cannot confirm entry',
      () async {
        final repository = _FakeDistrictQueueRepository();
        final service = _service(
          matcher: matcher,
          repository: repository,
          shifts: const [],
          locations: const _FakeLiveLocationRepository({}),
        );

        for (final gpsFixAt in <DateTime?>[
          null,
          now.subtract(const Duration(seconds: 16)),
          now.add(const Duration(seconds: 6)),
        ]) {
          final result = await service.observeLocation(
            location: _location(
              'driver-x',
              now,
              gpsFixAt: gpsFixAt,
              useReceiveTimeAsGpsFix: gpsFixAt != null,
            ),
            match: matcher.match(latitude: 10.5, longitude: 10.5),
          );
          expect(
            result,
            DriverDistrictObservationResult.invalidGpsFixTimestamp,
          );
          expect(repository.memberships['driver-x'], isNull);
        }
      },
    );

    test(
      'fresh distinct fixes confirm and repeated request does not count again',
      () async {
        final repository = _FakeDistrictQueueRepository();
        final service = _service(
          matcher: matcher,
          repository: repository,
          shifts: const [],
          locations: const _FakeLiveLocationRepository({}),
        );

        Future<DriverDistrictObservationResult> postFix(
          DateTime fixAt,
          DateTime receivedAt,
        ) => service.observeLocation(
          location: _location('driver-x', receivedAt, gpsFixAt: fixAt),
          match: matcher.match(latitude: 10.5, longitude: 10.5),
        );

        expect(
          await postFix(now.subtract(const Duration(seconds: 10)), now),
          DriverDistrictObservationResult.awaitingConfirmation,
        );
        expect(
          await postFix(
            now.subtract(const Duration(seconds: 10)),
            now.add(const Duration(seconds: 1)),
          ),
          DriverDistrictObservationResult.staleObservation,
        );
        expect(
          await postFix(
            now.subtract(const Duration(seconds: 5)),
            now.add(const Duration(seconds: 5)),
          ),
          DriverDistrictObservationResult.awaitingConfirmation,
        );
        expect(
          await postFix(now, now.add(const Duration(seconds: 10))),
          DriverDistrictObservationResult.confirmedTransition,
        );
        expect(
          repository.memberships['driver-x']!.enteredAt,
          now.add(const Duration(seconds: 10)),
        );
      },
    );

    test('does not select unknown districts', () async {
      final service = _service(
        matcher: matcher,
        repository: _FakeDistrictQueueRepository(),
        shifts: const [],
        locations: const _FakeLiveLocationRepository({}),
      );
      await expectLater(
        service.findAvailableDrivers(districtObjectId: 999, now: now),
        throwsArgumentError,
      );
    });
  });
}

DriverDistrictQueueEntry _entry(
  String shiftId,
  String driverId,
  DateTime enteredAt,
  DateTime queuePrioritySince,
) => DriverDistrictQueueEntry(
  shiftId: shiftId,
  driverId: driverId,
  districtObjectId: 316,
  enteredAt: enteredAt,
  queuePrioritySince: queuePrioritySince,
  lastObservedAt: enteredAt,
);

ActiveDriverShift _activeShift(
  String shiftId,
  String driverId, {
  required DateTime enteredAt,
  DriverQueueAvailability availability = DriverQueueAvailability.available,
  bool hasPendingOffer = false,
}) => ActiveDriverShift.restore(
  id: shiftId,
  driverId: driverId,
  vehicleId: 'vehicle-$driverId',
  startedAt: enteredAt.subtract(const Duration(hours: 1)),
  queueState: DriverQueueState(
    driverId: driverId,
    queuePrioritySince: enteredAt,
    availability: availability,
    hasPendingOffer: hasPendingOffer,
  ),
);

DriverLiveLocation _location(
  String driverId,
  DateTime updatedAt, {
  DateTime? gpsFixAt,
  bool useReceiveTimeAsGpsFix = true,
  double latitude = 10.5,
  double longitude = 10.5,
}) => DriverLiveLocation(
  driverId: driverId,
  latitude: latitude,
  longitude: longitude,
  updatedAt: updatedAt,
  gpsFixAt: useReceiveTimeAsGpsFix ? (gpsFixAt ?? updatedAt) : null,
);

DriverDistrictQueueService _service({
  required DistrictMatcher matcher,
  required _FakeDistrictQueueRepository repository,
  required List<ActiveDriverShift> shifts,
  required _FakeLiveLocationRepository locations,
}) => DriverDistrictQueueService(
  districtMatcher: matcher,
  repository: repository,
  shiftRepository: _FakeShiftRepository(shifts),
  liveLocationRepository: locations,
  dispatchStateRepository: const _FakeDispatchStateRepository({}),
);

const String _twoDistrictGeoJson = '''
{"type":"FeatureCollection","features":[
 {"type":"Feature","properties":{"object_id":316,"id":"district-316","kvname":"ЦЕНТЪР - НДК"},"geometry":{"type":"Polygon","coordinates":[[[10,10],[11,10],[11,11],[10,11],[10,10]]] }},
 {"type":"Feature","properties":{"object_id":317,"id":"district-317","kvname":"СЪСЕДЕН РАЙОН"},"geometry":{"type":"Polygon","coordinates":[[[11,10],[12,10],[12,11],[11,11],[11,10]]] }}
]}
''';

final class _FakeDistrictQueueRepository
    implements DriverDistrictQueueRepository {
  final Map<int, List<DriverDistrictQueueEntry>> entries = {};
  final Map<String, DriverDistrictQueueMembership> memberships = {};

  @override
  Future<DriverDistrictObservationResult> observeLocation({
    required String driverId,
    required DateTime receivedAt,
    required DateTime? gpsFixAt,
    required bool gpsFixIsPlausible,
    required int? districtObjectId,
    required DriverDistrictTransitionPolicy policy,
  }) async {
    if (!gpsFixIsPlausible || gpsFixAt == null) {
      return DriverDistrictObservationResult.invalidGpsFixTimestamp;
    }
    final current =
        memberships[driverId] ?? const DriverDistrictQueueMembership();
    final transition = current.observe(
      observedDistrictObjectId: districtObjectId,
      gpsFixAt: gpsFixAt,
      confirmedAt: receivedAt,
      policy: policy,
    );
    memberships[driverId] = transition.membership;
    return transition.result;
  }

  @override
  Future<List<DriverDistrictQueueEntry>> findByDistrictObjectId(
    int districtObjectId,
  ) async => entries[districtObjectId] ?? const [];
}

final class _FakeShiftRepository implements DriverShiftRepository {
  const _FakeShiftRepository(this.shifts);

  final List<ActiveDriverShift> shifts;

  @override
  Future<ActiveDriverShift?> findActiveByDriverId(String driverId) async {
    for (final shift in shifts) {
      if (shift.driverId == driverId) return shift;
    }
    return null;
  }

  @override
  Future<List<ActiveDriverShift>> findAllActive() async => shifts;

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

final class _FakeLiveLocationRepository
    implements DriverLiveLocationRepository {
  const _FakeLiveLocationRepository(this.locations);

  final Map<String, DriverLiveLocation> locations;

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

final class _FakeDispatchStateRepository
    implements DriverDispatchStateRepository {
  const _FakeDispatchStateRepository(this.states);

  final Map<String, DriverDispatchState> states;

  @override
  Future<DriverDispatchState?> findByDriverId(String driverId) async =>
      states[driverId];

  @override
  Future<DriverDispatchState> save(DriverDispatchState state) =>
      throw UnimplementedError();

  @override
  Future<DriverDispatchState> updateAtomically({
    required String driverId,
    required DriverDispatchState Function(DriverDispatchState) transform,
  }) => throw UnimplementedError();
}
