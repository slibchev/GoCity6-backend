import 'dart:convert';

import 'package:gocity6_backend/auth/driver_token_service.dart';
import 'package:gocity6_backend/dispatch/active_driver_shift.dart';
import 'package:gocity6_backend/dispatch/driver_break_repository.dart';
import 'package:gocity6_backend/dispatch/driver_break_route.dart';
import 'package:gocity6_backend/dispatch/driver_break_service.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

void main() {
  const driverId = 'driver-001';
  const secret = 'city6-driver-break-route-test-secret';
  final now = DateTime.utc(2026, 10, 28, 10);
  final tokenService = DriverTokenService(secret: secret);
  final token = tokenService.createToken(
    driverId: driverId,
    username: 'break-test',
  );

  Future<Response> callRoute({
    required String path,
    required DriverBreakService? service,
    String? authorization,
    String body = '',
    DriverTokenService? tokenServiceOverride,
  }) async {
    final router = Router();
    registerDriverBreakRoutes(
      router,
      tokenService: tokenServiceOverride ?? tokenService,
      breakService: service,
      now: () => now,
    );
    final headers = <String, String>{};
    if (authorization != null) {
      headers['authorization'] = authorization;
    }
    return router.call(
      Request(
        'POST',
        Uri.parse('http://localhost$path'),
        headers: headers,
        body: body,
      ),
    );
  }

  test(
    'short break endpoint is authenticated and returns the break contract',
    () async {
      final repository = _FakeBreakRepository(
        _state(queuePriority: DateTime.utc(2026, 10, 28, 8)),
        now: now,
      );
      final response = await callRoute(
        path: '/driver/break/short',
        service: DriverBreakService(repository: repository),
        authorization: 'Bearer $token',
      );

      expect(response.statusCode, 200);
      expect(response.headers['cache-control'], 'no-store');
      final body = jsonDecode(await response.readAsString()) as Map;
      final queue = body['shift']['queue'] as Map;
      final breakState = queue['break'] as Map;
      expect(queue['availability'], 'shortBreak');
      expect(queue['shortBreaksUsed'], 1);
      expect(breakState['mode'], 'short');
      expect(breakState['expiresAt'], '2026-10-28T10:10:00.000Z');
      expect(breakState['remainingSeconds'], 600);
    },
  );

  test(
    'long break and end endpoints preserve the configured FIFO rules',
    () async {
      final repository = _FakeBreakRepository(
        _state(queuePriority: DateTime.utc(2026, 10, 28, 8), used: 1),
        now: now,
      );
      final service = DriverBreakService(repository: repository);

      final started = await callRoute(
        path: '/driver/break/long',
        service: service,
        authorization: 'Bearer $token',
      );
      expect(started.statusCode, 200);
      final startedBody = jsonDecode(await started.readAsString()) as Map;
      final startedQueue = startedBody['shift']['queue'] as Map;
      expect(startedQueue['availability'], 'longBreak');
      expect(startedQueue['queuePrioritySince'], '2026-10-28T08:00:00.000Z');
      expect(startedQueue['break']['mode'], 'long');
      expect(startedQueue['break']['expiresAt'], isNull);
      expect(startedQueue['shortBreaksUsed'], 1);

      final ended = await callRoute(
        path: '/driver/break/end',
        service: service,
        authorization: 'Bearer $token',
      );
      expect(ended.statusCode, 200);
      final endedBody = jsonDecode(await ended.readAsString()) as Map;
      final endedQueue = endedBody['shift']['queue'] as Map;
      expect(endedQueue['availability'], 'available');
      expect(endedQueue['queuePrioritySince'], now.toIso8601String());
      expect(endedQueue['break']['mode'], 'none');
    },
  );

  test(
    'duplicate start does not consume another break and returns conflict',
    () async {
      final repository = _FakeBreakRepository(
        _state(queuePriority: DateTime.utc(2026, 10, 28, 8)),
        now: now,
      );
      final service = DriverBreakService(repository: repository);

      final first = await callRoute(
        path: '/driver/break/short',
        service: service,
        authorization: 'Bearer $token',
      );
      final duplicate = await callRoute(
        path: '/driver/break/short',
        service: service,
        authorization: 'Bearer $token',
      );

      expect(first.statusCode, 200);
      expect(duplicate.statusCode, 409);
      final body = jsonDecode(await duplicate.readAsString());
      expect(body['code'], 'notAvailable');
      expect(repository.queueState.shortBreaksUsed, 1);
    },
  );

  test(
    'deferred break uses requestId and can be cancelled explicitly',
    () async {
      const requestId = 'c6cbb0dd-67b8-4e0a-9066-62f8c4cba3be';
      final repository = _FakeBreakRepository(
        _state(queuePriority: DateTime.utc(2026, 10, 28, 8))
            .beginOffer()
            .acceptOffer(),
        now: now,
      );
      final service = DriverBreakService(repository: repository);

      final missingId = await callRoute(
        path: '/driver/break/short',
        service: service,
        authorization: 'Bearer $token',
      );
      expect(missingId.statusCode, 400);
      expect(
        jsonDecode(await missingId.readAsString())['code'],
        'idempotencyKeyRequired',
      );

      final scheduled = await callRoute(
        path: '/driver/break/short',
        service: service,
        authorization: 'Bearer $token',
        body: jsonEncode({'requestId': requestId}),
      );
      expect(scheduled.statusCode, 200);
      final scheduledBody = jsonDecode(await scheduled.readAsString()) as Map;
      final queue = scheduledBody['shift']['queue'] as Map;
      expect(queue['availability'], 'busy');
      expect(queue['breakStartedAt'], isNull);
      expect(queue['pendingBreak']['requestId'], requestId);
      expect(scheduledBody['breakRequest']['status'], 'pending');

      final cancelled = await callRoute(
        path: '/driver/break/cancel-pending',
        service: service,
        authorization: 'Bearer $token',
        body: jsonEncode({'requestId': requestId}),
      );
      expect(cancelled.statusCode, 200);
      final cancelledBody = jsonDecode(await cancelled.readAsString()) as Map;
      expect(cancelledBody['shift']['queue']['availability'], 'busy');
      expect(cancelledBody['shift']['queue']['pendingBreak'], isNull);
      expect(cancelledBody['breakRequest']['status'], 'cancelled');
    },
  );

  test('reserved next ride returns a clear 409 conflict', () async {
    final repository = _FakeBreakRepository(
      _state(queuePriority: DateTime.utc(2026, 10, 28, 8))
          .beginOffer()
          .acceptOffer(),
      now: now,
    )..hasReservedRide = true;
    final response = await callRoute(
      path: '/driver/break/long',
      service: DriverBreakService(repository: repository),
      authorization: 'Bearer $token',
      body: jsonEncode({'requestId': 'c6cbb0dd-67b8-4e0a-9066-62f8c4cba3be'}),
    );

    expect(response.statusCode, 409);
    expect(jsonDecode(await response.readAsString())['code'], 'reservedRide');
  });

  test('missing, invalid and unavailable authentication fail closed', () async {
    final repository = _FakeBreakRepository(
      _state(queuePriority: DateTime.utc(2026, 10, 28, 8)),
      now: now,
    );
    final service = DriverBreakService(repository: repository);

    final missing = await callRoute(
      path: '/driver/break/short',
      service: service,
    );
    final invalid = await callRoute(
      path: '/driver/break/short',
      service: service,
      authorization: 'Bearer invalid',
    );
    final unavailable = await callRoute(
      path: '/driver/break/short',
      service: null,
      authorization: 'Bearer $token',
    );

    expect(missing.statusCode, 401);
    expect(invalid.statusCode, 401);
    expect(unavailable.statusCode, 503);
    expect(repository.startCount, 0);
  });
}

DriverQueueState _state({required DateTime queuePriority, int used = 0}) {
  return DriverQueueState(
    driverId: 'driver-001',
    queuePrioritySince: queuePriority,
    shortBreaksUsed: used,
  );
}

class _FakeBreakRepository implements DriverBreakRepository {
  DriverQueueState queueState;
  final DateTime now;
  int startCount = 0;
  String? pendingRequestId;
  DriverBreakKind? pendingKind;
  bool hasReservedRide = false;
  final Map<String, (DriverBreakKind, DriverBreakRequestStatus)> requests = {};

  _FakeBreakRepository(this.queueState, {required this.now});

  @override
  Future<DriverBreakOperationResult> startBreak({
    required String driverId,
    required DriverBreakKind kind,
    String? requestId,
  }) async {
    startCount++;
    if (queueState.driverId != driverId) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.activeShiftNotFound,
      );
    }
    if (queueState.hasPendingOffer) {
      throw const DriverBreakConflictException(DriverBreakConflict.activeOffer);
    }
    if (requestId != null && requests.containsKey(requestId)) {
      final existing = requests[requestId]!;
      if (existing.$1 != kind) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.idempotencyKeyReused,
        );
      }
      return _result(
        requestId: requestId,
        requestKind: kind,
        requestStatus: existing.$2,
        pending: existing.$2 == DriverBreakRequestStatus.pending,
        replayed: true,
      );
    }
    if (queueState.availability == DriverQueueAvailability.busy) {
      if (hasReservedRide) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.reservedRide,
        );
      }
      if (requestId == null) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.idempotencyKeyRequired,
        );
      }
      pendingRequestId = requestId;
      pendingKind = kind;
      requests[requestId] = (kind, DriverBreakRequestStatus.pending);
      return _result(
        requestId: requestId,
        requestKind: kind,
        requestStatus: DriverBreakRequestStatus.pending,
        pending: true,
      );
    }
    if (queueState.availability != DriverQueueAvailability.available) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.notAvailable,
      );
    }
    try {
      queueState = switch (kind) {
        DriverBreakKind.short => queueState.startShortBreak(now),
        DriverBreakKind.long => queueState.startLongBreak(now),
      };
    } on DriverQueueConflictException catch (error) {
      throw DriverBreakConflictException(
        error.conflict == DriverQueueConflict.noShortBreaksRemaining
            ? DriverBreakConflict.noShortBreaksRemaining
            : DriverBreakConflict.notAvailable,
      );
    }
    if (requestId != null) {
      requests[requestId] = (kind, DriverBreakRequestStatus.active);
    }
    return _result(
      requestId: requestId,
      requestKind: requestId == null ? null : kind,
      requestStatus: requestId == null ? null : DriverBreakRequestStatus.active,
    );
  }

  @override
  Future<DriverBreakOperationResult> endBreak({
    required String driverId,
  }) async {
    if (queueState.driverId != driverId) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.activeShiftNotFound,
      );
    }
    try {
      queueState = queueState.returnFromBreak(now);
    } on DriverQueueConflictException {
      throw const DriverBreakConflictException(DriverBreakConflict.notOnBreak);
    }
    return _result();
  }

  @override
  Future<DriverBreakOperationResult> cancelPendingBreak({
    required String driverId,
    required String requestId,
  }) async {
    if (queueState.driverId != driverId) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.activeShiftNotFound,
      );
    }
    final request = requests[requestId];
    if (request == null || pendingRequestId != requestId) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.pendingBreakNotFound,
      );
    }
    requests[requestId] = (request.$1, DriverBreakRequestStatus.cancelled);
    pendingRequestId = null;
    pendingKind = null;
    return _result(
      requestId: requestId,
      requestKind: request.$1,
      requestStatus: DriverBreakRequestStatus.cancelled,
    );
  }

  DriverBreakOperationResult _result({
    String? requestId,
    DriverBreakKind? requestKind,
    DriverBreakRequestStatus? requestStatus,
    bool pending = false,
    bool replayed = false,
  }) => DriverBreakOperationResult(
    shift: _shift(),
    pendingBreakKind: pending ? requestKind : null,
    pendingBreakRequestId: pending ? requestId : null,
    activeBreakRequestId: null,
    requestStatus: requestStatus,
    requestId: requestId,
    requestKind: requestKind,
    replayed: replayed,
  );

  ActiveDriverShift _shift() => ActiveDriverShift.restore(
    id: 'shift-001',
    driverId: queueState.driverId,
    vehicleId: 'vehicle-001',
    startedAt: DateTime.utc(2026, 10, 28, 7),
    queueState: queueState,
  );
}
