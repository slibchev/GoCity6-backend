import '../ride/ride_request.dart';
import '../routing/route_estimator.dart';
import 'dispatch_candidate.dart';
import 'driver_live_location_repository.dart';
import 'driver_queue_state.dart';
import 'driver_shift_repository.dart';

class DispatchCandidateBatch {
  final List<DispatchCandidate> candidates;
  final Map<String, DriverQueueState> driverStates;

  const DispatchCandidateBatch({
    required this.candidates,
    required this.driverStates,
  });
}

class DispatchCandidateService {
  static const Duration defaultMaxLocationAge = Duration(seconds: 30);

  final DriverShiftRepository shiftRepository;
  final DriverLiveLocationRepository liveLocationRepository;
  final RouteEstimator routeEstimator;
  final Duration maxLocationAge;

  const DispatchCandidateService({
    required this.shiftRepository,
    required this.liveLocationRepository,
    required this.routeEstimator,
    this.maxLocationAge = defaultMaxLocationAge,
  });

  Future<List<DispatchCandidate>> buildForRide({
    required RideRequest ride,
    required DateTime now,
  }) async {
    final batch = await buildBatchForRide(ride: ride, now: now);

    return batch.candidates;
  }

  Future<DispatchCandidateBatch> buildBatchForRide({
    required RideRequest ride,
    required DateTime now,
  }) async {
    final nowUtc = now.toUtc();
    final shifts = await shiftRepository.findAllActive();

    final candidates = <DispatchCandidate>[];
    final driverStates = <String, DriverQueueState>{};

    for (final shift in shifts) {
      final queueState = shift.queueState.effectiveAt(nowUtc);

      if (queueState.availability != DriverQueueAvailability.available ||
          queueState.hasPendingOffer) {
        continue;
      }

      final location = await liveLocationRepository.findByDriverId(
        shift.driverId,
      );

      if (location == null) {
        continue;
      }

      final locationAge = nowUtc.difference(location.updatedAt.toUtc());

      if (locationAge.isNegative || locationAge.compareTo(maxLocationAge) > 0) {
        continue;
      }

      final estimate = await routeEstimator.estimate(
        origin: RouteWaypoint(
          latitude: location.latitude,
          longitude: location.longitude,
        ),
        destination: RouteWaypoint(address: ride.pickup),
      );

      final candidate = DispatchCandidate.fromQueueState(
        queueState: queueState,
        vehicleId: shift.vehicleId,
        etaSeconds: estimate.durationSeconds.round(),
        distanceMeters: estimate.distanceMeters.round(),
        now: nowUtc,
      );

      if (candidate != null) {
        candidates.add(candidate);
        driverStates[candidate.driverId] = queueState;
      }
    }

    return DispatchCandidateBatch(
      candidates: List.unmodifiable(candidates),
      driverStates: Map.unmodifiable(driverStates),
    );
  }
}
