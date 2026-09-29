import 'package:postgres/postgres.dart';

import 'external_ride_session.dart';
import 'external_ride_session_repository.dart';

class PostgresExternalRideSessionRepository
    implements ExternalRideSessionRepository {
  final SessionExecutor database;

  PostgresExternalRideSessionRepository({required this.database});

  @override
  Future<ExternalRideSession?> findById(String id) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT
            id,
            driver_id,
            started_at,
            ended_at,
            distance_meters,
            trigger_offer_id,
            trigger_ride_id
          FROM external_ride_sessions
          WHERE id = @id
        '''),
        parameters: {'id': id},
      );

      if (result.isEmpty) {
        return null;
      }

      return _sessionFromRow(result.first.toColumnMap());
    });
  }

  @override
  Future<ExternalRideSession?> findActiveByDriverId(String driverId) {
    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT
            id,
            driver_id,
            started_at,
            ended_at,
            distance_meters,
            trigger_offer_id,
            trigger_ride_id
          FROM external_ride_sessions
          WHERE driver_id = @driverId
            AND ended_at IS NULL
          LIMIT 1
        '''),
        parameters: {'driverId': driverId},
      );

      if (result.isEmpty) {
        return null;
      }

      return _sessionFromRow(result.first.toColumnMap());
    });
  }

  @override
  Future<ExternalRideSession> createActive(ExternalRideSession session) {
    if (!session.isActive) {
      throw ArgumentError(
        'createActive requires an active external ride session.',
      );
    }

    return database.runTx((transaction) async {
      final driverLock = await transaction.execute(
        Sql.named('''
          SELECT id
          FROM drivers
          WHERE id = @driverId
          FOR UPDATE
        '''),
        parameters: {'driverId': session.driverId},
      );

      if (driverLock.isEmpty) {
        throw ArgumentError.value(
          session.driverId,
          'driverId',
          'Driver does not exist.',
        );
      }

      final existing = await transaction.execute(
        Sql.named('''
          SELECT id
          FROM external_ride_sessions
          WHERE driver_id = @driverId
            AND ended_at IS NULL
          LIMIT 1
        '''),
        parameters: {'driverId': session.driverId},
      );

      if (existing.isNotEmpty) {
        throw const ExternalRideSessionRepositoryConflictException(
          ExternalRideSessionRepositoryConflict.driverAlreadyHasActiveSession,
        );
      }

      final result = await transaction.execute(
        Sql.named('''
          INSERT INTO external_ride_sessions (
            id,
            driver_id,
            started_at,
            ended_at,
            distance_meters,
            trigger_offer_id,
            trigger_ride_id
          )
          VALUES (
            @id,
            @driverId,
            @startedAt,
            NULL,
            @distanceMeters,
            @triggerOfferId,
            @triggerRideId
          )
          RETURNING
            id,
            driver_id,
            started_at,
            ended_at,
            distance_meters,
            trigger_offer_id,
            trigger_ride_id
        '''),
        parameters: {
          'id': session.id,
          'driverId': session.driverId,
          'startedAt': session.startedAt,
          'distanceMeters': session.distanceMeters,
          'triggerOfferId': session.triggerOfferId,
          'triggerRideId': session.triggerRideId,
        },
      );

      return _sessionFromRow(result.single.toColumnMap());
    });
  }

  @override
  Future<ExternalRideSession> addVerifiedDistance({
    required String driverId,
    required int segmentDistanceMeters,
  }) {
    if (segmentDistanceMeters < 0) {
      throw ArgumentError.value(
        segmentDistanceMeters,
        'segmentDistanceMeters',
        'Segment distance cannot be negative.',
      );
    }

    return database.run((session) async {
      final result = await session.execute(
        Sql.named('''
          UPDATE external_ride_sessions
          SET distance_meters =
              distance_meters + @segmentDistanceMeters
          WHERE driver_id = @driverId
            AND ended_at IS NULL
          RETURNING
            id,
            driver_id,
            started_at,
            ended_at,
            distance_meters,
            trigger_offer_id,
            trigger_ride_id
        '''),
        parameters: {
          'driverId': driverId,
          'segmentDistanceMeters': segmentDistanceMeters,
        },
      );

      if (result.isEmpty) {
        throw const ExternalRideSessionRepositoryConflictException(
          ExternalRideSessionRepositoryConflict.activeSessionNotFound,
        );
      }

      return _sessionFromRow(result.single.toColumnMap());
    });
  }

  @override
  Future<ExternalRideSession> finishActive({
    required String driverId,
    required DateTime finishedAt,
  }) {
    return database.runTx((transaction) async {
      final activeResult = await transaction.execute(
        Sql.named('''
          SELECT
            id,
            driver_id,
            started_at,
            ended_at,
            distance_meters,
            trigger_offer_id,
            trigger_ride_id
          FROM external_ride_sessions
          WHERE driver_id = @driverId
            AND ended_at IS NULL
          LIMIT 1
          FOR UPDATE
        '''),
        parameters: {'driverId': driverId},
      );

      if (activeResult.isEmpty) {
        throw const ExternalRideSessionRepositoryConflictException(
          ExternalRideSessionRepositoryConflict.activeSessionNotFound,
        );
      }

      final current = _sessionFromRow(activeResult.single.toColumnMap());

      final finished = current.finish(finishedAt);

      final updateResult = await transaction.execute(
        Sql.named('''
          UPDATE external_ride_sessions
          SET ended_at = @endedAt
          WHERE id = @id
            AND ended_at IS NULL
          RETURNING
            id,
            driver_id,
            started_at,
            ended_at,
            distance_meters,
            trigger_offer_id,
            trigger_ride_id
        '''),
        parameters: {'id': finished.id, 'endedAt': finished.endedAt},
      );

      if (updateResult.isEmpty) {
        throw const ExternalRideSessionRepositoryConflictException(
          ExternalRideSessionRepositoryConflict.activeSessionNotFound,
        );
      }

      return _sessionFromRow(updateResult.single.toColumnMap());
    });
  }

  ExternalRideSession _sessionFromRow(Map<String, dynamic> row) {
    return ExternalRideSession.restore(
      id: row['id'] as String,
      driverId: row['driver_id'] as String,
      startedAt: row['started_at'] as DateTime,
      endedAt: row['ended_at'] as DateTime?,
      distanceMeters: row['distance_meters'] as int,
      triggerOfferId: row['trigger_offer_id'] as String?,
      triggerRideId: row['trigger_ride_id'] as String?,
    );
  }
}
