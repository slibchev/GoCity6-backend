const Object _notProvided = Object();

enum ExternalRideSessionConflict { alreadyFinished }

class ExternalRideSessionConflictException implements Exception {
  final ExternalRideSessionConflict conflict;

  const ExternalRideSessionConflictException(this.conflict);

  @override
  String toString() {
    return 'External ride session conflict: ${conflict.name}';
  }
}

class ExternalRideSession {
  static const int qualificationDistanceMeters = 500;

  final String id;
  final String driverId;

  final DateTime startedAt;
  final DateTime? endedAt;

  /// Натрупано проверено движение по време на режима "Зает".
  ///
  /// Това не е разстоянието по права линия между началната
  /// и крайната GPS точка. По-късно GPS tracking слоят ще подава
  /// последователни проверени сегменти към този модел.
  final int distanceMeters;

  /// Ако "Зает" е натиснат по време на активна City6 оферта,
  /// пазим коя точно оферта и поръчка са го предизвикали.
  ///
  /// Ако шофьорът е станал "Зает" без активна оферта,
  /// и двете стойности са null.
  final String? triggerOfferId;
  final String? triggerRideId;

  const ExternalRideSession._({
    required this.id,
    required this.driverId,
    required this.startedAt,
    required this.endedAt,
    required this.distanceMeters,
    required this.triggerOfferId,
    required this.triggerRideId,
  });

  factory ExternalRideSession.create({
    required String id,
    required String driverId,
    required DateTime startedAt,
    String? triggerOfferId,
    String? triggerRideId,
  }) {
    _validateTriggerPair(
      triggerOfferId: triggerOfferId,
      triggerRideId: triggerRideId,
    );

    return ExternalRideSession._(
      id: id,
      driverId: driverId,
      startedAt: startedAt,
      endedAt: null,
      distanceMeters: 0,
      triggerOfferId: triggerOfferId,
      triggerRideId: triggerRideId,
    );
  }

  /// Възстановяване от постоянна база данни.
  ///
  /// Всички проверки се изпълняват и в production режим.
  factory ExternalRideSession.restore({
    required String id,
    required String driverId,
    required DateTime startedAt,
    required DateTime? endedAt,
    required int distanceMeters,
    required String? triggerOfferId,
    required String? triggerRideId,
  }) {
    if (distanceMeters < 0) {
      throw ArgumentError.value(
        distanceMeters,
        'distanceMeters',
        'Distance cannot be negative.',
      );
    }

    if (endedAt != null && endedAt.isBefore(startedAt)) {
      throw ArgumentError('endedAt cannot be before startedAt.');
    }

    _validateTriggerPair(
      triggerOfferId: triggerOfferId,
      triggerRideId: triggerRideId,
    );

    return ExternalRideSession._(
      id: id,
      driverId: driverId,
      startedAt: startedAt,
      endedAt: endedAt,
      distanceMeters: distanceMeters,
      triggerOfferId: triggerOfferId,
      triggerRideId: triggerRideId,
    );
  }

  bool get isActive => endedAt == null;

  bool get wasTriggeredByPendingOffer =>
      triggerOfferId != null && triggerRideId != null;

  bool get qualifiesAsExternalRide =>
      distanceMeters >= qualificationDistanceMeters;

  int get remainingMetersToQualify {
    final remaining = qualificationDistanceMeters - distanceMeters;

    return remaining > 0 ? remaining : 0;
  }

  /// Добавя само вече проверен GPS сегмент.
  ///
  /// Например:
  /// point 1 -> point 2 = 90 m
  /// point 2 -> point 3 = 140 m
  ///
  /// След тези две извиквания session.distanceMeters ще бъде 230.
  ExternalRideSession addVerifiedDistance(int segmentDistanceMeters) {
    if (!isActive) {
      throw const ExternalRideSessionConflictException(
        ExternalRideSessionConflict.alreadyFinished,
      );
    }

    if (segmentDistanceMeters < 0) {
      throw ArgumentError.value(
        segmentDistanceMeters,
        'segmentDistanceMeters',
        'Segment distance cannot be negative.',
      );
    }

    return _copyWith(distanceMeters: distanceMeters + segmentDistanceMeters);
  }

  ExternalRideSession finish(DateTime finishedAt) {
    if (!isActive) {
      throw const ExternalRideSessionConflictException(
        ExternalRideSessionConflict.alreadyFinished,
      );
    }

    if (finishedAt.isBefore(startedAt)) {
      throw ArgumentError('finishedAt cannot be before startedAt.');
    }

    return _copyWith(endedAt: finishedAt);
  }

  ExternalRideSession _copyWith({
    DateTime? startedAt,
    Object? endedAt = _notProvided,
    int? distanceMeters,
    Object? triggerOfferId = _notProvided,
    Object? triggerRideId = _notProvided,
  }) {
    return ExternalRideSession._(
      id: id,
      driverId: driverId,
      startedAt: startedAt ?? this.startedAt,
      endedAt: identical(endedAt, _notProvided)
          ? this.endedAt
          : endedAt as DateTime?,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      triggerOfferId: identical(triggerOfferId, _notProvided)
          ? this.triggerOfferId
          : triggerOfferId as String?,
      triggerRideId: identical(triggerRideId, _notProvided)
          ? this.triggerRideId
          : triggerRideId as String?,
    );
  }

  static void _validateTriggerPair({
    required String? triggerOfferId,
    required String? triggerRideId,
  }) {
    final hasOffer = triggerOfferId != null;
    final hasRide = triggerRideId != null;

    if (hasOffer != hasRide) {
      throw ArgumentError(
        'triggerOfferId and triggerRideId must either '
        'both be set or both be null.',
      );
    }
  }
}
