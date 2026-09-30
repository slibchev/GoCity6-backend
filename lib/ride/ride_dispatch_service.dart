import '../dispatch/atomic_ride_reservation_repository.dart';
import '../dispatch/atomic_waiting_ride_acceptance_repository.dart';
import '../dispatch/driver_queue_state.dart';
import '../dispatch/driver_shift_repository.dart';
import '../routing/route_estimator.dart';
import 'ride_request.dart';
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
}

enum RideDispatchInputConflict {
  driverLocationRequired,
  invalidDriverLocation,
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

class RideDispatchService {
  final RideRequestRepository repository;

  final AtomicWaitingRideAcceptanceRepository?
      waitingRideAcceptanceRepository;

  final DriverShiftRepository? driverShiftRepository;

  final AtomicRideReservationRepository? rideReservationRepository;

  final RouteEstimator? routeEstimator;

  const RideDispatchService({
    required this.repository,
    this.waitingRideAcceptanceRepository,
    this.driverShiftRepository,
    this.rideReservationRepository,
    this.routeEstimator,
  });

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
        now: now,
      );
    }

    return _selectWaitingRideLegacy(
      ride: ride,
      driverId: driverId,
      vehicleId: vehicleId,
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
    final shift = await driverShiftRepository!.findActiveByDriverId(driverId);

    if (shift == null) {
      throw const RideDispatchConflictException(
        RideDispatchConflict.driverNotAvailable,
      );
    }

    switch (shift.queueState.availability) {
      case DriverQueueAvailability.available:
        if (waitingRideAcceptanceRepository == null) {
          throw StateError(
            'Atomic waiting ride acceptance repository is not configured.',
          );
        }

        return _acceptWaitingRideAtomically(
          rideId: ride.id,
          driverId: driverId,
        );

      case DriverQueueAvailability.busy:
        _requireReservationDependencies(
          reservationId: reservationId,
          now: now,
        );

        final location = _requireDriverLocation(
          latitude: driverLatitude,
          longitude: driverLongitude,
        );

        final driverRides =
            await repository.findByAssignedDriverId(driverId);

        final activeCurrentRides = driverRides
            .where(
              (existingRide) =>
                  existingRide.id != ride.id &&
                  existingRide.assignedVehicleId == shift.vehicleId &&
                  _isActiveCurrentRide(existingRide.status),
            )
            .toList();

        if (activeCurrentRides.length != 1) {
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
        );

      case DriverQueueAvailability.externalRide:
        _requireReservationDependencies(
          reservationId: reservationId,
          now: now,
        );

        final location = _requireDriverLocation(
          latitude: driverLatitude,
          longitude: driverLongitude,
        );

        final combinedEtaSeconds =
            await _calculateExternalCombinedEtaSeconds(
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
        );

      case DriverQueueAvailability.shortBreak:
      case DriverQueueAvailability.longBreak:
        throw const RideDispatchConflictException(
          RideDispatchConflict.driverNotAvailable,
        );
    }
  }

  Future<RideRequest> _selectWaitingRideLegacy({
    required RideRequest ride,
    required String driverId,
    required String vehicleId,
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
    final estimator = routeEstimator!;

    var totalSeconds = 0.0;

    RouteWaypoint origin = RouteWaypoint(
      latitude: driverLatitude,
      longitude: driverLongitude,
    );

    if (currentRide.status != RideRequestStatus.inProgress) {
      final toCurrentPickup = await estimator.estimate(
        origin: origin,
        destination: RouteWaypoint(address: currentRide.pickup),
      );

      totalSeconds += _requireFiniteDuration(toCurrentPickup);

      origin = _routeDestinationOrAddress(
        estimate: toCurrentPickup,
        fallbackAddress: currentRide.pickup,
      );
    }

    final toCurrentDestination = await estimator.estimate(
      origin: origin,
      destination: RouteWaypoint(address: currentRide.destination),
    );

    totalSeconds += _requireFiniteDuration(toCurrentDestination);

    origin = _routeDestinationOrAddress(
      estimate: toCurrentDestination,
      fallbackAddress: currentRide.destination,
    );

    final toNextPickup = await estimator.estimate(
      origin: origin,
      destination: RouteWaypoint(address: nextRide.pickup),
    );

    totalSeconds += _requireFiniteDuration(toNextPickup);

    return totalSeconds.ceil();
  }

  Future<int> _calculateExternalCombinedEtaSeconds({
    required RideRequest nextRide,
    required double driverLatitude,
    required double driverLongitude,
  }) async {
    final estimate = await routeEstimator!.estimate(
      origin: RouteWaypoint(
        latitude: driverLatitude,
        longitude: driverLongitude,
      ),
      destination: RouteWaypoint(address: nextRide.pickup),
    );

    return _requireFiniteDuration(estimate).ceil();
  }

  Future<RideRequest> _reserveWaitingRideAtomically({
    required RideRequest ride,
    required String driverId,
    required String reservationId,
    required int combinedEtaSeconds,
    required DateTime now,
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

        case AtomicRideReservationConflict.activeShiftNotFound:
        case AtomicRideReservationConflict.driverNotReservable:
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
      }
    }

    return ride.transitionTo(RideRequestStatus.reserved);
  }

  Future<RideRequest> _acceptWaitingRideAtomically({
    required String rideId,
    required String driverId,
  }) async {
    final atomicRepository = waitingRideAcceptanceRepository!;

    try {
      return await atomicRepository.acceptWaitingRide(
        rideId: rideId,
        driverId: driverId,
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
      throw StateError(
        'Ride reservation orchestration is not configured.',
      );
    }

    if (reservationId == null || reservationId.trim().isEmpty || now == null) {
      throw StateError(
        'Reservation id and current time are required for reservation.',
      );
    }
  }

  RouteWaypoint _routeDestinationOrAddress({
    required RouteEstimate estimate,
    required String fallbackAddress,
  }) {
    final latitude = estimate.destinationLatitude;
    final longitude = estimate.destinationLongitude;

    if (latitude != null && longitude != null) {
      return RouteWaypoint(
        latitude: latitude,
        longitude: longitude,
      );
    }

    return RouteWaypoint(address: fallbackAddress);
  }

  double _requireFiniteDuration(RouteEstimate estimate) {
    if (!estimate.durationSeconds.isFinite ||
        estimate.durationSeconds < 0) {
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
