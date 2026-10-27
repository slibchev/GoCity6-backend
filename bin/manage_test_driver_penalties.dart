import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';

import 'package:gocity6_backend/admin/test_driver_penalty_admin.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_state.dart';

Future<void> main(List<String> args) async {
  final options = _parse(args);
  final driverId = options['driver'];
  final actionText = options['action'];
  if (driverId == null || actionText == null) {
    stderr.writeln(
      'Usage: manage_test_driver_penalties.dart --driver=<id> '
      '--action=UNBLOCK|FULL_RESET [--reason=<text> --apply '
      '--confirm=<same-id>]',
    );
    exitCode = 2;
    return;
  }
  if (!TestDriverPenaltyAdmin.allowedDriverIds.contains(driverId)) {
    stderr.writeln('Driver is not in the test-tool allowlist.');
    exitCode = 2;
    return;
  }
  final action = switch (actionText) {
    'UNBLOCK' => TestDriverPenaltyAction.unblock,
    'FULL_RESET' => TestDriverPenaltyAction.fullReset,
    _ => null,
  };
  if (action == null) {
    stderr.writeln('Action must be UNBLOCK or FULL_RESET.');
    exitCode = 2;
    return;
  }
  final apply = options.containsKey('apply');
  if (apply && options['confirm'] != driverId) {
    stderr.writeln('Write requires --confirm=<exact driver id>.');
    exitCode = 2;
    return;
  }
  final reason = options['reason']?.trim() ?? '';
  if (apply && reason.isEmpty) {
    stderr.writeln('Write requires a non-empty --reason.');
    exitCode = 2;
    return;
  }
  if (apply &&
      (reason.length > 120 ||
          !RegExp(r'^[\p{L}\p{N} .,;:_-]+$', unicode: true).hasMatch(reason))) {
    stderr.writeln('Reason must be at most 120 plain text characters.');
    exitCode = 2;
    return;
  }
  final password = Platform.environment['CITY6_DB_PASSWORD'];
  if (password == null || password.isEmpty) {
    stderr.writeln('Protected City6 settings were not loaded.');
    exitCode = 2;
    return;
  }

  final connection = await Connection.open(
    Endpoint(
      host: 'localhost',
      port: 5432,
      database: 'city6',
      username: 'city6_app',
      password: password,
    ),
    settings: const ConnectionSettings(sslMode: SslMode.disable),
  );
  try {
    final identity = await connection.execute(
      "SELECT current_database(), current_user, current_schema(), "
      "host(inet_server_addr()), inet_server_port()",
    );
    final identityRow = identity.single;
    if (identityRow[0] != 'city6' ||
        identityRow[1] != 'city6_app' ||
        identityRow[2] != 'public' ||
        !{'127.0.0.1', '::1'}.contains(identityRow[3]) ||
        identityRow[4] != 5432) {
      throw StateError('Database identity check failed; refusing to continue.');
    }

    final drivers = await connection.execute(
      Sql.named('SELECT id FROM drivers WHERE id = @id'),
      parameters: {'id': driverId},
    );
    if (drivers.isEmpty) throw StateError('Driver does not exist.');

    final stateRows = await connection.execute(
      Sql.named('''
        SELECT consecutive_rejects, penalty_level, dispatch_blocked_until,
          penalty_reset_eligible_at, requires_completed_ride_after_penalty
        FROM driver_dispatch_states WHERE driver_id = @id
      '''),
      parameters: {'id': driverId},
    );
    final current = stateRows.isEmpty
        ? DriverDispatchState(
            driverId: driverId,
            consecutiveRejects: 0,
            penaltyLevel: 0,
            dispatchBlockedUntil: null,
            penaltyResetEligibleAt: null,
          )
        : _state(driverId, stateRows.single.toColumnMap());

    final pendingOffers = await connection.execute(
      Sql.named("""
        SELECT count(*) FROM ride_offers
        WHERE driver_id = @id AND status = 'pending' AND expires_at > now()
      """),
      parameters: {'id': driverId},
    );
    final activeRides = await connection.execute(
      Sql.named("""
        SELECT count(*) FROM rides
        WHERE assigned_driver_id = @id
          AND status IN ('accepted', 'driverArriving', 'inProgress')
      """),
      parameters: {'id': driverId},
    );
    final unprocessedExpired = await connection.execute(
      Sql.named("""
        SELECT count(*)
        FROM ride_offers o JOIN rides r ON r.id = o.ride_id
        LEFT JOIN ignored_offer_penalty_tracking t ON t.offer_id = o.id
        WHERE o.driver_id = @id
          AND (o.status = 'expired' OR
            (o.status = 'pending' AND o.expires_at <= now()))
          AND o.displayed_at IS NOT NULL AND o.displayed_at < o.expires_at
          AND t.offer_id IS NULL
          AND o.offered_at >= r.requested_at
          AND o.offered_at < r.requested_at + interval '20 minutes'
      """),
      parameters: {'id': driverId},
    );
    final blockers =
        (pendingOffers.single[0] as int) +
        (activeRides.single[0] as int) +
        (unprocessedExpired.single[0] as int);

    stdout.writeln('database: city6');
    stdout.writeln('driver: $driverId');
    stdout.writeln('action: $actionText');
    stdout.writeln('before: ${jsonEncode(_stateJson(current))}');
    stdout.writeln(
      'activeOffers=${pendingOffers.single[0]}, '
      'activeRides=${activeRides.single[0]}, '
      'unprocessedExpiredOffers=${unprocessedExpired.single[0]}',
    );
    if (blockers != 0) {
      throw StateError('Active or unprocessed offer prevents safe action.');
    }
    if (!apply) {
      stdout.writeln('preview only; no database changes made');
      return;
    }

    var next = current;
    await connection.runTx((tx) async {
      final safetyRows = await tx.execute(
        Sql.named('''
          SELECT
            (SELECT count(*) FROM ride_offers
              WHERE driver_id = @id AND status = 'pending'
                AND expires_at > now()) AS active_offers,
            (SELECT count(*) FROM rides
              WHERE assigned_driver_id = @id
                AND status IN ('accepted', 'driverArriving', 'inProgress'))
              AS active_rides,
            (SELECT count(*)
              FROM ride_offers o JOIN rides r ON r.id = o.ride_id
              LEFT JOIN ignored_offer_penalty_tracking t ON t.offer_id = o.id
              WHERE o.driver_id = @id
                AND (o.status = 'expired' OR
                  (o.status = 'pending' AND o.expires_at <= now()))
                AND o.displayed_at IS NOT NULL
                AND o.displayed_at < o.expires_at
                AND t.offer_id IS NULL
                AND o.offered_at >= r.requested_at
                AND o.offered_at < r.requested_at + interval '20 minutes')
              AS unprocessed_expired
        '''),
        parameters: {'id': driverId},
      );
      final safety = safetyRows.single.toColumnMap();
      if ((safety['active_offers'] as int) != 0 ||
          (safety['active_rides'] as int) != 0 ||
          (safety['unprocessed_expired'] as int) != 0) {
        throw StateError('Active or unprocessed offer prevents safe action.');
      }
      await tx.execute(
        Sql.named('''
          INSERT INTO driver_dispatch_states (driver_id)
          VALUES (@id) ON CONFLICT (driver_id) DO NOTHING
        '''),
        parameters: {'id': driverId},
      );
      final lockedRows = await tx.execute(
        Sql.named('''
          SELECT driver_id, consecutive_rejects, penalty_level,
            dispatch_blocked_until, penalty_reset_eligible_at,
            requires_completed_ride_after_penalty
          FROM driver_dispatch_states WHERE driver_id = @id FOR UPDATE
        '''),
        parameters: {'id': driverId},
      );
      final lockedCurrent = _state(driverId, lockedRows.single.toColumnMap());
      next = TestDriverPenaltyAdmin.apply(lockedCurrent, action);
      await tx.execute(
        Sql.named('''
          UPDATE driver_dispatch_states SET
            consecutive_rejects = @rejects,
            penalty_level = @level,
            dispatch_blocked_until = @blocked,
            penalty_reset_eligible_at = @eligible,
            requires_completed_ride_after_penalty = @recovery,
            updated_at = now()
          WHERE driver_id = @id
        '''),
        parameters: {
          'id': driverId,
          'rejects': next.consecutiveRejects,
          'level': next.penaltyLevel,
          'blocked': next.dispatchBlockedUntil,
          'eligible': next.penaltyResetEligibleAt,
          'recovery': next.requiresCompletedRideAfterPenalty,
        },
      );
    });
    stdout.writeln('after: ${jsonEncode(_stateJson(next))}');
    await _appendReport(driverId, actionText, reason);
  } finally {
    await connection.close();
  }
}

Map<String, String> _parse(List<String> args) {
  final result = <String, String>{};
  for (final arg in args) {
    if (arg == '--apply') {
      result['apply'] = 'true';
    } else if (arg.startsWith('--') && arg.contains('=')) {
      final separator = arg.indexOf('=');
      result[arg.substring(2, separator)] = arg.substring(separator + 1);
    } else {
      throw FormatException('Invalid argument.');
    }
  }
  return result;
}

DriverDispatchState _state(String id, Map<String, dynamic> row) =>
    DriverDispatchState(
      driverId: id,
      consecutiveRejects: row['consecutive_rejects'] as int,
      penaltyLevel: row['penalty_level'] as int,
      dispatchBlockedUntil: (row['dispatch_blocked_until'] as DateTime?)
          ?.toUtc(),
      penaltyResetEligibleAt: (row['penalty_reset_eligible_at'] as DateTime?)
          ?.toUtc(),
      requiresCompletedRideAfterPenalty:
          row['requires_completed_ride_after_penalty'] as bool,
    );

Map<String, Object?> _stateJson(DriverDispatchState state) => {
  'consecutive_rejects': state.consecutiveRejects,
  'penalty_level': state.penaltyLevel,
  'dispatch_blocked_until': state.dispatchBlockedUntil?.toIso8601String(),
  'penalty_reset_eligible_at': state.penaltyResetEligibleAt?.toIso8601String(),
  'requires_completed_ride_after_penalty':
      state.requiresCompletedRideAfterPenalty,
};

Future<void> _appendReport(
  String driverId,
  String action,
  String reason,
) async {
  final localAppData = Platform.environment['LOCALAPPDATA'];
  if (localAppData == null || localAppData.isEmpty) {
    throw StateError(
      'LOCALAPPDATA is unavailable; local action log not saved.',
    );
  }
  final directory = Directory(
    '$localAppData${Platform.pathSeparator}'
    'City6${Platform.pathSeparator}admin',
  );
  await directory.create(recursive: true);
  final file = File(
    '${directory.path}${Platform.pathSeparator}'
    'test-driver-penalty-actions.jsonl',
  );
  await file.writeAsString(
    '${jsonEncode({'at': DateTime.now().toUtc().toIso8601String(), 'driverId': driverId, 'action': action, 'reason': reason})}\n',
    mode: FileMode.append,
    flush: true,
  );
}
