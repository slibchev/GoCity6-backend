import '../ride/ride_request.dart';
import '../routing/route_estimator.dart';
import 'active_driver_shift.dart';
import 'dispatch_candidate.dart';
import 'driver_dispatch_state_repository.dart';
import 'driver_live_location.dart';
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

class DispatchCandidatePoolEntry {
  final ActiveDriverShift shift;
  final DriverQueueState queueState;
  final DriverLiveLocation location;

  const DispatchCandidatePoolEntry({
    required this.shift,
    required this.queueState,
    required this.location,
  });
}

class DispatchCandidatePool {
  final List<DispatchCandidatePoolEntry> entries;

  const DispatchCandidatePool({required this.entries});

  bool get isEmpty => entries.isEmpty;

  DispatchCandidatePool withoutDriver(String driverId) {
    return DispatchCandidatePool(
      entries: List.unmodifiable(
        entries.where((entry) => entry.shift.driverId != driverId),
      ),
    );
  }
}

class DispatchCandidateService {
  static const Duration defaultMaxLocationAge = Duration(seconds: 30);
  static const int _eligibilityConcurrency = 16;
  static const int _routeConcurrency = 12;

  final DriverShiftRepository shiftRepository;
  final DriverLiveLocationRepository liveLocationRepository;
  final DriverDispatchStateRepository? dispatchStateRepository;
  final RouteEstimator routeEstimator;
  final Duration maxLocationAge;

  const DispatchCandidateService({
    required this.shiftRepository,
    required this.liveLocationRepository,
    this.dispatchStateRepository,
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
    DispatchCandidatePool? pool,
  }) async {
    final nowUtc = now.toUtc();
    final eligiblePool = pool ?? await buildEligiblePool(now: nowUtc);

    if (eligiblePool.isEmpty) {
      return const DispatchCandidateBatch(candidates: [], driverStates: {});
    }

    final estimates = await _estimateRoutes(
      entries: eligiblePool.entries,
      destination: RouteWaypoint(address: ride.pickup),
    );
    final candidates = <DispatchCandidate>[];
    final driverStates = <String, DriverQueueState>{};

    for (var index = 0; index < eligiblePool.entries.length; index++) {
      final estimate = estimates[index];

      if (estimate == null) {
        continue;
      }

      final entry = eligiblePool.entries[index];
      final candidate = DispatchCandidate.fromQueueState(
        queueState: entry.queueState,
        vehicleId: entry.shift.vehicleId,
        etaSeconds: estimate.durationSeconds.round(),
        distanceMeters: estimate.distanceMeters.round(),
        now: nowUtc,
      );

      if (candidate != null) {
        candidates.add(candidate);
        driverStates[candidate.driverId] = entry.queueState;
      }
    }

    return DispatchCandidateBatch(
      candidates: List.unmodifiable(candidates),
      driverStates: Map.unmodifiable(driverStates),
    );
  }

  Future<DispatchCandidatePool> buildEligiblePool({
    required DateTime now,
  }) async {
    final nowUtc = now.toUtc();
    final shifts = await shiftRepository.findAllActive();
    final eligibleEntries = <DispatchCandidatePoolEntry>[];
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;

        if (index >= shifts.length) {
          return;
        }

        final shift = shifts[index];
        final queueState = shift.queueState.effectiveAt(nowUtc);

        if (queueState.availability != DriverQueueAvailability.available ||
            queueState.hasPendingOffer) {
          continue;
        }

        final dispatchState = dispatchStateRepository == null
            ? null
            : await dispatchStateRepository!.findByDriverId(shift.driverId);

        if (dispatchState?.isBlockedAt(nowUtc) ?? false) {
          continue;
        }

        final location = await liveLocationRepository.findByDriverId(
          shift.driverId,
        );

        if (location == null) {
          continue;
        }

        if (!_hasValidCoordinates(location)) {
          continue;
        }

        final locationAge = nowUtc.difference(location.updatedAt.toUtc());

        if (locationAge.isNegative || locationAge > maxLocationAge) {
          continue;
        }

        eligibleEntries.add(
          DispatchCandidatePoolEntry(
            shift: shift,
            queueState: queueState,
            location: location,
          ),
        );
      }
    }

    await Future.wait(
      List<Future<void>>.generate(_eligibilityConcurrency, (_) => worker()),
    );

    eligibleEntries.sort((a, b) {
      final queueOrder = a.queueState.queuePrioritySince.compareTo(
        b.queueState.queuePrioritySince,
      );

      if (queueOrder != 0) {
        return queueOrder;
      }

      return a.shift.driverId.compareTo(b.shift.driverId);
    });

    return DispatchCandidatePool(entries: List.unmodifiable(eligibleEntries));
  }

  Future<List<RouteEstimate?>> _estimateRoutes({
    required List<DispatchCandidatePoolEntry> entries,
    required RouteWaypoint destination,
  }) async {
    final origins = entries
        .map(
          (entry) => RouteWaypoint(
            latitude: entry.location.latitude,
            longitude: entry.location.longitude,
          ),
        )
        .toList(growable: false);

    if (routeEstimator is BatchRouteEstimator) {
      try {
        return await (routeEstimator as BatchRouteEstimator).estimateMany(
          origins: origins,
          destination: destination,
        );
      } on RouteWaypointResolutionException {
        rethrow;
      } on Exception {
        return List<RouteEstimate?>.filled(entries.length, null);
      }
    }

    final estimates = List<RouteEstimate?>.filled(entries.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;

        if (index >= entries.length) {
          return;
        }

        try {
          estimates[index] = await routeEstimator.estimate(
            origin: origins[index],
            destination: destination,
          );
        } on RouteWaypointResolutionException {
          rethrow;
        } on Exception {
          // A failed route estimate excludes only that driver.
        }
      }
    }

    await Future.wait(
      List<Future<void>>.generate(_routeConcurrency, (_) => worker()),
    );

    return estimates;
  }

  bool _hasValidCoordinates(DriverLiveLocation location) {
    return location.latitude.isFinite &&
        location.longitude.isFinite &&
        location.latitude >= -90 &&
        location.latitude <= 90 &&
        location.longitude >= -180 &&
        location.longitude <= 180;
  }
}
