enum RideOfferStatus { pending, accepted, rejected, expired }

enum RideOfferSource {
  automatic('automatic'),
  waitingBoard('waiting_board');

  const RideOfferSource(this.databaseValue);

  final String databaseValue;

  static RideOfferSource fromDatabaseValue(String value) {
    for (final source in values) {
      if (source.databaseValue == value) {
        return source;
      }
    }

    throw ArgumentError.value(value, 'value', 'Unknown ride offer source.');
  }
}

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
  static const int normalDispatchRound = 1;
  static const int bonusDispatchRound = 2;

  static const int noBonusMinor = 0;
  static const int shortRideBonusMinor = 500;

  final String id;

  final String rideId;
  final String driverId;
  final String vehicleId;
  final RideOfferSource source;

  /// Route metrics are optional for district FIFO offers. They are display
  /// metadata only and never determine the local queue order.
  final int? etaSeconds;
  final int? distanceMeters;

  /// The confirmed driver district at dispatch time. Persisted so customer
  /// cancellation can restore priority only when the driver never left it.
  final int? dispatchDistrictObjectId;
  final DateTime? dispatchDistrictEnteredAt;

  /// Transient compare-and-set values used by atomic district offer creation.
  /// These are not part of the public API or persisted on the offer row.
  final DateTime? dispatchLocationUpdatedAt;
  final DateTime? dispatchGpsFixAt;
  final bool dispatchHadCancellationPriority;

  final int dispatchRound;
  final int bonusMinor;

  final DateTime offeredAt;
  final DateTime expiresAt;

  final RideOfferStatus status;
  final DateTime? resolvedAt;
  final DateTime? displayedAt;

  const RideOffer._({
    required this.id,
    required this.rideId,
    required this.driverId,
    required this.vehicleId,
    required this.source,
    required this.etaSeconds,
    required this.distanceMeters,
    required this.dispatchDistrictObjectId,
    required this.dispatchDistrictEnteredAt,
    required this.dispatchLocationUpdatedAt,
    required this.dispatchGpsFixAt,
    required this.dispatchHadCancellationPriority,
    required this.dispatchRound,
    required this.bonusMinor,
    required this.offeredAt,
    required this.expiresAt,
    required this.status,
    required this.resolvedAt,
    required this.displayedAt,
  });

  factory RideOffer.create({
    required String id,
    required String rideId,
    required String driverId,
    required String vehicleId,
    required int? etaSeconds,
    required int? distanceMeters,
    int? dispatchDistrictObjectId,
    DateTime? dispatchDistrictEnteredAt,
    DateTime? dispatchLocationUpdatedAt,
    DateTime? dispatchGpsFixAt,
    bool dispatchHadCancellationPriority = false,
    int dispatchRound = normalDispatchRound,
    int bonusMinor = noBonusMinor,
    RideOfferSource source = RideOfferSource.automatic,
    required DateTime offeredAt,
    required Duration timeout,
  }) {
    _validateRouteMetrics(etaSeconds, distanceMeters);
    _validateDispatchDistrict(
      dispatchDistrictObjectId,
      dispatchDistrictEnteredAt,
    );

    if ((dispatchDistrictObjectId == null) !=
        (dispatchLocationUpdatedAt == null)) {
      throw ArgumentError(
        'District offers require the location timestamp used for selection.',
      );
    }
    if (dispatchDistrictObjectId != null && dispatchGpsFixAt == null) {
      throw ArgumentError('District offers require a GPS fix timestamp.');
    }

    if (etaSeconds != null && etaSeconds < 0) {
      throw ArgumentError.value(
        etaSeconds,
        'etaSeconds',
        'ETA cannot be negative.',
      );
    }

    if (distanceMeters != null && distanceMeters < 0) {
      throw ArgumentError.value(
        distanceMeters,
        'distanceMeters',
        'Distance cannot be negative.',
      );
    }

    _validateDispatchRoundAndBonus(
      dispatchRound: dispatchRound,
      bonusMinor: bonusMinor,
    );

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
      source: source,
      etaSeconds: etaSeconds,
      distanceMeters: distanceMeters,
      dispatchDistrictObjectId: dispatchDistrictObjectId,
      dispatchDistrictEnteredAt: dispatchDistrictEnteredAt?.toUtc(),
      dispatchLocationUpdatedAt: dispatchLocationUpdatedAt?.toUtc(),
      dispatchGpsFixAt: dispatchGpsFixAt?.toUtc(),
      dispatchHadCancellationPriority: dispatchHadCancellationPriority,
      dispatchRound: dispatchRound,
      bonusMinor: bonusMinor,
      offeredAt: offeredAt,
      expiresAt: offeredAt.add(timeout),
      status: RideOfferStatus.pending,
      resolvedAt: null,
      displayedAt: null,
    );
  }

  factory RideOffer.restore({
    required String id,
    required String rideId,
    required String driverId,
    required String vehicleId,
    required int? etaSeconds,
    required int? distanceMeters,
    int? dispatchDistrictObjectId,
    DateTime? dispatchDistrictEnteredAt,
    DateTime? dispatchLocationUpdatedAt,
    DateTime? dispatchGpsFixAt,
    bool dispatchHadCancellationPriority = false,
    int dispatchRound = normalDispatchRound,
    int bonusMinor = noBonusMinor,
    RideOfferSource source = RideOfferSource.automatic,
    required DateTime offeredAt,
    required DateTime expiresAt,
    required RideOfferStatus status,
    required DateTime? resolvedAt,
    DateTime? displayedAt,
  }) {
    _validateRouteMetrics(etaSeconds, distanceMeters);
    _validateDispatchDistrict(
      dispatchDistrictObjectId,
      dispatchDistrictEnteredAt,
    );

    if (etaSeconds != null && etaSeconds < 0) {
      throw ArgumentError.value(
        etaSeconds,
        'etaSeconds',
        'ETA cannot be negative.',
      );
    }

    if (distanceMeters != null && distanceMeters < 0) {
      throw ArgumentError.value(
        distanceMeters,
        'distanceMeters',
        'Distance cannot be negative.',
      );
    }

    _validateDispatchRoundAndBonus(
      dispatchRound: dispatchRound,
      bonusMinor: bonusMinor,
    );

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
      source: source,
      etaSeconds: etaSeconds,
      distanceMeters: distanceMeters,
      dispatchDistrictObjectId: dispatchDistrictObjectId,
      dispatchDistrictEnteredAt: dispatchDistrictEnteredAt?.toUtc(),
      dispatchLocationUpdatedAt: dispatchLocationUpdatedAt?.toUtc(),
      dispatchGpsFixAt: dispatchGpsFixAt?.toUtc(),
      dispatchHadCancellationPriority: dispatchHadCancellationPriority,
      dispatchRound: dispatchRound,
      bonusMinor: bonusMinor,
      offeredAt: offeredAt,
      expiresAt: expiresAt,
      status: status,
      resolvedAt: resolvedAt,
      displayedAt: displayedAt,
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
      source: source,
      etaSeconds: etaSeconds,
      distanceMeters: distanceMeters,
      dispatchDistrictObjectId: dispatchDistrictObjectId,
      dispatchDistrictEnteredAt: dispatchDistrictEnteredAt,
      dispatchLocationUpdatedAt: dispatchLocationUpdatedAt,
      dispatchGpsFixAt: dispatchGpsFixAt,
      dispatchHadCancellationPriority: dispatchHadCancellationPriority,
      dispatchRound: dispatchRound,
      bonusMinor: bonusMinor,
      offeredAt: offeredAt,
      expiresAt: expiresAt,
      status: status,
      resolvedAt: resolvedAt,
      displayedAt: displayedAt,
    );
  }

  static void _validateDispatchRoundAndBonus({
    required int dispatchRound,
    required int bonusMinor,
  }) {
    if (dispatchRound != normalDispatchRound &&
        dispatchRound != bonusDispatchRound) {
      throw ArgumentError.value(
        dispatchRound,
        'dispatchRound',
        'Dispatch round must be 1 or 2.',
      );
    }

    if (dispatchRound == normalDispatchRound && bonusMinor != noBonusMinor) {
      throw ArgumentError('Dispatch round 1 must have no bonus.');
    }

    if (dispatchRound == bonusDispatchRound &&
        bonusMinor != shortRideBonusMinor) {
      throw ArgumentError('Dispatch round 2 must have a 500-cent bonus.');
    }
  }

  static void _validateRouteMetrics(int? etaSeconds, int? distanceMeters) {
    if ((etaSeconds == null) != (distanceMeters == null)) {
      throw ArgumentError(
        'ETA and distance must either both be present or both be null.',
      );
    }
  }

  static void _validateDispatchDistrict(
    int? districtObjectId,
    DateTime? districtEnteredAt,
  ) {
    if ((districtObjectId == null) != (districtEnteredAt == null) ||
        (districtObjectId != null && districtObjectId <= 0)) {
      throw ArgumentError('Invalid district dispatch snapshot.');
    }
  }
}
