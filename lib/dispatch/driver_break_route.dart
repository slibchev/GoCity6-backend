import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/driver_token_service.dart';
import 'active_driver_shift.dart';
import 'driver_break_repository.dart';
import 'driver_break_service.dart';
import 'driver_break_state_json.dart';

typedef _BreakOperation = Future<DriverBreakOperationResult> Function(
  DriverBreakService service,
  String driverId,
  String? requestId,
);

void registerDriverBreakRoutes(
  Router router, {
  required DriverTokenService? tokenService,
  required DriverBreakService? breakService,
  DateTime Function()? now,
}) {
  Future<Response> handle(
    Request request,
    _BreakOperation operation, {
    bool requiresRequestId = false,
  }) async {
    const headers = {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
    };

    if (tokenService == null || breakService == null) {
      return Response(
        503,
        body: jsonEncode({'error': 'Driver break service is unavailable.'}),
        headers: headers,
      );
    }

    final authorization = request.headers['authorization'];
    if (authorization == null || !authorization.startsWith('Bearer ')) {
      return Response(
        401,
        body: jsonEncode({'error': 'Authentication required.'}),
        headers: headers,
      );
    }

    final tokenPayload = tokenService.verifyToken(
      authorization.substring(7).trim(),
    );
    if (tokenPayload == null) {
      return Response(
        401,
        body: jsonEncode({'error': 'Invalid or expired token.'}),
        headers: headers,
      );
    }

    String? requestId;
    final bodyText = await request.readAsString();
    if (bodyText.trim().isNotEmpty) {
      Object? decoded;
      try {
        decoded = jsonDecode(bodyText);
      } on FormatException {
        return Response(
          400,
          body: jsonEncode({
            'code': 'invalidBody',
            'error': 'Invalid JSON body.',
          }),
          headers: headers,
        );
      }
      if (decoded is! Map<String, dynamic>) {
        return Response(
          400,
          body: jsonEncode({
            'code': 'invalidBody',
            'error': 'Body must be a JSON object.',
          }),
          headers: headers,
        );
      }
      final value = decoded['requestId'];
      if (value != null && value is! String) {
        return Response(
          400,
          body: jsonEncode({
            'code': 'invalidRequestId',
            'error': 'requestId must be a UUID string.',
          }),
          headers: headers,
        );
      }
      requestId = value as String?;
      if (requestId != null && !_isUuid(requestId)) {
        return Response(
          400,
          body: jsonEncode({
            'code': 'invalidRequestId',
            'error': 'requestId must be a UUID string.',
          }),
          headers: headers,
        );
      }
    }

    if (requiresRequestId && requestId == null) {
      return Response(
        400,
        body: jsonEncode({
          'code': 'idempotencyKeyRequired',
          'error': 'A UUID requestId is required for this operation.',
        }),
        headers: headers,
      );
    }

    try {
      final result = await operation(
        breakService,
        tokenPayload.driverId,
        requestId,
      );
      return Response.ok(
        jsonEncode({
          'shift': _driverShiftJson(
            result.shift,
            now: (now ?? DateTime.now)(),
            pendingBreakKind: result.pendingBreakKind,
            pendingBreakRequestId: result.pendingBreakRequestId,
            pendingBreakRequestedAt: result.pendingBreakRequestedAt,
          ),
          'breakRequest': result.requestStatus == null
              ? null
              : {
                  'requestId': result.requestId,
                  'kind': result.requestKind?.name,
                  'status': result.requestStatus!.name,
                  'replayed': result.replayed,
                },
        }),
        headers: headers,
      );
    } on DriverBreakConflictException catch (error) {
      final statusCode =
          error.conflict == DriverBreakConflict.idempotencyKeyRequired
          ? 400
          : 409;
      return Response(
        statusCode,
        body: jsonEncode({
          'code': error.conflict.name,
          'error': 'Driver break operation conflicts with current state.',
        }),
        headers: headers,
      );
    } catch (_) {
      return Response(
        500,
        body: jsonEncode({'error': 'Driver break operation failed.'}),
        headers: headers,
      );
    }
  }

  router.post('/driver/break/short', (Request request) {
    return handle(
      request,
      (service, driverId, requestId) =>
          service.startShortBreak(driverId: driverId, requestId: requestId),
    );
  });

  router.post('/driver/break/long', (Request request) {
    return handle(
      request,
      (service, driverId, requestId) =>
          service.startLongBreak(driverId: driverId, requestId: requestId),
    );
  });

  router.post('/driver/break/end', (Request request) {
    return handle(
      request,
      (service, driverId, _) => service.endBreak(driverId: driverId),
    );
  });

  router.post('/driver/break/cancel-pending', (Request request) {
    return handle(
      request,
      (service, driverId, requestId) =>
          service.cancelPendingBreak(driverId: driverId, requestId: requestId!),
      requiresRequestId: true,
    );
  });
}

bool _isUuid(String value) => RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
).hasMatch(value);

Map<String, Object?> _driverShiftJson(
  ActiveDriverShift shift, {
  required DateTime now,
  required DriverBreakKind? pendingBreakKind,
  required String? pendingBreakRequestId,
  required DateTime? pendingBreakRequestedAt,
}) {
  return {
    'id': shift.id,
    'driverId': shift.driverId,
    'vehicleId': shift.vehicleId,
    'startedAt': shift.startedAt.toUtc().toIso8601String(),
    'queue': {
      'availability': shift.queueState.availability.name,
      'queuePrioritySince': shift.queueState.queuePrioritySince
          .toUtc()
          .toIso8601String(),
      'shortBreaksUsed': shift.queueState.shortBreaksUsed,
      'breakStartedAt': shift.queueState.breakStartedAt
          ?.toUtc()
          .toIso8601String(),
      'hasPendingOffer': shift.queueState.hasPendingOffer,
      'break': driverBreakStateJson(shift.queueState, now: now),
      'pendingBreak': pendingDriverBreakStateJson(
        kind: pendingBreakKind?.name,
        requestId: pendingBreakRequestId,
        requestedAt: pendingBreakRequestedAt,
      ),
    },
  };
}
