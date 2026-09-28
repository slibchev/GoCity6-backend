import 'package:postgres/postgres.dart';

import 'ride_offer.dart';
import 'ride_offer_repository.dart';

class PostgresRideOfferRepository implements RideOfferRepository {
  final Session database;

  PostgresRideOfferRepository({required this.database});

  @override
  Future<RideOffer?> findById(String id) async {
    final result = await database.execute(
      Sql.named('''
        SELECT
          id,
          ride_id,
          driver_id,
          vehicle_id,
          eta_seconds,
          distance_meters,
          dispatch_round,
          bonus_minor,
          offered_at,
          expires_at,
          status,
          resolved_at
        FROM ride_offers
        WHERE id = @id
        LIMIT 1
      '''),
      parameters: {'id': id},
    );

    if (result.isEmpty) {
      return null;
    }

    return _offerFromRow(result.first.toColumnMap());
  }

  @override
  Future<List<RideOffer>> findByRideId(String rideId) async {
    final result = await database.execute(
      Sql.named('''
        SELECT
          id,
          ride_id,
          driver_id,
          vehicle_id,
          eta_seconds,
          distance_meters,
          dispatch_round,
          bonus_minor,
          offered_at,
          expires_at,
          status,
          resolved_at
        FROM ride_offers
        WHERE ride_id = @rideId
        ORDER BY offered_at ASC
      '''),
      parameters: {'rideId': rideId},
    );

    return result.map((row) => _offerFromRow(row.toColumnMap())).toList();
  }

  @override
  Future<List<RideOffer>> findPendingExpiredAt(DateTime now) async {
    final result = await database.execute(
      Sql.named('''
        SELECT
          id,
          ride_id,
          driver_id,
          vehicle_id,
          eta_seconds,
          distance_meters,
          dispatch_round,
          bonus_minor,
          offered_at,
          expires_at,
          status,
          resolved_at
        FROM ride_offers
        WHERE status = 'pending'
          AND expires_at <= @now
        ORDER BY expires_at ASC
      '''),
      parameters: {'now': now.toUtc()},
    );

    return result.map((row) => _offerFromRow(row.toColumnMap())).toList();
  }

  @override
  Future<void> create(RideOffer offer) async {
    if (offer.status != RideOfferStatus.pending || offer.resolvedAt != null) {
      throw ArgumentError('Only a pending unresolved offer can be created.');
    }

    await database.execute(
      Sql.named('''
        INSERT INTO ride_offers (
          id,
          ride_id,
          driver_id,
          vehicle_id,
          eta_seconds,
          distance_meters,
          dispatch_round,
          bonus_minor,
          offered_at,
          expires_at,
          status,
          resolved_at
        )
        VALUES (
          @id,
          @rideId,
          @driverId,
          @vehicleId,
          @etaSeconds,
          @distanceMeters,
          @dispatchRound,
          @bonusMinor,
          @offeredAt,
          @expiresAt,
          @status,
          @resolvedAt
        )
      '''),
      parameters: {
        'id': offer.id,
        'rideId': offer.rideId,
        'driverId': offer.driverId,
        'vehicleId': offer.vehicleId,
        'etaSeconds': offer.etaSeconds,
        'distanceMeters': offer.distanceMeters,
        'dispatchRound': offer.dispatchRound,
        'bonusMinor': offer.bonusMinor,
        'offeredAt': offer.offeredAt.toUtc(),
        'expiresAt': offer.expiresAt.toUtc(),
        'status': offer.status.name,
        'resolvedAt': offer.resolvedAt?.toUtc(),
      },
    );
  }

  @override
  Future<bool> resolve(RideOffer offer) async {
    if (offer.status == RideOfferStatus.pending || offer.resolvedAt == null) {
      throw ArgumentError(
        'Resolved offer must have a terminal status and resolvedAt.',
      );
    }

    final result = await database.execute(
      Sql.named('''
        UPDATE ride_offers
        SET
          status = @status,
          resolved_at = @resolvedAt
        WHERE id = @id
          AND status = 'pending'
      '''),
      parameters: {
        'id': offer.id,
        'status': offer.status.name,
        'resolvedAt': offer.resolvedAt!.toUtc(),
      },
    );

    return result.affectedRows == 1;
  }

  RideOffer _offerFromRow(Map<String, dynamic> row) {
    return RideOffer.restore(
      id: row['id'] as String,
      rideId: row['ride_id'] as String,
      driverId: row['driver_id'] as String,
      vehicleId: row['vehicle_id'] as String,
      etaSeconds: row['eta_seconds'] as int,
      distanceMeters: row['distance_meters'] as int,
      dispatchRound: row['dispatch_round'] as int,
      bonusMinor: row['bonus_minor'] as int,
      offeredAt: (row['offered_at'] as DateTime).toUtc(),
      expiresAt: (row['expires_at'] as DateTime).toUtc(),
      status: RideOfferStatus.values.byName(row['status'] as String),
      resolvedAt: (row['resolved_at'] as DateTime?)?.toUtc(),
    );
  }
}
