import 'driver_live_location.dart';

/// Confirmed membership in one district queue.
final class DriverDistrictQueueEntry {
  const DriverDistrictQueueEntry({
    required this.shiftId,
    required this.driverId,
    required this.districtObjectId,
    required this.enteredAt,
    required this.queuePrioritySince,
    this.lastObservedAt,
  });

  final String shiftId;
  final String driverId;
  final int districtObjectId;

  /// Backend time when the current district membership was confirmed.
  final DateTime enteredAt;

  /// Existing legacy priority, reset by established queue lifecycle events.
  final DateTime queuePrioritySince;

  /// Latest distinct GPS fix processed by the district queue.
  final DateTime? lastObservedAt;

  DateTime get fifoPriorityAt =>
      enteredAt.isAfter(queuePrioritySince) ? enteredAt : queuePrioritySince;
}

/// A currently eligible queue member, retaining the persisted FIFO position.
final class DriverDistrictQueueCandidate {
  const DriverDistrictQueueCandidate({
    required this.shiftId,
    required this.driverId,
    required this.vehicleId,
    required this.districtObjectId,
    required this.enteredAt,
    required this.fifoPriorityAt,
    required this.location,
  });

  final String shiftId;
  final String driverId;
  final String vehicleId;
  final int districtObjectId;
  final DateTime enteredAt;
  final DateTime fifoPriorityAt;
  final DriverLiveLocation location;
}

enum DriverDistrictObservationResult {
  confirmedTransition,
  alreadyInDistrict,
  awaitingConfirmation,
  outsideDistrictCoverage,
  invalidGpsFixTimestamp,
  staleObservation,
  noActiveShift,
}

/// Tunable GPS transition debounce policy. Observations must be distinct,
/// consecutive, and remain within [maxObservationGap].
final class DriverDistrictTransitionPolicy {
  const DriverDistrictTransitionPolicy({
    this.confirmationSamples = 3,
    this.minimumDwell = const Duration(seconds: 10),
    this.maxObservationGap = const Duration(seconds: 30),
  }) : assert(confirmationSamples >= 2);

  final int confirmationSamples;
  final Duration minimumDwell;
  final Duration maxObservationGap;
}

/// Persistable state for one driver's current shift.
///
/// A driver can have one confirmed district membership at a time. A different
/// match must pass the transition policy before replacing that membership.
final class DriverDistrictQueueMembership {
  const DriverDistrictQueueMembership({
    this.districtObjectId,
    this.enteredAt,
    this.lastObservedAt,
    this.pendingDistrictObjectId,
    this.pendingSince,
    this.pendingLastSeenAt,
    this.pendingObservations = 0,
  });

  final int? districtObjectId;
  final DateTime? enteredAt;
  final DateTime? lastObservedAt;
  final int? pendingDistrictObjectId;
  final DateTime? pendingSince;
  final DateTime? pendingLastSeenAt;
  final int pendingObservations;

  factory DriverDistrictQueueMembership.restore({
    required int? districtObjectId,
    required DateTime? enteredAt,
    DateTime? lastObservedAt,
    required int? pendingDistrictObjectId,
    required DateTime? pendingSince,
    required DateTime? pendingLastSeenAt,
    required int pendingObservations,
  }) {
    final hasConfirmedDistrict = districtObjectId != null;
    if (hasConfirmedDistrict != (enteredAt != null) ||
        (districtObjectId != null &&
            (districtObjectId <= 0 || lastObservedAt == null))) {
      throw const FormatException('Invalid confirmed district membership.');
    }

    final hasPendingDistrict = pendingDistrictObjectId != null;
    if (!hasPendingDistrict) {
      if (pendingSince != null ||
          pendingLastSeenAt != null ||
          pendingObservations != 0) {
        throw const FormatException('Invalid empty pending district state.');
      }
    } else if (pendingDistrictObjectId <= 0 ||
        pendingDistrictObjectId == districtObjectId ||
        pendingSince == null ||
        pendingLastSeenAt == null ||
        pendingLastSeenAt.isBefore(pendingSince) ||
        pendingObservations <= 0) {
      throw const FormatException('Invalid pending district state.');
    }
    if (pendingDistrictObjectId != null &&
        (lastObservedAt == null ||
            pendingLastSeenAt!.isAfter(lastObservedAt))) {
      throw const FormatException(
        'Pending district observation is newer than the stored observation.',
      );
    }

    return DriverDistrictQueueMembership(
      districtObjectId: districtObjectId,
      enteredAt: enteredAt?.toUtc(),
      lastObservedAt: lastObservedAt?.toUtc(),
      pendingDistrictObjectId: pendingDistrictObjectId,
      pendingSince: pendingSince?.toUtc(),
      pendingLastSeenAt: pendingLastSeenAt?.toUtc(),
      pendingObservations: pendingObservations,
    );
  }

  DriverDistrictMembershipTransition observe({
    required int? observedDistrictObjectId,
    required DateTime gpsFixAt,
    required DateTime confirmedAt,
    required DriverDistrictTransitionPolicy policy,
  }) {
    final fixAt = gpsFixAt.toUtc();
    final confirmationAt = confirmedAt.toUtc();

    if (policy.minimumDwell.isNegative ||
        policy.maxObservationGap <= Duration.zero ||
        policy.minimumDwell > policy.maxObservationGap ||
        policy.confirmationSamples < 2) {
      throw ArgumentError('Invalid district transition policy.');
    }

    if (observedDistrictObjectId != null && observedDistrictObjectId <= 0) {
      throw ArgumentError.value(
        observedDistrictObjectId,
        'observedDistrictObjectId',
        'District object ID must be positive.',
      );
    }

    if (lastObservedAt != null && !fixAt.isAfter(lastObservedAt!.toUtc())) {
      return DriverDistrictMembershipTransition(
        result: DriverDistrictObservationResult.staleObservation,
        membership: this,
      );
    }

    if (observedDistrictObjectId == null) {
      return DriverDistrictMembershipTransition(
        result: DriverDistrictObservationResult.outsideDistrictCoverage,
        membership: DriverDistrictQueueMembership(
          districtObjectId: districtObjectId,
          enteredAt: enteredAt,
          lastObservedAt: fixAt,
        ),
      );
    }

    final pendingDistrict = pendingDistrictObjectId;
    final pendingLastSeen = pendingLastSeenAt;
    final pendingStartedAt = pendingSince;
    if (pendingDistrict != null &&
        pendingLastSeen != null &&
        !fixAt.isAfter(pendingLastSeen)) {
      return DriverDistrictMembershipTransition(
        result: DriverDistrictObservationResult.staleObservation,
        membership: this,
      );
    }

    if (observedDistrictObjectId == districtObjectId) {
      return DriverDistrictMembershipTransition(
        result: DriverDistrictObservationResult.alreadyInDistrict,
        membership: DriverDistrictQueueMembership(
          districtObjectId: districtObjectId,
          enteredAt: enteredAt,
          lastObservedAt: fixAt,
        ),
      );
    }

    final pendingGap = pendingLastSeen == null
        ? null
        : fixAt.difference(pendingLastSeen);
    final pendingDuration = pendingStartedAt == null
        ? null
        : fixAt.difference(pendingStartedAt);
    final continuesPendingTransition =
        pendingDistrict == observedDistrictObjectId &&
        pendingGap != null &&
        !pendingGap.isNegative &&
        pendingGap <= policy.maxObservationGap &&
        pendingDuration != null &&
        !pendingDuration.isNegative &&
        pendingDuration <= policy.maxObservationGap;

    final since = continuesPendingTransition ? pendingStartedAt! : fixAt;
    final observations = continuesPendingTransition
        ? pendingObservations + 1
        : 1;

    if (observations >= policy.confirmationSamples &&
        fixAt.difference(since) >= policy.minimumDwell) {
      return DriverDistrictMembershipTransition(
        result: DriverDistrictObservationResult.confirmedTransition,
        membership: DriverDistrictQueueMembership(
          districtObjectId: observedDistrictObjectId,
          enteredAt: confirmationAt,
          lastObservedAt: fixAt,
        ),
      );
    }

    return DriverDistrictMembershipTransition(
      result: DriverDistrictObservationResult.awaitingConfirmation,
      membership: DriverDistrictQueueMembership(
        districtObjectId: districtObjectId,
        enteredAt: enteredAt,
        lastObservedAt: fixAt,
        pendingDistrictObjectId: observedDistrictObjectId,
        pendingSince: since,
        pendingLastSeenAt: fixAt,
        pendingObservations: observations,
      ),
    );
  }
}

final class DriverDistrictMembershipTransition {
  const DriverDistrictMembershipTransition({
    required this.result,
    required this.membership,
  });

  final DriverDistrictObservationResult result;
  final DriverDistrictQueueMembership membership;
}
