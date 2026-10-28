import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/driver_break_repository.dart';
import 'package:gocity6_backend/dispatch/driver_break_service.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:test/test.dart';

void main() {
  final originalPriority = DateTime.utc(2026, 10, 28, 8);
  final now = DateTime.utc(2026, 10, 28, 10);
  const requestId = 'c6cbb0dd-67b8-4e0a-9066-62f8c4cba3be';

  group('DriverBreakService', () {
    test(
      'short break preserves FIFO and consumes one shift allowance',
      () async {
        final store = _BreakStore(
          queueState: _queueState(priority: originalPriority),
          now: now,
        );

        final result = await _service(store)
            .startShortBreak(driverId: 'driver-001');
        final shift = result.shift;

        expect(
          shift.queueState.availability,
          DriverQueueAvailability.shortBreak,
        );
        expect(shift.queueState.queuePrioritySince, originalPriority);
        expect(shift.queueState.shortBreaksUsed, 1);
        expect(shift.queueState.breakStartedAt, now);
      },
    );

    test(
      'manually ended short break preserves priority and used count',
      () async {
        final store = _BreakStore(
          queueState: _queueState(priority: originalPriority),
          now: now,
        );
        await _service(store).startShortBreak(driverId: 'driver-001');
        store.now = now.add(const Duration(minutes: 3));

        final result = await _service(store).endBreak(driverId: 'driver-001');

        expect(
          result.shift.queueState.availability,
          DriverQueueAvailability.available,
        );
        expect(result.shift.queueState.queuePrioritySince, originalPriority);
        expect(result.shift.queueState.shortBreaksUsed, 1);
        expect(result.shift.queueState.breakStartedAt, isNull);
      },
    );

    test(
      'long break returns at the back without consuming short allowance',
      () async {
        final store = _BreakStore(
          queueState: _queueState(priority: originalPriority, used: 2),
          now: now,
        );
        await _service(store).startLongBreak(driverId: 'driver-001');
        store.now = now.add(const Duration(hours: 2));

        final result = await _service(store).endBreak(driverId: 'driver-001');

        expect(
          result.shift.queueState.availability,
          DriverQueueAvailability.available,
        );
        expect(result.shift.queueState.queuePrioritySince, store.now);
        expect(result.shift.queueState.shortBreaksUsed, 2);
      },
    );

    test(
      'a repeated start without an id does not consume another short break',
      () async {
        final store = _BreakStore(
          queueState: _queueState(priority: originalPriority),
          now: now,
        );
        final service = _service(store);
        await service.startShortBreak(driverId: 'driver-001');

        await expectLater(
          service.startShortBreak(driverId: 'driver-001'),
          _conflict(DriverBreakConflict.notAvailable),
        );
        expect(store.queueState!.shortBreaksUsed, 1);
      },
    );

    test(
      'deferred short break stays busy without starting its timer',
      () async {
        final store = _BreakStore(
          queueState: _busyQueue(priority: originalPriority),
          now: now,
          hasCurrentRide: true,
        );

        final result = await _service(store)
            .startShortBreak(driverId: 'driver-001', requestId: requestId);

        expect(result.requestStatus, DriverBreakRequestStatus.pending);
        expect(result.requestId, requestId);
        expect(result.requestKind, DriverBreakKind.short);
        expect(result.pendingBreakRequestId, requestId);
        expect(
          result.shift.queueState.availability,
          DriverQueueAvailability.busy,
        );
        expect(result.shift.queueState.breakStartedAt, isNull);
        expect(result.shift.queueState.queuePrioritySince, originalPriority);
        expect(result.shift.queueState.shortBreaksUsed, 0);
      },
    );

    test('short break activates atomically after course and starts full ten minutes', () async {
      final store = _BreakStore(
        queueState: _busyQueue(priority: originalPriority),
        now: now,
        hasCurrentRide: true,
      );
      final service = _service(store);
      await service.startShortBreak(
        driverId: 'driver-001',
        requestId: requestId,
      );

      store.now = now.add(const Duration(minutes: 47));
      final activated = store.completeCurrentRide();

      expect(activated.availability, DriverQueueAvailability.shortBreak);
      expect(activated.breakStartedAt, store.now);
      expect(activated.queuePrioritySince, store.now);
      expect(activated.shortBreaksUsed, 1);
      expect(
        activated.breakStartedAt!.add(DriverQueueState.shortBreakDuration),
        store.now.add(const Duration(minutes: 10)),
      );

      store.now = store.now.add(const Duration(minutes: 10));
      final afterRestart = await _service(store)
          .endBreak(driverId: 'driver-001');
      expect(
        afterRestart.shift.queueState.availability,
        DriverQueueAvailability.available,
      );
      expect(
        afterRestart.shift.queueState.queuePrioritySince,
        activated.queuePrioritySince,
      );
    });

    test(
      'deferred long break activates after course and moves to back on return',
      () async {
        final store = _BreakStore(
          queueState: _busyQueue(priority: originalPriority, used: 1),
          now: now,
          hasCurrentRide: true,
        );
        await _service(store)
            .startLongBreak(driverId: 'driver-001', requestId: requestId);
        store.now = now.add(const Duration(minutes: 35));
        final activated = store.completeCurrentRide();
        expect(activated.availability, DriverQueueAvailability.longBreak);
        expect(activated.breakStartedAt, store.now);
        expect(activated.queuePrioritySince, store.now);
        expect(activated.shortBreaksUsed, 1);

        store.now = store.now.add(const Duration(hours: 2));
        final returned = await _service(store).endBreak(driverId: 'driver-001');
        expect(
          returned.shift.queueState.availability,
          DriverQueueAvailability.available,
        );
        expect(returned.shift.queueState.queuePrioritySince, store.now);
      },
    );

    test(
      'pending request can be cancelled before activation without moving queue',
      () async {
        final store = _BreakStore(
          queueState: _busyQueue(priority: originalPriority),
          now: now,
          hasCurrentRide: true,
        );
        final service = _service(store);
        await service.startLongBreak(
          driverId: 'driver-001',
          requestId: requestId,
        );

        final result = await service.cancelPendingBreak(
          driverId: 'driver-001',
          requestId: requestId,
        );

        expect(result.requestStatus, DriverBreakRequestStatus.cancelled);
        expect(result.requestId, requestId);
        expect(
          result.shift.queueState.availability,
          DriverQueueAvailability.busy,
        );
        expect(result.shift.queueState.queuePrioritySince, originalPriority);
        expect(result.pendingBreakRequestId, isNull);
      },
    );

    test('request is idempotent across service recreation', () async {
      final store = _BreakStore(
        queueState: _busyQueue(priority: originalPriority),
        now: now,
        hasCurrentRide: true,
      );
      await _service(store)
          .startLongBreak(driverId: 'driver-001', requestId: requestId);

      final replay = await _service(store)
          .startLongBreak(driverId: 'driver-001', requestId: requestId);

      expect(replay.replayed, isTrue);
      expect(replay.requestStatus, DriverBreakRequestStatus.pending);
      expect(replay.pendingBreakRequestId, requestId);
      expect(store.requests.length, 1);
    });

    test('replay after ride completion returns active request without another break', () async {
      final store = _BreakStore(
        queueState: _busyQueue(priority: originalPriority),
        now: now,
        hasCurrentRide: true,
      );
      await _service(store)
          .startShortBreak(driverId: 'driver-001', requestId: requestId);
      final activated = store.completeCurrentRide();
      store.now = store.now.add(const Duration(minutes: 2));

      final replay = await _service(store)
          .startShortBreak(driverId: 'driver-001', requestId: requestId);

      expect(replay.replayed, isTrue);
      expect(replay.requestStatus, DriverBreakRequestStatus.active);
      expect(
        replay.shift.queueState.availability,
        DriverQueueAvailability.shortBreak,
      );
      expect(replay.shift.queueState.breakStartedAt, activated.breakStartedAt);
      expect(replay.shift.queueState.shortBreaksUsed, 1);
      expect(store.requests.length, 1);
    });

    test(
      'concurrent pending requests cannot replace the first request',
      () async {
        final store = _BreakStore(
          queueState: _busyQueue(priority: originalPriority),
          now: now,
          hasCurrentRide: true,
        );
        final service = _service(store);
        final results = await Future.wait<Object>([
          service.startShortBreak(driverId: 'driver-001', requestId: requestId),
          service
              .startLongBreak(
                driverId: 'driver-001',
                requestId: '24b756aa-e127-4b12-8d31-8d9691c2b8ce',
              )
              .then<Object>((value) => value)
              .catchError((Object error) => error),
        ]);

        expect(results.first, isA<DriverBreakOperationResult>());
        expect(
          results.last,
          isA<DriverBreakConflictException>().having(
            (error) => error.conflict,
            'conflict',
            DriverBreakConflict.pendingBreakConflict,
          ),
        );
        expect(store.pendingRequestId, requestId);
        expect(store.requests.length, 1);
      },
    );

    test('reusing a request id for another break type is rejected', () async {
      final store = _BreakStore(
        queueState: _busyQueue(priority: originalPriority),
        now: now,
        hasCurrentRide: true,
      );
      final service = _service(store);
      await service.startShortBreak(
        driverId: 'driver-001',
        requestId: requestId,
      );

      await expectLater(
        service.startLongBreak(driverId: 'driver-001', requestId: requestId),
        _conflict(DriverBreakConflict.idempotencyKeyReused),
      );
    });

    test('different request cannot replace an already pending break', () async {
      final store = _BreakStore(
        queueState: _busyQueue(priority: originalPriority),
        now: now,
        hasCurrentRide: true,
      );
      final service = _service(store);
      await service.startLongBreak(
        driverId: 'driver-001',
        requestId: requestId,
      );

      await expectLater(
        service.startShortBreak(
          driverId: 'driver-001',
          requestId: '24b756aa-e127-4b12-8d31-8d9691c2b8ce',
        ),
        _conflict(DriverBreakConflict.pendingBreakConflict),
      );
      expect(store.requests.length, 1);
    });

    test('reserved next ride prevents scheduling', () async {
      final store = _BreakStore(
        queueState: _busyQueue(priority: originalPriority),
        now: now,
        hasCurrentRide: true,
        hasReservedRide: true,
      );
      await expectLater(
        _service(store)
            .startLongBreak(driverId: 'driver-001', requestId: requestId),
        _conflict(DriverBreakConflict.reservedRide),
      );
      expect(store.requests, isEmpty);
    });

    test('start rejects pending offers and invalid busy state', () async {
      final pendingOfferStore = _BreakStore(
        queueState: _queueState(priority: originalPriority).beginOffer(),
        now: now,
      );
      await expectLater(
        _service(pendingOfferStore).startLongBreak(driverId: 'driver-001'),
        _conflict(DriverBreakConflict.activeOffer),
      );

      final busyWithoutRide = _BreakStore(
        queueState: _busyQueue(priority: originalPriority),
        now: now,
      );
      await expectLater(
        _service(busyWithoutRide)
            .startLongBreak(driverId: 'driver-001', requestId: requestId),
        _conflict(DriverBreakConflict.currentRide),
      );
    });

    test('short-break limit applies to a deferred request', () async {
      final store = _BreakStore(
        queueState: _busyQueue(priority: originalPriority, used: 3),
        now: now,
        hasCurrentRide: true,
      );
      await expectLater(
        _service(store)
            .startShortBreak(driverId: 'driver-001', requestId: requestId),
        _conflict(DriverBreakConflict.noShortBreaksRemaining),
      );
      expect(store.requests, isEmpty);
    });
  });
}

Matcher _conflict(DriverBreakConflict conflict) => throwsA(
  isA<DriverBreakConflictException>().having(
    (error) => error.conflict,
    'conflict',
    conflict,
  ),
);

DriverBreakService _service(_BreakStore store) =>
    DriverBreakService(repository: _InMemoryDriverBreakRepository(store));

DriverQueueState _queueState({required DateTime priority, int used = 0}) =>
    DriverQueueState(
      driverId: 'driver-001',
      queuePrioritySince: priority,
      shortBreaksUsed: used,
    );

DriverQueueState _busyQueue({required DateTime priority, int used = 0}) =>
    _queueState(priority: priority, used: used).beginOffer().acceptOffer();

class _BreakStore {
  DriverQueueState? queueState;
  DateTime now;
  bool hasCurrentRide;
  final bool hasReservedRide;
  final Map<String, (DriverBreakKind kind, DriverBreakRequestStatus status)>
  requests = {};
  String? pendingRequestId;
  DriverBreakKind? pendingKind;
  String? activeRequestId;

  _BreakStore({
    required this.queueState,
    required this.now,
    this.hasCurrentRide = false,
    this.hasReservedRide = false,
  });

  DriverQueueState completeCurrentRide() {
    hasCurrentRide = false;
    final kind = pendingKind;
    final requestId = pendingRequestId;
    if (kind == null || requestId == null) {
      queueState = DriverQueueState.restore(
        driverId: queueState!.driverId,
        queuePrioritySince: now,
        availability: DriverQueueAvailability.available,
        shortBreaksUsed: queueState!.shortBreaksUsed,
        breakStartedAt: null,
        hasPendingOffer: false,
      );
      return queueState!;
    }

    final old = queueState!;
    final availability = kind == DriverBreakKind.short
        ? DriverQueueAvailability.shortBreak
        : DriverQueueAvailability.longBreak;
    queueState = DriverQueueState.restore(
      driverId: old.driverId,
      queuePrioritySince: now,
      availability: availability,
      shortBreaksUsed:
          old.shortBreaksUsed + (kind == DriverBreakKind.short ? 1 : 0),
      breakStartedAt: now,
      hasPendingOffer: false,
    );
    pendingKind = null;
    pendingRequestId = null;
    activeRequestId = requestId;
    requests[requestId] = (kind, DriverBreakRequestStatus.active);
    return queueState!;
  }
}

class _InMemoryDriverBreakRepository implements DriverBreakRepository {
  final _BreakStore store;

  _InMemoryDriverBreakRepository(this.store);

  @override
  Future<DriverBreakOperationResult> startBreak({
    required String driverId,
    required DriverBreakKind kind,
    String? requestId,
  }) async {
    var state = _requireState(driverId).effectiveAt(store.now);
    if (requestId != null && store.requests.containsKey(requestId)) {
      final existing = store.requests[requestId]!;
      if (existing.$1 != kind) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.idempotencyKeyReused,
        );
      }
      return _result(
        state,
        requestId: requestId,
        requestKind: kind,
        requestStatus: existing.$2,
        pending: existing.$2 == DriverBreakRequestStatus.pending,
        replayed: true,
      );
    }
    if (store.pendingRequestId != null) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.pendingBreakConflict,
      );
    }
    if (state.hasPendingOffer) {
      throw const DriverBreakConflictException(DriverBreakConflict.activeOffer);
    }

    if (state.availability == DriverQueueAvailability.busy) {
      if (store.hasReservedRide) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.reservedRide,
        );
      }
      if (!store.hasCurrentRide) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.currentRide,
        );
      }
      if (requestId == null) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.idempotencyKeyRequired,
        );
      }
      if (kind == DriverBreakKind.short && state.shortBreaksRemaining == 0) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.noShortBreaksRemaining,
        );
      }
      store.pendingRequestId = requestId;
      store.pendingKind = kind;
      store.requests[requestId] = (kind, DriverBreakRequestStatus.pending);
      store.queueState = state;
      return _result(
        state,
        requestId: requestId,
        requestKind: kind,
        requestStatus: DriverBreakRequestStatus.pending,
        pending: true,
      );
    }

    if (store.hasCurrentRide) {
      throw const DriverBreakConflictException(DriverBreakConflict.currentRide);
    }
    if (store.hasReservedRide) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.reservedRide,
      );
    }
    if (state.availability != DriverQueueAvailability.available) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.notAvailable,
      );
    }
    try {
      state = switch (kind) {
        DriverBreakKind.short => state.startShortBreak(store.now),
        DriverBreakKind.long => state.startLongBreak(store.now),
      };
    } on DriverQueueConflictException catch (error) {
      throw DriverBreakConflictException(
        error.conflict == DriverQueueConflict.noShortBreaksRemaining
            ? DriverBreakConflict.noShortBreaksRemaining
            : DriverBreakConflict.notAvailable,
      );
    }
    store.queueState = state;
    if (requestId != null) {
      store.activeRequestId = requestId;
      store.requests[requestId] = (kind, DriverBreakRequestStatus.active);
    }
    return _result(
      state,
      requestId: requestId,
      requestKind: requestId == null ? null : kind,
      requestStatus: requestId == null ? null : DriverBreakRequestStatus.active,
    );
  }

  @override
  Future<DriverBreakOperationResult> endBreak({
    required String driverId,
  }) async {
    final current = _requireState(driverId);
    final effective = current.effectiveAt(store.now);
    store.queueState = effective;
    if (effective.availability == DriverQueueAvailability.available &&
        current.availability == DriverQueueAvailability.shortBreak) {
      final requestId = store.activeRequestId;
      if (requestId != null) {
        final request = store.requests[requestId]!;
        store.requests[requestId] = (
          request.$1,
          DriverBreakRequestStatus.completed,
        );
        store.activeRequestId = null;
      }
      return _result(
        effective,
        requestId: requestId,
        requestKind: requestId == null ? null : store.requests[requestId]!.$1,
        requestStatus: requestId == null
            ? null
            : DriverBreakRequestStatus.completed,
      );
    }
    try {
      final updated = effective.returnFromBreak(store.now);
      store.queueState = updated;
      final requestId = store.activeRequestId;
      if (requestId != null) {
        final request = store.requests[requestId]!;
        store.requests[requestId] = (
          request.$1,
          DriverBreakRequestStatus.completed,
        );
        store.activeRequestId = null;
      }
      return _result(
        updated,
        requestId: requestId,
        requestKind: requestId == null ? null : store.requests[requestId]!.$1,
        requestStatus: requestId == null
            ? null
            : DriverBreakRequestStatus.completed,
      );
    } on DriverQueueConflictException {
      throw const DriverBreakConflictException(DriverBreakConflict.notOnBreak);
    }
  }

  @override
  Future<DriverBreakOperationResult> cancelPendingBreak({
    required String driverId,
    required String requestId,
  }) async {
    final state = _requireState(driverId);
    final request = store.requests[requestId];
    if (request == null) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.pendingBreakNotFound,
      );
    }
    if (request.$2 == DriverBreakRequestStatus.cancelled) {
      return _result(
        state,
        requestId: requestId,
        requestKind: request.$1,
        requestStatus: request.$2,
        replayed: true,
      );
    }
    if (request.$2 != DriverBreakRequestStatus.pending ||
        store.pendingRequestId != requestId) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.breakAlreadyActivated,
      );
    }
    store.requests[requestId] = (
      request.$1,
      DriverBreakRequestStatus.cancelled,
    );
    store.pendingKind = null;
    store.pendingRequestId = null;
    return _result(
      state,
      requestId: requestId,
      requestKind: request.$1,
      requestStatus: DriverBreakRequestStatus.cancelled,
    );
  }

  DriverBreakOperationResult _result(
    DriverQueueState state, {
    String? requestId,
    DriverBreakKind? requestKind,
    DriverBreakRequestStatus? requestStatus,
    bool pending = false,
    bool replayed = false,
  }) => DriverBreakOperationResult(
    shift: _shift(state),
    pendingBreakKind: pending ? requestKind : null,
    pendingBreakRequestId: pending ? requestId : null,
    activeBreakRequestId: store.activeRequestId,
    requestStatus: requestStatus,
    requestId: requestId,
    requestKind: requestKind,
    replayed: replayed,
  );

  DriverQueueState _requireState(String driverId) {
    final state = store.queueState;
    if (state == null || state.driverId != driverId) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.activeShiftNotFound,
      );
    }
    return state;
  }

  ActiveDriverShift _shift(DriverQueueState state) => ActiveDriverShift.restore(
    id: 'shift-001',
    driverId: state.driverId,
    vehicleId: 'vehicle-001',
    startedAt: DateTime.utc(2026, 10, 28, 7),
    queueState: state,
  );
}
