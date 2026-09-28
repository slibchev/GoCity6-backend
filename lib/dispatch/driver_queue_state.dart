const Object _notProvided = Object();

enum DriverQueueAvailability {
  available,
  shortBreak,
  longBreak,
  busy,
  externalRide,
}

enum DriverQueueConflict {
  activeOffer,
  notAvailable,
  noShortBreaksRemaining,
  noActiveOffer,
  notOnBreak,
  notOnExternalRide,
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

  /// Възстановява състояние, прочетено от постоянна база данни.
  ///
  /// За разлика от const конструктора тук проверките се изпълняват
  /// и в production режим.
  factory DriverQueueState.restore({
    required String driverId,
    required DateTime queuePrioritySince,
    required DriverQueueAvailability availability,
    required int shortBreaksUsed,
    required DateTime? breakStartedAt,
    required bool hasPendingOffer,
  }) {
    if (shortBreaksUsed < 0 || shortBreaksUsed > maxShortBreaksPerShift) {
      throw ArgumentError.value(
        shortBreaksUsed,
        'shortBreaksUsed',
        'Short breaks used must be between 0 and '
            '$maxShortBreaksPerShift.',
      );
    }

    final isOnBreak =
        availability == DriverQueueAvailability.shortBreak ||
        availability == DriverQueueAvailability.longBreak;

    if (isOnBreak && breakStartedAt == null) {
      throw ArgumentError('Break availability requires breakStartedAt.');
    }

    if (!isOnBreak && breakStartedAt != null) {
      throw ArgumentError('Non-break availability cannot have breakStartedAt.');
    }

    if (hasPendingOffer && availability != DriverQueueAvailability.available) {
      throw ArgumentError('Only an available driver can have a pending offer.');
    }

    return DriverQueueState(
      driverId: driverId,
      queuePrioritySince: queuePrioritySince,
      availability: availability,
      shortBreaksUsed: shortBreaksUsed,
      breakStartedAt: breakStartedAt,
      hasPendingOffer: hasPendingOffer,
    );
  }

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

  DriverQueueState acceptOffer() {
    _requirePendingOffer();

    return _copyWith(
      availability: DriverQueueAvailability.busy,
      hasPendingOffer: false,
    );
  }

  /// Шофьорът започва външен курс, когато няма активна City6 оферта.
  ///
  /// Това НЕ е почивка и няма автоматично връщане към available.
  DriverQueueState startExternalRide() {
    if (hasPendingOffer) {
      throw const DriverQueueConflictException(DriverQueueConflict.activeOffer);
    }

    if (availability != DriverQueueAvailability.available) {
      throw const DriverQueueConflictException(
        DriverQueueConflict.notAvailable,
      );
    }

    return _copyWith(availability: DriverQueueAvailability.externalRide);
  }

  /// Queue-side преходът при натискане на "Зает", докато има
  /// активна City6 оферта.
  ///
  /// Самата оферта трябва да бъде приключена атомарно от persistence
  /// слоя с отделна причина (becameBusy). Този метод само представя
  /// съответната промяна на queue state.
  DriverQueueState startExternalRideFromPendingOffer() {
    if (availability != DriverQueueAvailability.available) {
      throw const DriverQueueConflictException(
        DriverQueueConflict.notAvailable,
      );
    }

    _requirePendingOffer();

    return _copyWith(
      availability: DriverQueueAvailability.externalRide,
      hasPendingOffer: false,
    );
  }

  /// Външният курс приключва само когато шофьорът изрично се върне
  /// на "Свободен".
  ///
  /// При връщане той влиза отзад на опашката.
  DriverQueueState returnFromExternalRide(DateTime now) {
    if (availability != DriverQueueAvailability.externalRide) {
      throw const DriverQueueConflictException(
        DriverQueueConflict.notOnExternalRide,
      );
    }

    return _copyWith(
      availability: DriverQueueAvailability.available,
      queuePrioritySince: now,
    );
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
      case DriverQueueAvailability.busy:
      case DriverQueueAvailability.externalRide:
        throw const DriverQueueConflictException(
          DriverQueueConflict.notOnBreak,
        );
    }
  }

  /// При изтичане на 10-те минути късата почивка приключва
  /// автоматично. Старият queuePrioritySince се запазва.
  ///
  /// externalRide никога не приключва автоматично.
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
