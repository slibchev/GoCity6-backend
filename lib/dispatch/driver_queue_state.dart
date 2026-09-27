const Object _notProvided = Object();

enum DriverQueueAvailability { available, shortBreak, longBreak }

enum DriverQueueConflict {
  activeOffer,
  notAvailable,
  noShortBreaksRemaining,
  noActiveOffer,
  notOnBreak,
}

class DriverQueueConflictException implements Exception {
  final DriverQueueConflict conflict;

  const DriverQueueConflictException(this.conflict);

  @override
  String toString() {
    return 'Driver queue conflict: ${conflict.name}';
  }
}

class DriverQueueState {
  static const int maxShortBreaksPerShift = 3;

  static const Duration shortBreakDuration = Duration(minutes: 10);

  final String driverId;

  /// По-старото време означава по-предна позиция в опашката.
  ///
  /// Не пазим фиксиран номер като "трети".
  final DateTime queuePrioritySince;

  final DriverQueueAvailability availability;

  /// Брой използвани къси почивки в текущата смяна.
  final int shortBreaksUsed;

  final DateTime? breakStartedAt;

  /// Има предложение, за което шофьорът трябва да отговори.
  final bool hasPendingOffer;

  const DriverQueueState({
    required this.driverId,
    required this.queuePrioritySince,
    this.availability = DriverQueueAvailability.available,
    this.shortBreaksUsed = 0,
    this.breakStartedAt,
    this.hasPendingOffer = false,
  }) : assert(shortBreaksUsed >= 0),
       assert(shortBreaksUsed <= maxShortBreaksPerShift);

  int get shortBreaksRemaining => maxShortBreaksPerShift - shortBreaksUsed;

  DriverQueueState beginOffer() {
    if (availability != DriverQueueAvailability.available) {
      throw const DriverQueueConflictException(
        DriverQueueConflict.notAvailable,
      );
    }

    if (hasPendingOffer) {
      throw const DriverQueueConflictException(DriverQueueConflict.activeOffer);
    }

    return _copyWith(hasPendingOffer: true);
  }

  DriverQueueState rejectOffer(DateTime now) {
    _requirePendingOffer();

    return _copyWith(hasPendingOffer: false, queuePrioritySince: now);
  }

  DriverQueueState expireOffer(DateTime now) {
    _requirePendingOffer();

    return _copyWith(hasPendingOffer: false, queuePrioritySince: now);
  }

  DriverQueueState startShortBreak(DateTime now) {
    _requireCanStartBreak();

    if (shortBreaksUsed >= maxShortBreaksPerShift) {
      throw const DriverQueueConflictException(
        DriverQueueConflict.noShortBreaksRemaining,
      );
    }

    return _copyWith(
      availability: DriverQueueAvailability.shortBreak,
      shortBreaksUsed: shortBreaksUsed + 1,
      breakStartedAt: now,
    );
  }

  DriverQueueState startLongBreak(DateTime now) {
    _requireCanStartBreak();

    return _copyWith(
      availability: DriverQueueAvailability.longBreak,
      breakStartedAt: now,
    );
  }

  DriverQueueState returnFromBreak(DateTime now) {
    switch (availability) {
      case DriverQueueAvailability.shortBreak:
        return _copyWith(
          availability: DriverQueueAvailability.available,
          breakStartedAt: null,
        );

      case DriverQueueAvailability.longBreak:
        return _copyWith(
          availability: DriverQueueAvailability.available,
          queuePrioritySince: now,
          breakStartedAt: null,
        );

      case DriverQueueAvailability.available:
        throw const DriverQueueConflictException(
          DriverQueueConflict.notOnBreak,
        );
    }
  }

  /// При изтичане на 10-те минути късата почивка приключва
  /// автоматично. Старият queuePrioritySince се запазва.
  DriverQueueState effectiveAt(DateTime now) {
    if (availability != DriverQueueAvailability.shortBreak ||
        breakStartedAt == null) {
      return this;
    }

    final elapsed = now.difference(breakStartedAt!);

    if (elapsed < shortBreakDuration) {
      return this;
    }

    return _copyWith(
      availability: DriverQueueAvailability.available,
      breakStartedAt: null,
    );
  }

  void _requireCanStartBreak() {
    if (hasPendingOffer) {
      throw const DriverQueueConflictException(DriverQueueConflict.activeOffer);
    }

    if (availability != DriverQueueAvailability.available) {
      throw const DriverQueueConflictException(
        DriverQueueConflict.notAvailable,
      );
    }
  }

  void _requirePendingOffer() {
    if (!hasPendingOffer) {
      throw const DriverQueueConflictException(
        DriverQueueConflict.noActiveOffer,
      );
    }
  }

  DriverQueueState _copyWith({
    DateTime? queuePrioritySince,
    DriverQueueAvailability? availability,
    int? shortBreaksUsed,
    Object? breakStartedAt = _notProvided,
    bool? hasPendingOffer,
  }) {
    return DriverQueueState(
      driverId: driverId,
      queuePrioritySince: queuePrioritySince ?? this.queuePrioritySince,
      availability: availability ?? this.availability,
      shortBreaksUsed: shortBreaksUsed ?? this.shortBreaksUsed,
      breakStartedAt: identical(breakStartedAt, _notProvided)
          ? this.breakStartedAt
          : breakStartedAt as DateTime?,
      hasPendingOffer: hasPendingOffer ?? this.hasPendingOffer,
    );
  }
}
