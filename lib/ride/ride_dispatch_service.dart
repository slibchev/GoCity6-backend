import '../dispatch/atomic_ride_reservation_repository.dart';
import '../dispatch/atomic_waiting_ride_acceptance_repository.dart';
import '../dispatch/driver_queue_state.dart';
import '../dispatch/driver_shift_repository.dart';
import '../dispatch/driver_live_location.dart';
import '../dispatch/driver_live_location_repository.dart';
import '../dispatch/driver_work_state_repository.dart';
import '../dispatch/active_driver_shift.dart';
import '../dispatch/external_ride_session.dart';
import '../dispatch/external_ride_session_repository.dart';
import '../routing/route_estimator.dart';
import 'ride_request.dart';
import 'ride_pickup_route_waypoint.dart';
import 'ride_request_repository.dart';
import 'ride_request_status.dart';

enum RideDispatchConflict {
  rideNotWaitingForVehicle,
  rideAlreadyAssigned,
  driverNotAvailable,
  driverAlreadyHasReservedRide,
  currentCity6RideNotFound,
  externalRideNotQualified,
  reservationEtaTooHigh,
  rideAlreadyReserved,
  vehicleAlreadyHasReservedRide,
  driverStillHasActiveRide,
  rideNotReserved,
  rideAssignedToAnotherDriver,
  rideTooOld,
  rideHasAutomaticOffer,
}

enum RideDispatchInputConflict {
  driverLocationRequired,
  invalidDriverLocation,
  driverLocationUnavailable,
}

class RideNotFoundException implements Exception {
  final String rideId;

  const RideNotFoundException(this.rideId);

  @override
  String toString() {
    return 'Ride not found: $rideId';
  }
}

class RideDispatchConflictException implements Exception {
  final RideDispatchConflict conflict;

  const RideDispatchConflictException(this.conflict);

  @override
  String toString() {
    return 'Ride dispatch conflict: ${conflict.name}';
  }
}

class RideDispatchInputException implements Exception {
  final RideDispatchInputConflict conflict;

  const RideDispatchInputException(this.conflict);

  @override
  String toString() {
    return 'Ride dispatch input conflict: ${conflict.name}';
  }
}

class WaitingRideSelectionAssessment {
  const WaitingRideSelectionAssessment({
    required this.canSelect,
    required this.combinedEtaSeconds,
    required this.reasonCode,
  });

  final bool canSelect;
  final int? combinedEtaSeconds;
  final String? reasonCode;

  Map<String, Object?> toJson() => {
    'canSelect': canSelect,
    'combinedEtaSeconds': combinedEtaSeconds,
    'reasonCode': reasonCode,
  };
}

final class _BusyRoutePrefix {
  const _BusyRoutePrefix({required this.seconds, required this.origin});

  final double seconds;
  final RouteWaypoint origin;
}

final class _WaitingRideContext {
  const _WaitingRideContext({
    required this.shift,
    required this.currentRide,
    required this.currentRideCount,
    required this.reservedRideExists,
    required this.pendingOffer,
    required this.breakScheduled,
    required this.location,
    required this.externalRideSession,
  });

  final ActiveDriverShift? shift;
  final RideRequest? currentRide;
  final int currentRideCount;
  final bool reservedRideExists;
  final bool pendingOffer;
  final bool breakScheduled;
  final DriverLiveLocation? location;
  final ExternalRideSession? externalRideSession;
}

class RideDispatchService {
  final RideRequestRepository repository;

  final AtomicWaitingRideAcceptanceRepository? waitingRideAcceptanceRepository;

  final DriverShiftRepository? driverShiftRepository;

  final AtomicRideReservationRepository? rideReservationRepository;

  final RouteEstimator? routeEstimator;

  final DriverWorkStateRepository? workStateRepository;

  final DriverLiveLocationRepository? liveLocationRepository;

  final ExternalRideSessionRepository? externalRideSessionRepository;

  final int maxWaitingRideEvaluations;

  final Duration routeEstimateTimeout;

  const RideDispatchService({
    required this.repository,
    this.waitingRideAcceptanceRepository,
    this.driverShiftRepository,
    this.rideReservationRepository,
    this.routeEstimator,
    this.workStateRepository,
    this.liveLocationRepository,
    this.externalRideSessionRepository,
    this.maxWaitingRideEvaluations = 25,
    this.routeEstimateTimeout = const Duration(seconds: 4),
  }) : assert(maxWaitingRideEvaluations > 0),
       assert(routeEstimateTimeout > Duration.zero);

  /// Evaluates the current waiting-board list for one authenticated driver.
  /// This is advisory only; the atomic repositories remain authoritative.
  Future<List<WaitingRideSelectionAssessment>> assessWaitingRides({
    required String driverId,
    required List<RideRequest> rides,
    DateTime? now,
  }) async {
    final nowUtc = (now ?? DateTime.now()).toUtc();
    final context = await _loadWaitingRideContext(driverId, nowUtc);
    final baseFailure = _contextFailure(context, nowUtc);
    final assessments = List<WaitingRideSelectionAssessment?>.filled(
      rides.length,
      null,
    );

    for (var i = 0; i < rides.length; i++) {
      final rideFailure = _rideFailure(rides[i], nowUtc);
      if (rideFailure != null) {
        assessments[i] = _notSelectable(rideFailure);
      } else if (baseFailure != null) {
        assessments[i] = _notSelectable(baseFailure);
      }
    }

    if (baseFailure != null || context.shift == null) {
      return List.unmodifiable(assessments.map((item) => item!));
    }

    final queueState = context.shift!.queueState.effectiveAt(nowUtc);
    if (queueState.availability == DriverQueueAvailability.available) {
      for (var i = 0; i < rides.length; i++) {
        assessments[i] ??= const WaitingRideSelectionAssessment(
          canSelect: true,
          combinedEtaSeconds: null,
          reasonCode: null,
        );
      }
      return List.unmodifiable(assessments.map((item) => item!));
    }

    final routeIndexes = <int>[];
    for (var i = 0; i < rides.length; i++) {
      if (assessments[i] == null) routeIndexes.add(i);
    }
    if (routeIndexes.isEmpty) {
      return List.unmodifiable(assessments.map((item) => item!));
    }
    if (routeIndexes.length > maxWaitingRideEvaluations) {
      for (final index in routeIndexes.skip(maxWaitingRideEvaluations)) {
        assessments[index] = _notSelectable('evaluation_deferred');
      }
      routeIndexes.removeRange(maxWaitingRideEvaluations, routeIndexes.length);
    }

    final location = context.location;
    if (location == null || !location.isReliableAt(nowUtc)) {
      for (final index in routeIndexes) {
        assessments[index] = _notSelectable('gps_unavailable');
      }
      return List.unmodifiable(assessments.map((item) => item!));
    }

    if (queueState.availability == DriverQueueAvailability.busy) {
      final currentRide = context.currentRide;
      if (currentRide == null) {
        for (final index in routeIndexes) {
          assessments[index] = _notSelectable('current_ride_unavailable');
        }
        return List.unmodifiable(assessments.map((item) => item!));
      }
      try {
        final prefix = await _prepareBusyRoutePrefix(
          currentRide: currentRide,
          driverLatitude: location.latitude,
          driverLongitude: location.longitude,
        );
        await _assessPickupRoutes(
          origin: prefix.origin,
          indexes: routeIndexes,
          rides: rides,
          prefixSeconds: prefix.seconds,
          assessments: assessments,
        );
      } catch (_) {
        for (final index in routeIndexes) {
          assessments[index] = _notSelectable('route_unavailable');
        }
      }
      return List.unmodifiable(assessments.map((item) => item!));
    }

    if (queueState.availability == DriverQueueAvailability.externalRide) {
      final session = context.externalRideSession;
      if (session == null || !session.qualifiesAsExternalRide) {
        for (final index in routeIndexes) {
          assessments[index] = _notSelectable('external_ride_not_qualified');
        }
        return List.unmodifiable(assessments.map((item) => item!));
      }
      await _assessPickupRoutes(
        origin: RouteWaypoint(
          latitude: location.latitude,
          longitude: location.longitude,
        ),
        indexes: routeIndexes,
        rides: rides,
        assessments: assessments,
      );
      return List.unmodifiable(assessments.map((item) => item!));
    }

    for (final index in routeIndexes) {
      assessments[index] = _notSelectable('driver_not_available');
    }
    return List.unmodifiable(assessments.map((item) => item!));
  }

  Future<_WaitingRideContext> _loadWaitingRideContext(
    String driverId,
    DateTime nowUtc,
  ) async {
    final snapshot = await workStateRepository?.loadByDriverId(driverId);
    final shift =
        snapshot?.activeShift ??
        (snapshot == null
            ? await driverShiftRepository?.findActiveByDriverId(driverId)
            : null);
    final assignedRides = snapshot == null && shift != null
        ? await repository.findByAssignedDriverId(driverId)
        : const <RideRequest>[];
    final activeRides = snapshot == null
        ? assignedRides
              .where((ride) => _isActiveCurrentRide(ride.status))
              .toList()
        : (snapshot.currentRide == null
              ? const <RideRequest>[]
              : [snapshot.currentRide!]);
    final currentRide =
        snapshot?.currentRide ??
        (activeRides.length == 1 ? activeRides.single : null);
    final currentRideCount = snapshot == null
        ? activeRides.length
        : (snapshot.currentRide == null ? 0 : 1);
    final reservedRideExists =
        snapshot?.reservedRide != null ||
        assignedRides.any((ride) => ride.status == RideRequestStatus.reserved);
    final pendingOffer =
        snapshot?.pendingOffer != null ||
        shift?.queueState.hasPendingOffer == true;
    final breakScheduled =
        snapshot?.pendingBreakRequestId != null ||
        snapshot?.pendingBreakKind != null;
    final availability = shift?.queueState.effectiveAt(nowUtc).availability;
    DriverLiveLocation? location;
    if (shift != null &&
        (availability == DriverQueueAvailability.busy ||
            availability == DriverQueueAvailability.externalRide)) {
      try {
        location = await liveLocationRepository?.findByDriverId(driverId);
      } catch (_) {
        location = null;
      }
    }

    ExternalRideSession? externalRideSession;
    if (availability == DriverQueueAvailability.externalRide) {
      try {
        externalRideSession = await externalRideSessionRepository
            ?.findActiveByDriverId(driverId);
      } catch (_) {
        externalRideSession = null;
      }
    }

    return _WaitingRideContext(
      shift: shift,
      currentRide: currentRide,
      currentRideCount: currentRideCount,
      reservedRideExists: reservedRideExists,
      pendingOffer: pendingOffer,
      breakScheduled: breakScheduled,
      location: location,
      externalRideSession: externalRideSession,
    );
  }

  String? _contextFailure(_WaitingRideContext context, DateTime nowUtc) {
    final shift = context.shift;
    if (shift == null) return 'no_active_shift';
    if (context.breakScheduled) return 'break_scheduled';
    if (context.pendingOffer) return 'pending_offer';
    if (context.reservedRideExists) return 'reserved_ride_exists';

    final availability = shift.queueState.effectiveAt(nowUtc).availability;
    if (availability == DriverQueueAvailability.shortBreak ||
        availability == DriverQueueAvailability.longBreak) {
      return 'driver_on_break';
    }
    if (availability == DriverQueueAvailability.busy) {
      final ride = context.currentRide;
      if (context.currentRideCount != 1 ||
          ride == null ||
          ride.assignedDriverId != shift.driverId ||
          ride.assignedVehicleId != shift.vehicleId ||
          !_isActiveCurrentRide(ride.status)) {
        return 'current_ride_unavailable';
      }
    } else if (availability == DriverQueueAvailability.available &&
        context.currentRideCount != 0) {
      return 'driver_state_mismatch';
    } else if (availability == DriverQueueAvailability.externalRide) {
      if (context.currentRideCount != 0) return 'driver_state_mismatch';
      final session = context.externalRideSession;
      if (session == null ||
          !session.isActive ||
          !session.qualifiesAsExternalRide) {
        return 'external_ride_not_qualified';
      }
    }
    return null;
  }

  String? _rideFailure(RideRequest ride, DateTime nowUtc) {
    if (ride.status != RideRequestStatus.waitingForVehicle) {
      return 'ride_not_waiting';
    }
    if (ride.assignedDriverId != null || ride.assignedVehicleId != null) {
      return 'ride_already_assigned';
    }
    if (!nowUtc.isBefore(
      ride.requestedAt.toUtc().add(const Duration(minutes: 30)),
    )) {
      return 'ride_expired';
    }
    return null;
  }

  WaitingRideSelectionAssessment _notSelectable(String reasonCode) =>
      WaitingRideSelectionAssessment(
        canSelect: false,
        combinedEtaSeconds: null,
        reasonCode: reasonCode,
      );

  WaitingRideSelectionAssessment _etaAssessment(int seconds) {
    final canSelect =
        seconds <= AtomicRideReservationRepository.maximumCombinedEtaSeconds;
    return WaitingRideSelectionAssessment(
      canSelect: canSelect,
      combinedEtaSeconds: seconds,
      reasonCode: canSelect ? null : 'combined_eta_too_high',
    );
  }

  Future<List<RouteEstimate?>> _estimateFinalLegs({
    required RouteWaypoint origin,
    required List<RouteWaypoint> destinations,
  }) async {
    final estimator = routeEstimator;
    if (estimator == null) return List.filled(destinations.length, null);
    if (estimator is MultiDestinationRouteEstimator) {
      return estimator
          .estimateToMany(origin: origin, destinations: destinations)
          .timeout(routeEstimateTimeout);
    }

    final estimates = List<RouteEstimate?>.filled(destinations.length, null);
    const concurrency = 4;
    for (var start = 0; start < destinations.length; start += concurrency) {
      final end = start + concurrency < destinations.length
          ? start + concurrency
          : destinations.length;
      await Future.wait(
        List<Future<void>>.generate(end - start, (offset) async {
          final index = start + offset;
          try {
            estimates[index] = await estimator
                .estimate(origin: origin, destination: destinations[index])
                .timeout(routeEstimateTimeout);
          } catch (_) {
            estimates[index] = null;
          }
        }),
      );
    }
    return estimates;
  }

  Future<void> _assessPickupRoutes({
    required RouteWaypoint origin,
    required List<int> indexes,
    required List<RideRequest> rides,
    required List<WaitingRideSelectionAssessment?> assessments,
    double prefixSeconds = 0,
  }) async {
    final destinationIndexes = <int>[];
    final destinations = <RouteWaypoint>[];
    for (final index in indexes) {
      try {
        final destination = ridePickupRouteWaypoint(rides[index]);
        destinationIndexes.add(index);
        destinations.add(destination);
      } catch (_) {
        assessments[index] = _notSelectable('route_unavailable');
      }
    }
    try {
      final estimates = await _estimateFinalLegs(
        origin: origin,
        destinations: destinations,
      );
      for (var offset = 0; offset < destinationIndexes.length; offset++) {
        final index = destinationIndexes[offset];
        final estimate = offset < estimates.length ? estimates[offset] : null;
        if (estimate == null ||
            !estimate.durationSeconds.isFinite ||
            estimate.durationSeconds < 0) {
          assessments[index] = _notSelectable('route_unavailable');
          continue;
        }
        assessments[index] = _etaAssessment(
          (prefixSeconds + estimate.durationSeconds).ceil(),
        );
      }
    } catch (_) {
      for (final index in destinationIndexes) {
        assessments[index] = _notSelectable('route_unavailable');
      }
    }
  }

  Future<RouteEstimate> _estimateRoute({
    required RouteWaypoint origin,
    required RouteWaypoint destination,
  }) {
    return routeEstimator!
        .estimate(origin: origin, destination: destination)
        .timeout(routeEstimateTimeout);
  }

  Future<RideRequest> selectWaitingRide({
    required String rideId,
    required String driverId,
    required String vehicleId,
    double? driverLatitude,
    double? driverLongitude,
    String? reservationId,
    DateTime? now,
  }) async {
    final ride = await _requireRide(rideId);

    final nowUtc = now?.toUtc();

    if (nowUtc != null &&
        !nowUtc.isBefore(
          ride.requestedAt.toUtc().add(const Duration(minutes: 30)),
        )) {
      throw const RideDispatchConflictException(
        RideDispatchConflict.rideTooOld,
      );
    }

    if (ride.status != RideRequestStatus.waitingForVehicle) {
      throw const RideDispatchConflictException(
        RideDispatchConflict.rideNotWaitingForVehicle,
      );
    }

    if (ride.assignedDriverId != null || ride.assignedVehicleId != null) {
      throw const RideDispatchConflictException(
        RideDispatchConflict.rideAlreadyAssigned,
      );
    }

    if (driverShiftRepository != null) {
      return _selectUsingQueueState(
        ride: ride,
        driverId: driverId,
        driverLatitude: driverLatitude,
        driverLongitude: driverLongitude,
        reservationId: reservationId,
        now: nowUtc,
      );
    }

    return _selectWaitingRideLegacy(
      ride: ride,
      driverId: driverId,
      vehicleId: vehicleId,
      now: nowUtc,
    );
  }

  Future<RideRequest> promoteReservedRide({
    required String rideId,
    required String driverId,
  }) async {
    final ride = await _requireRide(rideId);

    if (ride.status != RideRequestStatus.reserved) {
      throw const RideDispatchConflictException(
        RideDispatchConflict.rideNotReserved,
      );
    }

    if (ride.assignedDriverId != driverId) {
      throw const RideDispatchConflictException(
        RideDispatchConflict.rideAssignedToAnotherDriver,
      );
    }

    final driverRides = await repository.findByAssignedDriverId(driverId);

    final hasOtherActiveRide = driverRides.any(
      (existingRide) =>
          existingRide.id != ride.id &&
          _isActiveCurrentRide(existingRide.status),
    );

    if (hasOtherActiveRide) {
      throw const RideDispatchConflictException(
        RideDispatchConflict.driverStillHasActiveRide,
      );
    }

    final updatedRide = ride.transitionTo(RideRequestStatus.accepted);

    await repository.save(updatedRide);

    return updatedRide;
  }

  Future<RideRequest> _selectUsingQueueState({
    required RideRequest ride,
    required String driverId,
    required double? driverLatitude,
    required double? driverLongitude,
    required String? reservationId,
    required DateTime? now,
  }) async {
    final snapshot = await workStateRepository?.loadByDriverId(driverId);
    final shift =
        snapshot?.activeShift ??
        (snapshot == null
            ? await driverShiftRepository!.findActiveByDriverId(driverId)
            : null);

    if (shift == null) {
      throw const RideDispatchConflictException(
        RideDispatchConflict.driverNotAvailable,
      );
    }

    if (snapshot?.pendingBreakRequestId != null ||
        snapshot?.pendingBreakKind != null) {
      throw const RideDispatchConflictException(
        RideDispatchConflict.driverNotAvailable,
      );
    }
    if (snapshot?.reservedRide != null) {
      throw const RideDispatchConflictException(
        RideDispatchConflict.driverAlreadyHasReservedRide,
      );
    }
    if (snapshot?.pendingOffer != null || shift.queueState.hasPendingOffer) {
      throw const RideDispatchConflictException(
        RideDispatchConflict.driverNotAvailable,
      );
    }

    final nowUtc = (now ?? DateTime.now()).toUtc();
    switch (shift.queueState.effectiveAt(nowUtc).availability) {
      case DriverQueueAvailability.available:
        if (waitingRideAcceptanceRepository == null) {
          throw StateError(
            'Atomic waiting ride acceptance repository is not configured.',
          );
        }

        return _acceptWaitingRideAtomically(
          rideId: ride.id,
          driverId: driverId,
          now: now,
        );

      case DriverQueueAvailability.busy:
        _requireReservationDependencies(reservationId: reservationId, now: now);

        final expectedLocation = await _loadReservationLocation(
          driverId: driverId,
          now: nowUtc,
        );
        final location = _requireDriverLocation(
          latitude: expectedLocation?.latitude ?? driverLatitude,
          longitude: expectedLocation?.longitude ?? driverLongitude,
        );

        final activeCurrentRides = snapshot == null
            ? (await repository.findByAssignedDriverId(driverId))
                  .where(
                    (existingRide) =>
                        existingRide.id != ride.id &&
                        existingRide.assignedVehicleId == shift.vehicleId &&
                        _isActiveCurrentRide(existingRide.status),
                  )
                  .toList()
            : (snapshot.currentRide == null
                  ? <RideRequest>[]
                  : [snapshot.currentRide!]);

        if (activeCurrentRides.length != 1) {
          throw const RideDispatchConflictException(
            RideDispatchConflict.currentCity6RideNotFound,
          );
        }
        if (activeCurrentRides.single.assignedDriverId != driverId ||
            activeCurrentRides.single.assignedVehicleId != shift.vehicleId) {
          throw const RideDispatchConflictException(
            RideDispatchConflict.currentCity6RideNotFound,
          );
        }

        final combinedEtaSeconds = await _calculateBusyCombinedEtaSeconds(
          currentRide: activeCurrentRides.single,
          nextRide: ride,
          driverLatitude: location.$1,
          driverLongitude: location.$2,
        );

        return _reserveWaitingRideAtomically(
          ride: ride,
          driverId: driverId,
          reservationId: reservationId!,
          combinedEtaSeconds: combinedEtaSeconds,
          now: now!,
          expectedDriverLocation: expectedLocation,
          expectedCurrentRideId: activeCurrentRides.single.id,
        );

      case DriverQueueAvailability.externalRide:
        _requireReservationDependencies(reservationId: reservationId, now: now);

        final expectedLocation = await _loadReservationLocation(
          driverId: driverId,
          now: nowUtc,
        );
        final location = _requireDriverLocation(
          latitude: expectedLocation?.latitude ?? driverLatitude,
          longitude: expectedLocation?.longitude ?? driverLongitude,
        );

        final combinedEtaSeconds = await _calculateExternalCombinedEtaSeconds(
          nextRide: ride,
          driverLatitude: location.$1,
          driverLongitude: location.$2,
        );

        return _reserveWaitingRideAtomically(
          ride: ride,
          driverId: driverId,
          reservationId: reservationId!,
          combinedEtaSeconds: combinedEtaSeconds,
          now: now!,
          expectedDriverLocation: expectedLocation,
        );

      case DriverQueueAvailability.shortBreak:
      case DriverQueueAvailability.longBreak:
        throw const RideDispatchConflictException(
          RideDispatchConflict.driverNotAvailable,
        );
    }
  }

  Future<DriverLiveLocation?> _loadReservationLocation({
    required String driverId,
    required DateTime now,
  }) async {
    final locationRepository = liveLocationRepository;
    if (locationRepository == null) {
      if (workStateRepository != null) {
        throw const RideDispatchInputException(
          RideDispatchInputConflict.driverLocationUnavailable,
        );
      }
      return null;
    }

    final location = await locationRepository.findByDriverId(driverId);
    if (location == null || !location.isReliableAt(now)) {
      throw const RideDispatchInputException(
        RideDispatchInputConflict.driverLocationUnavailable,
      );
    }
    return location;
  }

  Future<RideRequest> _selectWaitingRideLegacy({
    required RideRequest ride,
    required String driverId,
    required String vehicleId,
    required DateTime? now,
  }) async {
    final driverRides = await repository.findByAssignedDriverId(driverId);

    final otherRides = driverRides.where(
      (existingRide) => existingRide.id != ride.id,
    );

    final hasReservedRide = otherRides.any(
      (existingRide) => existingRide.status == RideRequestStatus.reserved,
    );

    if (hasReservedRide) {
      throw const RideDispatchConflictException(
        RideDispatchConflict.driverAlreadyHasReservedRide,
      );
    }

    final hasActiveRide = otherRides.any(
      (existingRide) => _isActiveCurrentRide(existingRide.status),
    );

    if (!hasActiveRide && waitingRideAcceptanceRepository != null) {
      return _acceptWaitingRideAtomically(
        rideId: ride.id,
        driverId: driverId,
        now: now,
      );
    }

    final targetStatus = hasActiveRide
        ? RideRequestStatus.reserved
        : RideRequestStatus.accepted;

    if (repository is AtomicRideClaimRepository) {
      final atomicRepository = repository as AtomicRideClaimRepository;

      final claimedRide = await atomicRepository.claimWaitingRide(
        rideId: ride.id,
        driverId: driverId,
        vehicleId: vehicleId,
        targetStatus: targetStatus,
      );

      if (claimedRide == null) {
        final latestRide = await repository.findById(ride.id);

        if (latestRide == null) {
          throw RideNotFoundException(ride.id);
        }

        if (latestRide.status != RideRequestStatus.waitingForVehicle) {
          throw const RideDispatchConflictException(
            RideDispatchConflict.rideNotWaitingForVehicle,
          );
        }

        throw const RideDispatchConflictException(
          RideDispatchConflict.rideAlreadyAssigned,
        );
      }

      return claimedRide;
    }

    final updatedRide = ride
        .transitionTo(targetStatus)
        .copyWith(assignedDriverId: driverId, assignedVehicleId: vehicleId);

    await repository.save(updatedRide);

    return updatedRide;
  }

  Future<int> _calculateBusyCombinedEtaSeconds({
    required RideRequest currentRide,
    required RideRequest nextRide,
    required double driverLatitude,
    required double driverLongitude,
  }) async {
    final prefix = await _prepareBusyRoutePrefix(
      currentRide: currentRide,
      driverLatitude: driverLatitude,
      driverLongitude: driverLongitude,
    );
    final finalLeg = await _estimateRoute(
      origin: prefix.origin,
      destination: ridePickupRouteWaypoint(nextRide),
    );
    return (prefix.seconds + _requireFiniteDuration(finalLeg)).ceil();
  }

  Future<_BusyRoutePrefix> _prepareBusyRoutePrefix({
    required RideRequest currentRide,
    required double driverLatitude,
    required double driverLongitude,
  }) async {
    var totalSeconds = 0.0;
    RouteWaypoint origin = RouteWaypoint(
      latitude: driverLatitude,
      longitude: driverLongitude,
    );

    if (currentRide.status != RideRequestStatus.inProgress) {
      final currentPickup = ridePickupRouteWaypoint(currentRide);
      final toCurrentPickup = await _estimateRoute(
        origin: origin,
        destination: currentPickup,
      );
      totalSeconds += _requireFiniteDuration(toCurrentPickup);
      origin = _routeDestinationOrAddress(
        estimate: toCurrentPickup,
        fallbackWaypoint: currentPickup,
      );
    }

    final destination = RouteWaypoint(address: currentRide.destination);
    final toCurrentDestination = await _estimateRoute(
      origin: origin,
      destination: destination,
    );
    totalSeconds += _requireFiniteDuration(toCurrentDestination);
    origin = _routeDestinationOrAddress(
      estimate: toCurrentDestination,
      fallbackWaypoint: destination,
    );
    return _BusyRoutePrefix(seconds: totalSeconds, origin: origin);
  }

  Future<int> _calculateExternalCombinedEtaSeconds({
    required RideRequest nextRide,
    required double driverLatitude,
    required double driverLongitude,
  }) async {
    final estimate = await _estimateRoute(
      origin: RouteWaypoint(
        latitude: driverLatitude,
        longitude: driverLongitude,
      ),
      destination: ridePickupRouteWaypoint(nextRide),
    );

    return _requireFiniteDuration(estimate).ceil();
  }

  Future<RideRequest> _reserveWaitingRideAtomically({
    required RideRequest ride,
    required String driverId,
    required String reservationId,
    required int combinedEtaSeconds,
    required DateTime now,
    DriverLiveLocation? expectedDriverLocation,
    String? expectedCurrentRideId,
  }) async {
    if (combinedEtaSeconds >
        AtomicRideReservationRepository.maximumCombinedEtaSeconds) {
      throw const RideDispatchConflictException(
        RideDispatchConflict.reservationEtaTooHigh,
      );
    }

    try {
      await rideReservationRepository!.reserveWaitingRide(
        reservationId: reservationId,
        rideId: ride.id,
        driverId: driverId,
        combinedEtaSeconds: combinedEtaSeconds,
        now: now,
        expectedDriverLocation: expectedDriverLocation,
        expectedCurrentRideId: expectedCurrentRideId,
      );
    } on AtomicRideReservationConflictException catch (error) {
      switch (error.conflict) {
        case AtomicRideReservationConflict.rideNotFound:
          throw RideNotFoundException(ride.id);

        case AtomicRideReservationConflict.rideNotWaitingForVehicle:
          throw const RideDispatchConflictException(
            RideDispatchConflict.rideNotWaitingForVehicle,
          );

        case AtomicRideReservationConflict.rideAlreadyAssigned:
          throw const RideDispatchConflictException(
            RideDispatchConflict.rideAlreadyAssigned,
          );

        case AtomicRideReservationConflict.rideTooOld:
          throw const RideDispatchConflictException(
            RideDispatchConflict.rideTooOld,
          );

        case AtomicRideReservationConflict.activeAutomaticOffer:
          throw const RideDispatchConflictException(
            RideDispatchConflict.rideHasAutomaticOffer,
          );

        case AtomicRideReservationConflict.activeShiftNotFound:
        case AtomicRideReservationConflict.driverNotReservable:
        case AtomicRideReservationConflict.driverBreakScheduled:
        case AtomicRideReservationConflict.queueStateMismatch:
        case AtomicRideReservationConflict.activeExternalRideNotFound:
          throw const RideDispatchConflictException(
            RideDispatchConflict.driverNotAvailable,
          );

        case AtomicRideReservationConflict.currentCity6RideNotFound:
          throw const RideDispatchConflictException(
            RideDispatchConflict.currentCity6RideNotFound,
          );

        case AtomicRideReservationConflict.externalRideNotQualified:
          throw const RideDispatchConflictException(
            RideDispatchConflict.externalRideNotQualified,
          );

        case AtomicRideReservationConflict.etaTooHigh:
          throw const RideDispatchConflictException(
            RideDispatchConflict.reservationEtaTooHigh,
          );

        case AtomicRideReservationConflict.rideAlreadyReserved:
          throw const RideDispatchConflictException(
            RideDispatchConflict.rideAlreadyReserved,
          );

        case AtomicRideReservationConflict.driverAlreadyHasReservedRide:
          throw const RideDispatchConflictException(
            RideDispatchConflict.driverAlreadyHasReservedRide,
          );

        case AtomicRideReservationConflict.vehicleAlreadyHasReservedRide:
          throw const RideDispatchConflictException(
            RideDispatchConflict.vehicleAlreadyHasReservedRide,
          );

        case AtomicRideReservationConflict.driverLocationUnavailable:
          throw const RideDispatchInputException(
            RideDispatchInputConflict.driverLocationUnavailable,
          );

        case AtomicRideReservationConflict.currentRideChanged:
          throw const RideDispatchConflictException(
            RideDispatchConflict.currentCity6RideNotFound,
          );
      }
    }

    return ride.transitionTo(RideRequestStatus.reserved);
  }

  Future<RideRequest> _acceptWaitingRideAtomically({
    required String rideId,
    required String driverId,
    required DateTime? now,
  }) async {
    final atomicRepository = waitingRideAcceptanceRepository!;

    try {
      return await atomicRepository.acceptWaitingRide(
        rideId: rideId,
        driverId: driverId,
        now: now,
      );
    } on AtomicWaitingRideAcceptanceConflictException catch (error) {
      switch (error.conflict) {
        case AtomicWaitingRideAcceptanceConflict.rideNotFound:
          throw RideNotFoundException(rideId);

        case AtomicWaitingRideAcceptanceConflict.rideNotWaitingForVehicle:
          throw const RideDispatchConflictException(
            RideDispatchConflict.rideNotWaitingForVehicle,
          );

        case AtomicWaitingRideAcceptanceConflict.rideAlreadyAssigned:
          throw const RideDispatchConflictException(
            RideDispatchConflict.rideAlreadyAssigned,
          );

        case AtomicWaitingRideAcceptanceConflict.rideTooOld:
          throw const RideDispatchConflictException(
            RideDispatchConflict.rideTooOld,
          );

        case AtomicWaitingRideAcceptanceConflict.activeAutomaticOffer:
          throw const RideDispatchConflictException(
            RideDispatchConflict.rideHasAutomaticOffer,
          );

        case AtomicWaitingRideAcceptanceConflict.activeShiftNotFound:
        case AtomicWaitingRideAcceptanceConflict.driverNotAvailable:
        case AtomicWaitingRideAcceptanceConflict.pendingOfferExists:
        case AtomicWaitingRideAcceptanceConflict.queueStateMismatch:
          throw const RideDispatchConflictException(
            RideDispatchConflict.driverNotAvailable,
          );
      }
    }
  }

  (double, double) _requireDriverLocation({
    required double? latitude,
    required double? longitude,
  }) {
    if (latitude == null || longitude == null) {
      throw const RideDispatchInputException(
        RideDispatchInputConflict.driverLocationRequired,
      );
    }

    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw const RideDispatchInputException(
        RideDispatchInputConflict.invalidDriverLocation,
      );
    }

    return (latitude, longitude);
  }

  void _requireReservationDependencies({
    required String? reservationId,
    required DateTime? now,
  }) {
    if (rideReservationRepository == null || routeEstimator == null) {
      throw StateError('Ride reservation orchestration is not configured.');
    }

    if (reservationId == null || reservationId.trim().isEmpty || now == null) {
      throw StateError(
        'Reservation id and current time are required for reservation.',
      );
    }
  }

  RouteWaypoint _routeDestinationOrAddress({
    required RouteEstimate estimate,
    required RouteWaypoint fallbackWaypoint,
  }) {
    final latitude = estimate.destinationLatitude;
    final longitude = estimate.destinationLongitude;

    if (latitude != null && longitude != null) {
      return RouteWaypoint(latitude: latitude, longitude: longitude);
    }

    return fallbackWaypoint;
  }

  double _requireFiniteDuration(RouteEstimate estimate) {
    if (!estimate.durationSeconds.isFinite || estimate.durationSeconds < 0) {
      throw StateError('Route estimate has an invalid duration.');
    }

    return estimate.durationSeconds;
  }

  Future<RideRequest> _requireRide(String rideId) async {
    final ride = await repository.findById(rideId);

    if (ride == null) {
      throw RideNotFoundException(rideId);
    }

    return ride;
  }

  bool _isActiveCurrentRide(RideRequestStatus status) {
    return status == RideRequestStatus.accepted ||
        status == RideRequestStatus.driverArriving ||
        status == RideRequestStatus.inProgress;
  }
}
