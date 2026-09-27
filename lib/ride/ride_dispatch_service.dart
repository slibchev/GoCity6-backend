import 'ride_request.dart';
import 'ride_request_repository.dart';
import 'ride_request_status.dart';

enum RideDispatchConflict {
  rideNotWaitingForVehicle,
  rideAlreadyAssigned,
  driverAlreadyHasReservedRide,
  driverStillHasActiveRide,
  rideNotReserved,
  rideAssignedToAnotherDriver,
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

class RideDispatchService {
  final RideRequestRepository repository;

  const RideDispatchService({required this.repository});

  Future<RideRequest> selectWaitingRide({
    required String rideId,
    required String driverId,
    required String vehicleId,
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

    final targetStatus = hasActiveRide
        ? RideRequestStatus.reserved
        : RideRequestStatus.accepted;

    if (repository is AtomicRideClaimRepository) {
      final atomicRepository = repository as AtomicRideClaimRepository;

      final claimedRide = await atomicRepository.claimWaitingRide(
        rideId: rideId,
        driverId: driverId,
        vehicleId: vehicleId,
        targetStatus: targetStatus,
      );

      if (claimedRide == null) {
        final latestRide = await repository.findById(rideId);

        if (latestRide == null) {
          throw RideNotFoundException(rideId);
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
