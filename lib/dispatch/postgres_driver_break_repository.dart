import 'package:postgres/postgres.dart';

import 'active_driver_shift.dart';
import 'driver_break_repository.dart';
import 'driver_queue_state.dart';

class PostgresDriverBreakRepository implements DriverBreakRepository {
  final SessionExecutor database;

  PostgresDriverBreakRepository({required this.database});

  @override
  Future<DriverBreakOperationResult> startBreak({
    required String driverId,
    required DriverBreakKind kind,
    String? requestId,
  }) {
    return database.runTx((transaction) async {
      final locked = await _lockActiveShift(transaction, driverId);
      if (locked == null) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.activeShiftNotFound,
        );
      }

      final now = await _databaseNow(transaction);
      final shiftId = locked['shift_id'] as String;
      final queueState = await _materializedQueueState(
        transaction,
        locked,
        now: now,
      );

      if (requestId != null) {
        await transaction.execute(
          Sql.named('SELECT pg_advisory_xact_lock(hashtextextended(@key, 0))'),
          parameters: {'key': requestId},
        );
        final replay = await _findRequest(transaction, requestId);
        if (replay != null) {
          return _replayStart(
            locked: locked,
            queueState: queueState,
            replay: replay,
            shiftId: shiftId,
            driverId: driverId,
            kind: kind,
          );
        }
      }

      if (locked['pending_break_request_id'] != null ||
          locked['pending_break_kind'] != null) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.pendingBreakConflict,
        );
      }

      await _ensureNoPendingOffer(transaction, driverId, queueState);

      if (queueState.availability == DriverQueueAvailability.available) {
        await _ensureNoCurrentRide(transaction, driverId);
        await _ensureNoReservedRide(transaction, driverId);

        final updatedQueueState = _startQueueBreak(queueState, kind, now);
        if (requestId != null) {
          await _insertRequest(
            transaction,
            requestId: requestId,
            shiftId: shiftId,
            kind: kind,
            status: DriverBreakRequestStatus.active,
            requestedAt: now,
            activatedAt: now,
          );
        }
        await _persistQueueState(
          transaction,
          shiftId: shiftId,
          queueState: updatedQueueState,
          pendingBreakKind: null,
          pendingBreakRequestId: null,
          activeBreakRequestId: requestId,
        );
        return DriverBreakOperationResult(
          shift: _activeShiftFromRow(locked, updatedQueueState),
          pendingBreakKind: null,
          pendingBreakRequestId: null,
          activeBreakRequestId: requestId,
          requestStatus: requestId == null
              ? null
              : DriverBreakRequestStatus.active,
          requestId: requestId,
          requestKind: requestId == null ? null : kind,
        );
      }

      if (queueState.availability == DriverQueueAvailability.busy) {
        await _ensureNoReservedRide(transaction, driverId);
        await _ensureHasCurrentRide(
          transaction,
          driverId,
          locked['vehicle_id'] as String,
        );
        if (requestId == null) {
          throw const DriverBreakConflictException(
            DriverBreakConflict.idempotencyKeyRequired,
          );
        }
        if (kind == DriverBreakKind.short &&
            queueState.shortBreaksRemaining == 0) {
          throw const DriverBreakConflictException(
            DriverBreakConflict.noShortBreaksRemaining,
          );
        }
        final pendingQueueState = queueState;
        await _insertRequest(
          transaction,
          requestId: requestId,
          shiftId: shiftId,
          kind: kind,
          status: DriverBreakRequestStatus.pending,
          requestedAt: now,
        );
        await _persistQueueState(
          transaction,
          shiftId: shiftId,
          queueState: pendingQueueState,
          pendingBreakKind: kind,
          pendingBreakRequestId: requestId,
          activeBreakRequestId: null,
        );
        return DriverBreakOperationResult(
          shift: _activeShiftFromRow(locked, pendingQueueState),
          pendingBreakKind: kind,
          pendingBreakRequestId: requestId,
          pendingBreakRequestedAt: now,
          activeBreakRequestId: null,
          requestStatus: DriverBreakRequestStatus.pending,
          requestId: requestId,
          requestKind: kind,
        );
      }

      if (queueState.availability == DriverQueueAvailability.externalRide) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.notAvailable,
        );
      }
      throw const DriverBreakConflictException(
        DriverBreakConflict.notAvailable,
      );
    });
  }

  @override
  Future<DriverBreakOperationResult> endBreak({required String driverId}) {
    return database.runTx((transaction) async {
      final locked = await _lockActiveShift(transaction, driverId);
      if (locked == null) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.activeShiftNotFound,
        );
      }

      final now = await _databaseNow(transaction);
      final shiftId = locked['shift_id'] as String;
      final originalAvailability = locked['availability'] as String;
      final originalBreakStartedAt = (locked['break_started_at'] as DateTime?)
          ?.toUtc();
      final queueState = await _materializedQueueState(
        transaction,
        locked,
        now: now,
      );
      final activeRequestId = locked['active_break_request_id'] as String?;
      final expiredShortBreak =
          originalAvailability == DriverQueueAvailability.shortBreak.name &&
          originalBreakStartedAt != null &&
          !now.isBefore(
            originalBreakStartedAt.add(DriverQueueState.shortBreakDuration),
          );

      if (expiredShortBreak) {
        return DriverBreakOperationResult(
          shift: _activeShiftFromRow(locked, queueState),
          pendingBreakKind: null,
          pendingBreakRequestId: null,
          activeBreakRequestId: null,
          requestStatus: activeRequestId == null
              ? null
              : DriverBreakRequestStatus.completed,
          requestId: activeRequestId,
          requestKind: activeRequestId == null
              ? null
              : (originalAvailability == DriverQueueAvailability.shortBreak.name
                    ? DriverBreakKind.short
                    : DriverBreakKind.long),
        );
      }

      await _ensureNoPendingOffer(transaction, driverId, queueState);
      await _ensureNoCurrentRide(transaction, driverId);
      await _ensureNoReservedRide(transaction, driverId);

      if (queueState.availability != DriverQueueAvailability.shortBreak &&
          queueState.availability != DriverQueueAvailability.longBreak) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.notOnBreak,
        );
      }

      final updatedQueueState = queueState.returnFromBreak(now);
      if (activeRequestId != null) {
        await _completeRequest(transaction, activeRequestId, now);
      }
      await _persistQueueState(
        transaction,
        shiftId: shiftId,
        queueState: updatedQueueState,
        pendingBreakKind: null,
        pendingBreakRequestId: null,
        activeBreakRequestId: null,
      );
      return DriverBreakOperationResult(
        shift: _activeShiftFromRow(locked, updatedQueueState),
        pendingBreakKind: null,
        pendingBreakRequestId: null,
        activeBreakRequestId: null,
        requestStatus: activeRequestId == null
            ? null
            : DriverBreakRequestStatus.completed,
        requestId: activeRequestId,
        requestKind: activeRequestId == null
            ? null
            : (queueState.availability == DriverQueueAvailability.shortBreak
                  ? DriverBreakKind.short
                  : DriverBreakKind.long),
      );
    });
  }

  @override
  Future<DriverBreakOperationResult> cancelPendingBreak({
    required String driverId,
    required String requestId,
  }) {
    return database.runTx((transaction) async {
      final locked = await _lockActiveShift(transaction, driverId);
      if (locked == null) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.activeShiftNotFound,
        );
      }
      await transaction.execute(
        Sql.named('SELECT pg_advisory_xact_lock(hashtextextended(@key, 0))'),
        parameters: {'key': requestId},
      );
      final now = await _databaseNow(transaction);
      final shiftId = locked['shift_id'] as String;
      final queueState = await _materializedQueueState(
        transaction,
        locked,
        now: now,
      );
      final request = await _findRequest(transaction, requestId);
      if (request == null || request['shift_id'] != shiftId) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.pendingBreakNotFound,
        );
      }
      final status = DriverBreakRequestStatus.values.byName(
        request['status'] as String,
      );
      if (status == DriverBreakRequestStatus.cancelled) {
        return DriverBreakOperationResult(
          shift: _activeShiftFromRow(locked, queueState),
          pendingBreakKind: locked['pending_break_kind'] == null
              ? null
              : DriverBreakKind.values.byName(
                  locked['pending_break_kind'] as String,
                ),
          pendingBreakRequestId: locked['pending_break_request_id'] as String?,
          pendingBreakRequestedAt: status == DriverBreakRequestStatus.pending
              ? (request['requested_at'] as DateTime).toUtc()
              : null,
          activeBreakRequestId: locked['active_break_request_id'] as String?,
          requestStatus: status,
          replayed: true,
          requestId: requestId,
          requestKind: DriverBreakKind.values.byName(
            request['break_kind'] as String,
          ),
        );
      }
      if (status != DriverBreakRequestStatus.pending ||
          locked['pending_break_request_id'] != requestId) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.breakAlreadyActivated,
        );
      }

      final cancelled = await transaction.execute(
        Sql.named('''
          UPDATE driver_break_requests
          SET status = 'cancelled', ended_at = @endedAt
          WHERE request_id = @requestId
            AND shift_id = @shiftId
            AND status = 'pending'
          RETURNING request_id
        '''),
        parameters: {
          'endedAt': now,
          'requestId': requestId,
          'shiftId': shiftId,
        },
      );
      if (cancelled.isEmpty) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.pendingBreakNotFound,
        );
      }
      await transaction.execute(
        Sql.named('''
          UPDATE driver_queue_states
          SET pending_break_kind = NULL, pending_break_request_id = NULL
          WHERE shift_id = @shiftId
            AND pending_break_request_id = @requestId
        '''),
        parameters: {'shiftId': shiftId, 'requestId': requestId},
      );
      return DriverBreakOperationResult(
        shift: _activeShiftFromRow(locked, queueState),
        pendingBreakKind: null,
        pendingBreakRequestId: null,
        pendingBreakRequestedAt: null,
        activeBreakRequestId: null,
        requestStatus: DriverBreakRequestStatus.cancelled,
        requestId: requestId,
        requestKind: DriverBreakKind.values.byName(
          request['break_kind'] as String,
        ),
      );
    });
  }

  DriverBreakOperationResult _replayStart({
    required Map<String, dynamic> locked,
    required DriverQueueState queueState,
    required Map<String, dynamic> replay,
    required String shiftId,
    required String driverId,
    required DriverBreakKind kind,
  }) {
    if (replay['shift_id'] != shiftId ||
        replay['driver_id'] != driverId ||
        replay['break_kind'] != kind.name) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.idempotencyKeyReused,
      );
    }
    final status = DriverBreakRequestStatus.values.byName(
      replay['status'] as String,
    );
    final pendingId = locked['pending_break_request_id'] as String?;
    final activeId = locked['active_break_request_id'] as String?;
    if (status == DriverBreakRequestStatus.pending &&
        (pendingId != replay['request_id'] ||
            locked['pending_break_kind'] != kind.name)) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.pendingBreakConflict,
      );
    }
    if (status == DriverBreakRequestStatus.active &&
        (activeId != replay['request_id'] ||
            queueState.availability !=
                (kind == DriverBreakKind.short
                    ? DriverQueueAvailability.shortBreak
                    : DriverQueueAvailability.longBreak))) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.pendingBreakConflict,
      );
    }
    return DriverBreakOperationResult(
      shift: _activeShiftFromRow(locked, queueState),
      pendingBreakKind: locked['pending_break_kind'] == null
          ? null
          : DriverBreakKind.values.byName(
              locked['pending_break_kind'] as String,
            ),
      pendingBreakRequestId: pendingId,
      pendingBreakRequestedAt: status == DriverBreakRequestStatus.pending
          ? (replay['requested_at'] as DateTime).toUtc()
          : null,
      activeBreakRequestId: activeId,
      requestStatus: status,
      replayed: true,
      requestId: replay['request_id'] as String,
      requestKind: DriverBreakKind.values.byName(
        replay['break_kind'] as String,
      ),
    );
  }

  DriverQueueState _startQueueBreak(
    DriverQueueState state,
    DriverBreakKind kind,
    DateTime now,
  ) {
    try {
      return switch (kind) {
        DriverBreakKind.short => state.startShortBreak(now),
        DriverBreakKind.long => state.startLongBreak(now),
      };
    } on DriverQueueConflictException catch (error) {
      if (error.conflict == DriverQueueConflict.noShortBreaksRemaining) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.noShortBreaksRemaining,
        );
      }
      if (error.conflict == DriverQueueConflict.activeOffer) {
        throw const DriverBreakConflictException(
          DriverBreakConflict.activeOffer,
        );
      }
      throw const DriverBreakConflictException(
        DriverBreakConflict.notAvailable,
      );
    }
  }

  Future<Map<String, dynamic>?> _lockActiveShift(
    Session transaction,
    String driverId,
  ) async {
    final result = await transaction.execute(
      Sql.named('''
        SELECT
          s.id AS shift_id,
          s.driver_id,
          s.vehicle_id,
          s.started_at,
          s.protected_breaks_used,
          q.availability,
          q.queue_priority_since,
          q.break_started_at,
          q.has_pending_offer,
          q.pending_break_kind,
          q.pending_break_request_id,
          q.active_break_request_id
        FROM driver_shifts s
        JOIN driver_queue_states q ON q.shift_id = s.id
        WHERE s.driver_id = @driverId AND s.ended_at IS NULL
        LIMIT 2
        FOR UPDATE OF s, q
      '''),
      parameters: {'driverId': driverId},
    );
    if (result.length > 1) {
      throw StateError('Driver has more than one active shift.');
    }
    return result.isEmpty ? null : result.single.toColumnMap();
  }

  Future<DateTime> _databaseNow(Session transaction) async {
    final result = await transaction.execute('SELECT clock_timestamp() AS now');
    return (result.single.toColumnMap()['now'] as DateTime).toUtc();
  }

  Future<DriverQueueState> _materializedQueueState(
    Session transaction,
    Map<String, dynamic> row, {
    required DateTime now,
  }) async {
    final raw = _queueStateFromRow(row);
    final effective = raw.effectiveAt(now);
    if (raw.availability == effective.availability) {
      return raw;
    }

    final activeRequestId = row['active_break_request_id'] as String?;
    if (activeRequestId != null) {
      await _completeRequest(transaction, activeRequestId, now);
    }
    await transaction.execute(
      Sql.named('''
        UPDATE driver_queue_states
        SET availability = 'available',
            break_started_at = NULL,
            active_break_request_id = NULL
        WHERE shift_id = @shiftId
          AND availability = 'shortBreak'
          AND break_started_at <=
            @now - (@durationSeconds * INTERVAL '1 second')
      '''),
      parameters: {
        'shiftId': row['shift_id'],
        'now': now,
        'durationSeconds': DriverQueueState.shortBreakDuration.inSeconds,
      },
    );
    row['availability'] = effective.availability.name;
    row['break_started_at'] = null;
    row['active_break_request_id'] = null;
    return effective;
  }

  DriverQueueState _queueStateFromRow(Map<String, dynamic> row) {
    return DriverQueueState.restore(
      driverId: row['driver_id'] as String,
      queuePrioritySince: (row['queue_priority_since'] as DateTime).toUtc(),
      availability: DriverQueueAvailability.values.byName(
        row['availability'] as String,
      ),
      shortBreaksUsed: row['protected_breaks_used'] as int,
      breakStartedAt: (row['break_started_at'] as DateTime?)?.toUtc(),
      hasPendingOffer: row['has_pending_offer'] as bool,
    );
  }

  Future<Map<String, dynamic>?> _findRequest(
    Session transaction,
    String requestId,
  ) async {
    final result = await transaction.execute(
      Sql.named('''
        SELECT request.request_id, request.shift_id, shift.driver_id,
               request.break_kind, request.status, request.requested_at,
               request.activated_at, request.ended_at
        FROM driver_break_requests request
        JOIN driver_shifts shift ON shift.id = request.shift_id
        WHERE request.request_id = @requestId
        FOR UPDATE OF request
      '''),
      parameters: {'requestId': requestId},
    );
    return result.isEmpty ? null : result.single.toColumnMap();
  }

  Future<void> _insertRequest(
    Session transaction, {
    required String requestId,
    required String shiftId,
    required DriverBreakKind kind,
    required DriverBreakRequestStatus status,
    required DateTime requestedAt,
    DateTime? activatedAt,
  }) async {
    await transaction.execute(
      Sql.named('''
        INSERT INTO driver_break_requests (
          request_id, shift_id, break_kind, status,
          requested_at, activated_at, ended_at
        ) VALUES (
          @requestId, @shiftId, @kind, @status,
          @requestedAt, @activatedAt, NULL
        )
      '''),
      parameters: {
        'requestId': requestId,
        'shiftId': shiftId,
        'kind': kind.name,
        'status': status.name,
        'requestedAt': requestedAt,
        'activatedAt': activatedAt,
      },
    );
  }

  Future<void> _completeRequest(
    Session transaction,
    String requestId,
    DateTime endedAt,
  ) async {
    final result = await transaction.execute(
      Sql.named('''
        UPDATE driver_break_requests
        SET status = 'completed', ended_at = @endedAt
        WHERE request_id = @requestId
          AND status = 'active'
        RETURNING request_id
      '''),
      parameters: {'requestId': requestId, 'endedAt': endedAt},
    );
    if (result.isEmpty) {
      throw StateError('Active break request is missing or inconsistent.');
    }
  }

  Future<void> _ensureNoPendingOffer(
    Session transaction,
    String driverId,
    DriverQueueState queueState,
  ) async {
    if (queueState.hasPendingOffer) {
      throw const DriverBreakConflictException(DriverBreakConflict.activeOffer);
    }
    final result = await transaction.execute(
      Sql.named('''
        SELECT EXISTS (
          SELECT 1 FROM ride_offers
          WHERE driver_id = @driverId AND status = 'pending'
        ) AS exists
      '''),
      parameters: {'driverId': driverId},
    );
    if (result.single.toColumnMap()['exists'] as bool) {
      throw const DriverBreakConflictException(DriverBreakConflict.activeOffer);
    }
  }

  Future<void> _ensureNoCurrentRide(
    Session transaction,
    String driverId,
  ) async {
    final result = await transaction.execute(
      Sql.named('''
        SELECT EXISTS (
          SELECT 1 FROM rides
          WHERE assigned_driver_id = @driverId
            AND status IN ('accepted', 'driverArriving', 'inProgress')
        ) AS exists
      '''),
      parameters: {'driverId': driverId},
    );
    if (result.single.toColumnMap()['exists'] as bool) {
      throw const DriverBreakConflictException(DriverBreakConflict.currentRide);
    }
  }

  Future<void> _ensureHasCurrentRide(
    Session transaction,
    String driverId,
    String vehicleId,
  ) async {
    final result = await transaction.execute(
      Sql.named('''
        SELECT id
        FROM rides
        WHERE assigned_driver_id = @driverId
          AND assigned_vehicle_id = @vehicleId
          AND status IN ('accepted', 'driverArriving', 'inProgress')
        ORDER BY requested_at
        FOR UPDATE
      '''),
      parameters: {'driverId': driverId, 'vehicleId': vehicleId},
    );
    if (result.isEmpty) {
      throw const DriverBreakConflictException(DriverBreakConflict.currentRide);
    }
    if (result.length > 1) {
      throw StateError('Driver has more than one active current ride.');
    }
  }

  Future<void> _ensureNoReservedRide(
    Session transaction,
    String driverId,
  ) async {
    final result = await transaction.execute(
      Sql.named('''
        SELECT EXISTS (
          SELECT 1
          FROM ride_reservations
          WHERE driver_id = @driverId
            AND ended_at IS NULL
        ) AS exists
      '''),
      parameters: {'driverId': driverId},
    );
    if (result.single.toColumnMap()['exists'] as bool) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.reservedRide,
      );
    }
  }

  Future<void> _persistQueueState(
    Session transaction, {
    required String shiftId,
    required DriverQueueState queueState,
    required DriverBreakKind? pendingBreakKind,
    required String? pendingBreakRequestId,
    required String? activeBreakRequestId,
  }) async {
    final shiftResult = await transaction.execute(
      Sql.named('''
        UPDATE driver_shifts
        SET protected_breaks_used = @shortBreaksUsed
        WHERE id = @shiftId
          AND driver_id = @driverId
          AND ended_at IS NULL
        RETURNING id
      '''),
      parameters: {
        'shiftId': shiftId,
        'driverId': queueState.driverId,
        'shortBreaksUsed': queueState.shortBreaksUsed,
      },
    );
    if (shiftResult.isEmpty) {
      throw const DriverBreakConflictException(
        DriverBreakConflict.activeShiftNotFound,
      );
    }
    final queueResult = await transaction.execute(
      Sql.named('''
        UPDATE driver_queue_states
        SET availability = @availability,
            queue_priority_since = @queuePrioritySince,
            break_started_at = @breakStartedAt,
            has_pending_offer = FALSE,
            pending_break_kind = @pendingBreakKind,
            pending_break_request_id = @pendingBreakRequestId,
            active_break_request_id = @activeBreakRequestId
        WHERE shift_id = @shiftId
        RETURNING shift_id
      '''),
      parameters: {
        'shiftId': shiftId,
        'availability': queueState.availability.name,
        'queuePrioritySince': queueState.queuePrioritySince.toUtc(),
        'breakStartedAt': queueState.breakStartedAt?.toUtc(),
        'pendingBreakKind': pendingBreakKind?.name,
        'pendingBreakRequestId': pendingBreakRequestId,
        'activeBreakRequestId': activeBreakRequestId,
      },
    );
    if (queueResult.isEmpty) {
      throw StateError('Queue state was not found for the active shift.');
    }
  }

  ActiveDriverShift _activeShiftFromRow(
    Map<String, dynamic> row,
    DriverQueueState queueState,
  ) {
    return ActiveDriverShift.restore(
      id: row['shift_id'] as String,
      driverId: row['driver_id'] as String,
      vehicleId: row['vehicle_id'] as String,
      startedAt: (row['started_at'] as DateTime).toUtc(),
      queueState: queueState,
    );
  }
}
