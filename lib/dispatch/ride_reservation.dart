enum RideReservationConflict { alreadyEnded }

class RideReservationConflictException implements Exception {
  final RideReservationConflict conflict;

  const RideReservationConflictException(this.conflict);

  @override
  String toString() {
    return 'Ride reservation conflict: ${conflict.name}';
  }
}

class RideReservation {
  final String id;

  final String rideId;
  final String driverId;
  final String vehicleId;
  final String shiftId;

  final DateTime reservedAt;
  final DateTime? endedAt;

  const RideReservation._({
    required this.id,
    required this.rideId,
    required this.driverId,
    required this.vehicleId,
    required this.shiftId,
    required this.reservedAt,
    required this.endedAt,
  });

  factory RideReservation.create({
    required String id,
    required String rideId,
    required String driverId,
    required String vehicleId,
    required String shiftId,
    required DateTime reservedAt,
  }) {
    return RideReservation._(
      id: id,
      rideId: rideId,
      driverId: driverId,
      vehicleId: vehicleId,
      shiftId: shiftId,
      reservedAt: reservedAt,
      endedAt: null,
    );
  }

  /// Възстановяване от постоянна база данни.
  ///
  /// Всички проверки се изпълняват и в production режим.
  factory RideReservation.restore({
    required String id,
    required String rideId,
    required String driverId,
    required String vehicleId,
    required String shiftId,
    required DateTime reservedAt,
    required DateTime? endedAt,
  }) {
    if (endedAt != null && endedAt.isBefore(reservedAt)) {
      throw ArgumentError('endedAt cannot be before reservedAt.');
    }

    return RideReservation._(
      id: id,
      rideId: rideId,
      driverId: driverId,
      vehicleId: vehicleId,
      shiftId: shiftId,
      reservedAt: reservedAt,
      endedAt: endedAt,
    );
  }

  bool get isActive => endedAt == null;

  /// Приключва reservation-а без да определя причината.
  ///
  /// Конкретните lifecycle правила за:
  /// - преминаване към текуща City6 поръчка;
  /// - отказ;
  /// - customer cancellation;
  /// - други бъдещи причини
  ///
  /// остават отговорност на atomic repository/service слоя.
  RideReservation end(DateTime endedAt) {
    if (!isActive) {
      throw const RideReservationConflictException(
        RideReservationConflict.alreadyEnded,
      );
    }

    if (endedAt.isBefore(reservedAt)) {
      throw ArgumentError('endedAt cannot be before reservedAt.');
    }

    return RideReservation._(
      id: id,
      rideId: rideId,
      driverId: driverId,
      vehicleId: vehicleId,
      shiftId: shiftId,
      reservedAt: reservedAt,
      endedAt: endedAt,
    );
  }
}