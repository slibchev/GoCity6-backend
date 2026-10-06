import '../ride/ride_request.dart';
import '../routing/route_estimator.dart';
import 'dispatch_candidate.dart';
import 'driver_live_location_repository.dart';
import 'driver_queue_state.dart';
import 'driver_shift_repository.dart';

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
    final nowUtc = now.toUtc();
    final shifts = await shiftRepository.findAllActive();

    final candidates = <DispatchCandidate>[];

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

      final locationAge = nowUtc.difference(
        location.updatedAt.toUtc(),
      );

      if (locationAge.isNegative ||
          locationAge.compareTo(maxLocationAge) > 0) {
        continue;
      }

      final estimate = await routeEstimator.estimate(
        origin: RouteWaypoint(
          latitude: location.latitude,
          longitude: location.longitude,
        ),
        destination: RouteWaypoint(
          address: ride.pickup,
        ),
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
      }
    }

    return List.unmodifiable(candidates);
  }
}