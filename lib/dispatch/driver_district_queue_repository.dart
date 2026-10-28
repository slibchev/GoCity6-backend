import 'driver_district_queue.dart';

abstract interface class DriverDistrictQueueRepository {
  /// Records a trusted DistrictMatcher observation against the active shift.
  ///
  /// Implementations must serialize observations per active queue-state row
  /// and ignore an observation if it is no longer the latest persisted GPS
  /// location for that driver.
  Future<DriverDistrictObservationResult> observeLocation({
    required String driverId,
    required DateTime receivedAt,
    required DateTime? gpsFixAt,
    required bool gpsFixIsPlausible,
    required int? districtObjectId,
    required DriverDistrictTransitionPolicy policy,
  });

  /// Returns confirmed memberships in effective FIFO order.
  Future<List<DriverDistrictQueueEntry>> findByDistrictObjectId(
    int districtObjectId,
  );
}
