import 'package:gocity6_backend/ride/waiting_ride_expiration_repository.dart';
import 'package:gocity6_backend/ride/waiting_ride_expiration_service.dart';
import 'package:test/test.dart';

void main() {
  test('cancels a batch before settling related outbox work', () async {
    final repository = _FakeExpirationRepository(
      batches: [
        const WaitingRideExpirationBatch(
          cancelledRideIds: ['ride-expired'],
          expiredOfferCount: 1,
        ),
      ],
      outboxCounts: [1],
    );
    final service = WaitingRideExpirationService(
      repository: repository,
      batchSize: 23,
    );

    final result = await service.processDueRides();

    expect(repository.calls, ['cancel:23', 'outbox:23']);
    expect(result.cancelledRideCount, 1);
    expect(result.expiredOfferCount, 1);
    expect(result.settledOutboxCount, 1);
    expect(result.didWork, isTrue);
  });

  test('repeated scan is idle after no due work remains', () async {
    final repository = _FakeExpirationRepository(
      batches: [
        const WaitingRideExpirationBatch(
          cancelledRideIds: [],
          expiredOfferCount: 0,
        ),
      ],
      outboxCounts: [0],
    );
    final service = WaitingRideExpirationService(repository: repository);

    final result = await service.processDueRides();

    expect(result.didWork, isFalse);
    expect(repository.calls, ['cancel:100', 'outbox:100']);
  });

  test(
    'a new service instance recovers outbox settlement after interruption',
    () async {
      final repository = _FakeExpirationRepository(
        batches: [
          const WaitingRideExpirationBatch(
            cancelledRideIds: ['ride-expired'],
            expiredOfferCount: 1,
          ),
          const WaitingRideExpirationBatch(
            cancelledRideIds: [],
            expiredOfferCount: 0,
          ),
        ],
        outboxCounts: [1],
        outboxFailuresRemaining: 1,
      );

      await expectLater(
        WaitingRideExpirationService(repository: repository).processDueRides(),
        throwsStateError,
      );

      final afterRestart = await WaitingRideExpirationService(
        repository: repository,
      ).processDueRides();

      expect(afterRestart.cancelledRideCount, 0);
      expect(afterRestart.settledOutboxCount, 1);
      expect(repository.calls, [
        'cancel:100',
        'outbox:100',
        'cancel:100',
        'outbox:100',
      ]);
    },
  );

  test('does not settle outbox if ride cancellation phase fails', () async {
    final repository = _FakeExpirationRepository(
      cancellationError: StateError('isolated fake failure'),
    );
    final service = WaitingRideExpirationService(repository: repository);

    await expectLater(service.processDueRides(), throwsStateError);
    expect(repository.calls, ['cancel:100']);
  });
}

final class _FakeExpirationRepository
    implements WaitingRideExpirationRepository {
  _FakeExpirationRepository({
    this.batches = const [],
    this.outboxCounts = const [],
    this.cancellationError,
    this.outboxFailuresRemaining = 0,
  });

  final List<WaitingRideExpirationBatch> batches;
  final List<int> outboxCounts;
  final Object? cancellationError;
  int outboxFailuresRemaining;
  final List<String> calls = [];
  var _batchIndex = 0;
  var _outboxIndex = 0;

  @override
  Future<WaitingRideExpirationBatch> cancelExpiredWaitingRides({
    required int limit,
  }) async {
    calls.add('cancel:$limit');
    if (cancellationError case final error?) throw error;
    if (_batchIndex >= batches.length) {
      return const WaitingRideExpirationBatch(
        cancelledRideIds: [],
        expiredOfferCount: 0,
      );
    }
    return batches[_batchIndex++];
  }

  @override
  Future<int> settleOutboxForCancelledRides({required int limit}) async {
    calls.add('outbox:$limit');
    if (outboxFailuresRemaining > 0) {
      outboxFailuresRemaining--;
      throw StateError('isolated fake interruption');
    }
    if (_outboxIndex >= outboxCounts.length) return 0;
    return outboxCounts[_outboxIndex++];
  }
}
