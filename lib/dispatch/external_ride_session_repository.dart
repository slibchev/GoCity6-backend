import 'external_ride_session.dart';

enum ExternalRideSessionRepositoryConflict {
  driverAlreadyHasActiveSession,
  activeSessionNotFound,
}

class ExternalRideSessionRepositoryConflictException implements Exception {
  final ExternalRideSessionRepositoryConflict conflict;

  const ExternalRideSessionRepositoryConflictException(this.conflict);

  @override
  String toString() {
    return 'External ride session repository conflict: ${conflict.name}';
  }
}

abstract interface class ExternalRideSessionRepository {
  Future<ExternalRideSession?> findById(String id);

  Future<ExternalRideSession?> findActiveByDriverId(String driverId);

  /// Създава нов активен external ride.
  ///
  /// Един шофьор може да има максимум една активна session.
  Future<ExternalRideSession> createActive(ExternalRideSession session);

  /// Атомарно добавя вече проверен GPS сегмент към активната
  /// external ride session на шофьора.
  ///
  /// PostgreSQL реализацията трябва да използва:
  ///
  /// distance_meters = distance_meters + segmentDistanceMeters
  ///
  /// вместо read-modify-save, за да няма lost updates.
  Future<ExternalRideSession> addVerifiedDistance({
    required String driverId,
    required int segmentDistanceMeters,
  });

  /// При натискане на "Свободен" приключва текущата external ride
  /// session на шофьора.
  ///
  /// Нареждането в текущия район НЕ е отговорност на това repository.
  /// То ще бъде част от общия completion/queue flow.
  Future<ExternalRideSession> finishActive({
    required String driverId,
    required DateTime finishedAt,
  });
}
