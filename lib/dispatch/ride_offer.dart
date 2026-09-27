enum RideOfferStatus { pending, accepted, rejected, expired }

enum RideOfferConflict { notPending, alreadyExpired, notExpiredYet }

class RideOfferConflictException implements Exception {
  final RideOfferConflict conflict;

  const RideOfferConflictException(this.conflict);

  @override
  String toString() {
    return 'Ride offer conflict: ${conflict.name}';
  }
}

class RideOffer {
  final String id;

  final String rideId;
  final String driverId;
  final String vehicleId;

  final int etaSeconds;
  final int distanceMeters;

  final DateTime offeredAt;
  final DateTime expiresAt;

  final RideOfferStatus status;
  final DateTime? resolvedAt;

  const RideOffer._({
    required this.id,
    required this.rideId,
    required this.driverId,
    required this.vehicleId,
    required this.etaSeconds,
    required this.distanceMeters,
    required this.offeredAt,
    required this.expiresAt,
    required this.status,
    required this.resolvedAt,
  });

  factory RideOffer.create({
    required String id,
    required String rideId,
    required String driverId,
    required String vehicleId,
    required int etaSeconds,
    required int distanceMeters,
    required DateTime offeredAt,
    required Duration timeout,
  }) {
    if (etaSeconds < 0) {
      throw ArgumentError.value(
        etaSeconds,
        'etaSeconds',
        'ETA cannot be negative.',
      );
    }

    if (distanceMeters < 0) {
      throw ArgumentError.value(
        distanceMeters,
        'distanceMeters',
        'Distance cannot be negative.',
      );
    }

    if (timeout.inMicroseconds <= 0) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'Offer timeout must be positive.',
      );
    }

    return RideOffer._(
      id: id,
      rideId: rideId,
      driverId: driverId,
      vehicleId: vehicleId,
      etaSeconds: etaSeconds,
      distanceMeters: distanceMeters,
      offeredAt: offeredAt,
      expiresAt: offeredAt.add(timeout),
      status: RideOfferStatus.pending,
      resolvedAt: null,
    );
  }

  factory RideOffer.restore({
    required String id,
    required String rideId,
    required String driverId,
    required String vehicleId,
    required int etaSeconds,
    required int distanceMeters,
    required DateTime offeredAt,
    required DateTime expiresAt,
    required RideOfferStatus status,
    required DateTime? resolvedAt,
  }) {
    if (etaSeconds < 0) {
      throw ArgumentError.value(
        etaSeconds,
        'etaSeconds',
        'ETA cannot be negative.',
      );
    }

    if (distanceMeters < 0) {
      throw ArgumentError.value(
        distanceMeters,
        'distanceMeters',
        'Distance cannot be negative.',
      );
    }

    if (!expiresAt.isAfter(offeredAt)) {
      throw ArgumentError('Offer expiration must be after offeredAt.');
    }

    switch (status) {
      case RideOfferStatus.pending:
        if (resolvedAt != null) {
          throw ArgumentError('Pending offer cannot have resolvedAt.');
        }

      case RideOfferStatus.accepted:
      case RideOfferStatus.rejected:
        if (resolvedAt == null || !resolvedAt.isBefore(expiresAt)) {
          throw ArgumentError(
            'Accepted or rejected offer must be resolved before expiration.',
          );
        }

      case RideOfferStatus.expired:
        if (resolvedAt == null || resolvedAt.isBefore(expiresAt)) {
          throw ArgumentError(
            'Expired offer must be resolved at or after expiration.',
          );
        }
    }

    return RideOffer._(
      id: id,
      rideId: rideId,
      driverId: driverId,
      vehicleId: vehicleId,
      etaSeconds: etaSeconds,
      distanceMeters: distanceMeters,
      offeredAt: offeredAt,
      expiresAt: expiresAt,
      status: status,
      resolvedAt: resolvedAt,
    );
  }

  bool get isPending => status == RideOfferStatus.pending;

  bool isExpiredAt(DateTime now) {
    return !now.isBefore(expiresAt);
  }

  RideOffer accept(DateTime now) {
    _requirePending();

    if (isExpiredAt(now)) {
      throw const RideOfferConflictException(RideOfferConflict.alreadyExpired);
    }

    return _resolved(status: RideOfferStatus.accepted, resolvedAt: now);
  }

  RideOffer reject(DateTime now) {
    _requirePending();

    if (isExpiredAt(now)) {
      throw const RideOfferConflictException(RideOfferConflict.alreadyExpired);
    }

    return _resolved(status: RideOfferStatus.rejected, resolvedAt: now);
  }

  RideOffer expire(DateTime now) {
    _requirePending();

    if (!isExpiredAt(now)) {
      throw const RideOfferConflictException(RideOfferConflict.notExpiredYet);
    }

    return _resolved(status: RideOfferStatus.expired, resolvedAt: now);
  }

  void _requirePending() {
    if (!isPending) {
      throw const RideOfferConflictException(RideOfferConflict.notPending);
    }
  }

  RideOffer _resolved({
    required RideOfferStatus status,
    required DateTime resolvedAt,
  }) {
    return RideOffer._(
      id: id,
      rideId: rideId,
      driverId: driverId,
      vehicleId: vehicleId,
      etaSeconds: etaSeconds,
      distanceMeters: distanceMeters,
      offeredAt: offeredAt,
      expiresAt: expiresAt,
      status: status,
      resolvedAt: resolvedAt,
    );
  }
}
