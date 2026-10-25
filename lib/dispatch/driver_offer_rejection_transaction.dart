import 'driver_dispatch_state.dart';
import 'driver_offer_action_outbox_repository.dart';
import 'ride_offer.dart';

/// A locked database view of the offer fields needed by the reject policy.
final class DriverOfferRejectionOffer {
  const DriverOfferRejectionOffer({
    required this.id,
    required this.rideId,
    required this.driverId,
    required this.vehicleId,
    required this.dispatchRound,
    required this.offeredAt,
    required this.expiresAt,
    required this.status,
  });

  final String id;
  final String rideId;
  final String driverId;
  final String vehicleId;
  final int dispatchRound;
  final DateTime offeredAt;
  final DateTime expiresAt;
  final RideOfferStatus status;
}

/// Active shift and queue values locked for this driver.
final class DriverOfferRejectionQueue {
  const DriverOfferRejectionQueue({
    required this.shiftId,
    required this.vehicleId,
    required this.availability,
    required this.hasPendingOffer,
  });

  final String shiftId;
  final String vehicleId;
  final String availability;
  final bool hasPendingOffer;
}

/// Operations that must all use one transaction during an explicit reject.
/// The PostgreSQL adapter binds every method to the same [TxSession].
abstract interface class DriverOfferRejectionTransaction {
  Future<DriverOfferRejectionOffer?> lockOffer(String offerId);

  Future<DateTime?> findRideRequestedAt(String rideId);

  Future<DriverOfferRejectionQueue?> lockActiveQueue(String driverId);

  Future<DriverOfferActionOutboxRecord?> findActionForDriver({
    required String offerId,
    required String driverId,
  });

  Future<DriverOfferActionOutboxRecord?> findActionByIdempotencyKey({
    required String driverId,
    required String idempotencyKey,
  });

  Future<DriverDispatchState> updateDispatchState({
    required String driverId,
    required DriverDispatchState Function(DriverDispatchState) transform,
  });

  Future<bool> rejectPendingOffer({
    required String offerId,
    required String driverId,
    required DateTime rejectedAt,
  });

  Future<bool> releaseQueue({
    required String shiftId,
    required DateTime queuePrioritySince,
  });

  Future<DriverOfferActionInsertResult> insertAction(
    DriverOfferActionOutboxRecord record,
  );
}

/// Owns the single PostgreSQL transaction used by the new reject path.
abstract interface class DriverOfferRejectionTransactionRunner {
  Future<T> run<T>(
    Future<T> Function(DriverOfferRejectionTransaction transaction) action,
  );
}
