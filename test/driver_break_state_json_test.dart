import 'package:gocity6_backend/dispatch/driver_break_state_json.dart';
import 'package:gocity6_backend/dispatch/driver_queue_state.dart';
import 'package:test/test.dart';

void main() {
  final startedAt = DateTime.utc(2026, 10, 28, 10);
  final priority = DateTime.utc(2026, 10, 28, 8);

  test('short break reports UTC expiry, remaining time and allowance', () {
    final state = DriverQueueState(
      driverId: 'driver-001',
      queuePrioritySince: priority,
      availability: DriverQueueAvailability.shortBreak,
      shortBreaksUsed: 2,
      breakStartedAt: startedAt,
    );

    final result = driverBreakStateJson(
      state,
      now: startedAt.add(const Duration(minutes: 4, seconds: 20)),
    );

    expect(result['mode'], 'short');
    expect(result['startedAt'], '2026-10-28T10:00:00.000Z');
    expect(result['expiresAt'], '2026-10-28T10:10:00.000Z');
    expect(result['remainingSeconds'], 340);
    expect(result['shortBreaksUsed'], 2);
    expect(result['shortBreaksRemaining'], 1);
    expect(result['maxShortBreaksPerShift'], 3);
  });

  test('long break has no expiry and does not consume short allowance', () {
    final state = DriverQueueState(
      driverId: 'driver-001',
      queuePrioritySince: priority,
      availability: DriverQueueAvailability.longBreak,
      shortBreaksUsed: 1,
      breakStartedAt: startedAt,
    );

    final result = driverBreakStateJson(state, now: startedAt);

    expect(result['mode'], 'long');
    expect(result['startedAt'], '2026-10-28T10:00:00.000Z');
    expect(result['expiresAt'], isNull);
    expect(result['remainingSeconds'], isNull);
    expect(result['shortBreaksUsed'], 1);
    expect(result['shortBreaksRemaining'], 2);
  });

  test('available queue reports no active break', () {
    final state = DriverQueueState(
      driverId: 'driver-001',
      queuePrioritySince: priority,
    );

    final result = driverBreakStateJson(state, now: startedAt);

    expect(result['mode'], 'none');
    expect(result['startedAt'], isNull);
    expect(result['expiresAt'], isNull);
    expect(result['remainingSeconds'], isNull);
  });

  test('pending break exposes durable request and after-ride activation', () {
    final result = pendingDriverBreakStateJson(
      kind: 'short',
      requestId: 'c6cbb0dd-67b8-4e0a-9066-62f8c4cba3be',
      requestedAt: DateTime.parse('2026-10-28T10:00:00+03:00'),
    );

    expect(result, {
      'kind': 'short',
      'status': 'pending',
      'activation': 'afterCurrentRide',
      'requestId': 'c6cbb0dd-67b8-4e0a-9066-62f8c4cba3be',
      'requestedAt': '2026-10-28T07:00:00.000Z',
    });
    expect(
      pendingDriverBreakStateJson(
        kind: null,
        requestId: null,
        requestedAt: null,
      ),
      isNull,
    );
  });
}
