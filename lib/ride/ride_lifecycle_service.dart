import 'ride_request.dart';
import 'ride_request_repository.dart';
import 'ride_request_status.dart';

enum RideLifecycleConflict {
  rideAlreadyExists,
  rideMustBePending,
  rideHasAssignment,
  rideHasCompletionData,
  rideCannotBeCancelled,
  rideMustBeReserved,
  rideAssignedToAnotherDriver,
  rideMustBeAccepted,
  rideMustBeDriverArriving,
}

class RideLifecycleNotFoundException implements Exception {
  final String rideId;

  const RideLifecycleNotFoundException(this.rideId);

  @override
  String toString() {
    return 'Ride not found: $rideId';
  }
}

class RideLifecycleConflictException implements Exception {
  final RideLifecycleConflict conflict;

  const RideLifecycleConflictException(this.conflict);

  @override
  String toString() {
    return 'Ride lifecycle conflict: ${conflict.name}';
  }
}

class RideLifecycleService {
  final RideRequestRepository repository;

  const RideLifecycleService({required this.repository});

  Future<RideRequest> submitRide(RideRequest request) async {
    final existingRide = await repository.findById(request.id);

    if (existingRide != null) {
      throw const RideLifecycleConflictException(
        RideLifecycleConflict.rideAlreadyExists,
      );
    }

    if (request.status != RideRequestStatus.pending) {
      throw const RideLifecycleConflictException(
        RideLifecycleConflict.rideMustBePending,
      );
    }

    if (request.assignedDriverId != null || request.assignedVehicleId != null) {
      throw const RideLifecycleConflictException(
        RideLifecycleConflict.rideHasAssignment,
      );
    }

    if (request.completedByDriverId != null || request.completedAt != null) {
      throw const RideLifecycleConflictException(
        RideLifecycleConflict.rideHasCompletionData,
      );
    }

    final submittedRide = request.transitionTo(
      RideRequestStatus.waitingForVehicle,
    );

    await repository.save(submittedRide);

    return submittedRide;
  }

  Future<RideRequest> getRide(String rideId) {
    return _requireRide(rideId);
  }

  Future<RideRequest> cancelRide(String rideId) async {
    final ride = await _requireRide(rideId);

    if (!ride.status.canBeCancelled) {
      throw const RideLifecycleConflictException(
        RideLifecycleConflict.rideCannotBeCancelled,
      );
    }

    final cancelledRide = ride.transitionTo(RideRequestStatus.cancelled);

    await repository.save(cancelledRide);

    return cancelledRide;
  }

  Future<RideRequest> releaseReservedRide({
    required String rideId,
    required String driverId,
  }) async {
    final ride = await _requireRide(rideId);

    if (ride.status != RideRequestStatus.reserved) {
      throw const RideLifecycleConflictException(
        RideLifecycleConflict.rideMustBeReserved,
      );
    }

    _requireAssignedDriver(ride: ride, driverId: driverId);

    final releasedRide = ride
        .transitionTo(RideRequestStatus.waitingForVehicle)
        .copyWith(assignedDriverId: null, assignedVehicleId: null);

    await repository.save(releasedRide);

    return releasedRide;
  }

  Future<RideRequest> markDriverArriving({
    required String rideId,
    required String driverId,
  }) async {
    final ride = await _requireRide(rideId);

    if (ride.status != RideRequestStatus.accepted) {
      throw const RideLifecycleConflictException(
        RideLifecycleConflict.rideMustBeAccepted,
      );
    }

    _requireAssignedDriver(ride: ride, driverId: driverId);

    final updatedRide = ride.transitionTo(RideRequestStatus.driverArriving);

    await repository.save(updatedRide);

    return updatedRide;
  }

  Future<RideRequest> startRide({
    required String rideId,
    required String driverId,
  }) async {
    final ride = await _requireRide(rideId);

    if (ride.status != RideRequestStatus.driverArriving) {
      throw const RideLifecycleConflictException(
        RideLifecycleConflict.rideMustBeDriverArriving,
      );
    }

    _requireAssignedDriver(ride: ride, driverId: driverId);

    final updatedRide = ride.transitionTo(RideRequestStatus.inProgress);

    await repository.save(updatedRide);

    return updatedRide;
  }

  Future<RideRequest> _requireRide(String rideId) async {
    final ride = await repository.findById(rideId);

    if (ride == null) {
      throw RideLifecycleNotFoundException(rideId);
    }

    return ride;
  }

  void _requireAssignedDriver({
    required RideRequest ride,
    required String driverId,
  }) {
    if (ride.assignedDriverId != driverId) {
      throw const RideLifecycleConflictException(
        RideLifecycleConflict.rideAssignedToAnotherDriver,
      );
    }
  }
}
