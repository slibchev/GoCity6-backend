import '../geography/district_matcher.dart';
import 'active_driver_shift.dart';
import 'dispatch_candidate_service.dart';
import 'driver_district_queue.dart';
import 'driver_district_queue_repository.dart';
import 'driver_dispatch_state_repository.dart';
import 'driver_live_location.dart';
import 'driver_live_location_repository.dart';
import 'driver_queue_state.dart';
import 'driver_shift_repository.dart';

final class DriverDistrictQueueService {
  static const Duration defaultMaxLocationAge =
      DispatchCandidateService.defaultMaxLocationAge;
  static const Duration defaultMaxGpsFixAge = Duration(seconds: 15);
  static const Duration defaultGpsFutureSkew = Duration(seconds: 5);

  const DriverDistrictQueueService({
    required this.districtMatcher,
    required this.repository,
    required this.shiftRepository,
    required this.liveLocationRepository,
    required this.dispatchStateRepository,
    this.transitionPolicy = const DriverDistrictTransitionPolicy(),
    this.maxLocationAge = defaultMaxLocationAge,
    this.maxGpsFixAge = defaultMaxGpsFixAge,
    this.gpsFutureSkew = defaultGpsFutureSkew,
  });

  final DistrictMatcher districtMatcher;
  final DriverDistrictQueueRepository repository;
  final DriverShiftRepository shiftRepository;
  final DriverLiveLocationRepository liveLocationRepository;
  final DriverDispatchStateRepository dispatchStateRepository;
  final DriverDistrictTransitionPolicy transitionPolicy;
  final Duration maxLocationAge;
  final Duration maxGpsFixAge;
  final Duration gpsFutureSkew;

  Future<DriverDistrictObservationResult> observeLocation({
    required DriverLiveLocation location,
    required DistrictMatch? match,
  }) {
    if (match != null &&
        !districtMatcher.containsObjectId(match.district.objectId)) {
      throw ArgumentError('District match is not from the approved map.');
    }

    final gpsFixAt = location.gpsFixAt?.toUtc();
    final receivedAt = location.updatedAt.toUtc();
    final gpsFixIsPlausible = _isPlausibleGpsFix(
      gpsFixAt: gpsFixAt,
      referenceAt: receivedAt,
    );

    return repository.observeLocation(
      driverId: location.driverId,
      receivedAt: receivedAt,
      gpsFixAt: gpsFixAt,
      gpsFixIsPlausible: gpsFixIsPlausible,
      districtObjectId: match?.district.objectId,
      policy: transitionPolicy,
    );
  }

  /// Returns eligible members without route estimates or distance ordering.
  /// The database membership is the FIFO source; filtering preserves that
  /// order. Dispatch must revalidate eligibility atomically before offering.
  Future<List<DriverDistrictQueueCandidate>> findAvailableDrivers({
    required int districtObjectId,
    required DateTime now,
  }) async {
    if (!districtMatcher.containsObjectId(districtObjectId)) {
      throw ArgumentError.value(
        districtObjectId,
        'districtObjectId',
        'District is not in the approved City6 map.',
      );
    }

    final nowUtc = now.toUtc();
    final entries = await repository.findByDistrictObjectId(districtObjectId);
    if (entries.isEmpty) return const [];

    final activeShifts = await shiftRepository.findAllActive();
    final shiftsById = <String, ActiveDriverShift>{
      for (final shift in activeShifts) shift.id: shift,
    };
    final candidates = <DriverDistrictQueueCandidate>[];

    for (final entry in entries) {
      if (entry.districtObjectId != districtObjectId ||
          entry.enteredAt.isAfter(nowUtc) ||
          entry.fifoPriorityAt.isAfter(nowUtc)) {
        continue;
      }
      final shift = shiftsById[entry.shiftId];
      if (shift == null || shift.driverId != entry.driverId) continue;

      final queueState = shift.queueState.effectiveAt(nowUtc);
      if (queueState.availability != DriverQueueAvailability.available ||
          queueState.hasPendingOffer) {
        continue;
      }

      final dispatchState = await dispatchStateRepository.findByDriverId(
        shift.driverId,
      );
      if (dispatchState?.isBlockedAt(nowUtc) ?? false) continue;

      final location = await liveLocationRepository.findByDriverId(
        shift.driverId,
      );
      if (location == null ||
          !_isFreshAndValid(location, nowUtc) ||
          !_isPlausibleGpsFix(
            gpsFixAt: location.gpsFixAt,
            referenceAt: nowUtc,
          ) ||
          (entry.lastObservedAt != null &&
              location.gpsFixAt!.isBefore(entry.lastObservedAt!))) {
        continue;
      }

      // A GPS point outside every approved polygon is never a queue
      // candidate. During a pending transition, a matched point remains in
      // the previously confirmed queue until the transition is confirmed.
      if (districtMatcher.match(
            latitude: location.latitude,
            longitude: location.longitude,
          ) ==
          null) {
        continue;
      }

      candidates.add(
        DriverDistrictQueueCandidate(
          shiftId: shift.id,
          driverId: shift.driverId,
          vehicleId: shift.vehicleId,
          districtObjectId: districtObjectId,
          enteredAt: entry.enteredAt.toUtc(),
          fifoPriorityAt: entry.fifoPriorityAt.toUtc(),
          location: location,
        ),
      );
    }

    candidates.sort((a, b) {
      final rankOrder = a.fifoPriorityAt.compareTo(b.fifoPriorityAt);
      return rankOrder != 0 ? rankOrder : a.driverId.compareTo(b.driverId);
    });
    return List.unmodifiable(candidates);
  }

  bool _isFreshAndValid(DriverLiveLocation location, DateTime nowUtc) {
    if (!location.latitude.isFinite ||
        !location.longitude.isFinite ||
        location.latitude < -90 ||
        location.latitude > 90 ||
        location.longitude < -180 ||
        location.longitude > 180) {
      return false;
    }
    final age = nowUtc.difference(location.updatedAt.toUtc());
    return !age.isNegative && age <= maxLocationAge;
  }

  bool _isPlausibleGpsFix({
    required DateTime? gpsFixAt,
    required DateTime referenceAt,
  }) {
    if (gpsFixAt == null ||
        maxGpsFixAge.isNegative ||
        gpsFutureSkew.isNegative) {
      return false;
    }

    final age = referenceAt.toUtc().difference(gpsFixAt.toUtc());
    return age >= -gpsFutureSkew && age <= maxGpsFixAge;
  }
}

/// Parses the Driver App's actual Geolocator fix timestamp.
///
/// The API contract requires an ISO-8601 UTC string ending in `Z`; timestamps
/// with local offsets or no timezone are intentionally rejected.
DateTime? parseDriverGpsFixTimestamp(Object? value) {
  if (value is! String) {
    return null;
  }

  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?Z$',
  ).firstMatch(value);
  if (match == null) return null;

  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final hour = int.parse(match[4]!);
  final minute = int.parse(match[5]!);
  final second = int.parse(match[6]!);
  final fraction = (match[7] ?? '').padRight(6, '0');
  final parsed = DateTime.utc(
    year,
    month,
    day,
    hour,
    minute,
    second,
    int.parse(fraction.substring(0, 3)),
    int.parse(fraction.substring(3, 6)),
  );

  // DateTime normalizes overflow values (for example day 32); reject them.
  if (parsed.year != year ||
      parsed.month != month ||
      parsed.day != day ||
      parsed.hour != hour ||
      parsed.minute != minute ||
      parsed.second != second) {
    return null;
  }
  return parsed;
}
