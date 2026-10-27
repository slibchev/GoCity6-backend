import 'package:gocity6_backend/dispatch/automatic_dispatch_redispatch_executor.dart';
import 'package:gocity6_backend/dispatch/automatic_dispatch_redispatch_service.dart';
import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_repository.dart';
import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_worker.dart';
import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_worker_repository.dart';
import 'package:gocity6_backend/dispatch/idempotent_automatic_redispatch_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:gocity6_backend/dispatch/ride_offer_repository.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 25, 12);

  group('AutomaticDispatchRedispatchExecutor', () {
    test(
      'maps a created automatic offer to confirmed with stable identities',
      () async {
        final original = _originalOffer(now: now);
        final action = _action(now: now);
        final created = _redispatchedOffer(now: now, rideId: original.rideId);
        final service = _FakeRedispatcher(
          (_, _, _) async => AutomaticDispatchRedispatchCreated(created),
        );
        final executor = _executor(original: original, service: service);

        final result = await executor.execute(action);

        expect(result, isA<DriverOfferRedispatchConfirmed>());
        expect(service.calls, [
          (
            rideId: original.rideId,
            actionId: action.actionId,
            leaseToken: action.leaseToken!,
          ),
        ]);
      },
    );

    test('maps an already progressed action to confirmed', () async {
      final original = _originalOffer(now: now);
      final progressed = _redispatchedOffer(now: now, rideId: original.rideId);
      final executor = _executor(
        original: original,
        service: _FakeRedispatcher(
          (_, _, _) async =>
              AutomaticDispatchRedispatchAlreadyProgressed(progressed),
        ),
      );

      expect(
        await executor.execute(_action(now: now)),
        isA<DriverOfferRedispatchConfirmed>(),
      );
    });

    test(
      'no eligible driver produces a retryable, non-completed result',
      () async {
        final original = _originalOffer(now: now);
        final executor = _executor(
          original: original,
          service: _FakeRedispatcher(
            (_, _, _) async =>
                const AutomaticDispatchRedispatchNoEligibleDriver(),
          ),
        );

        final result = await executor.execute(_action(now: now));

        expect(result, isA<DriverOfferRedispatchTemporaryFailure>());
        expect(
          (result as DriverOfferRedispatchTemporaryFailure).errorCode,
          DriverOfferActionOutboxErrorCode.noEligibleDriver,
        );
      },
    );

    test('waiting-board offer is sent to review without redispatch', () async {
      final original = _originalOffer(
        now: now,
        source: RideOfferSource.waitingBoard,
      );
      final service = _FakeRedispatcher((_, _, _) async {
        fail('Unsupported waiting-board action must not be dispatched.');
      });
      final executor = _executor(original: original, service: service);

      final result = await executor.execute(_action(now: now));

      expect(result, isA<DriverOfferRedispatchPermanentFailure>());
      expect(
        (result as DriverOfferRedispatchPermanentFailure).errorCode,
        DriverOfferActionOutboxErrorCode.unsupportedOfferSource,
      );
      expect(service.calls, isEmpty);
    });

    test('fails closed when the original offer is not rejected', () async {
      final original = _originalOffer(now: now, rejected: false);
      final service = _FakeRedispatcher((_, _, _) async {
        fail('Service must not run for an unresolved offer.');
      });
      final executor = _executor(original: original, service: service);

      await expectLater(
        executor.execute(_action(now: now)),
        throwsA(
          isA<DriverOfferRedispatchInvariantException>().having(
            (error) => error.invariant,
            'invariant',
            DriverOfferRedispatchInvariant.originalOfferNotRejected,
          ),
        ),
      );
      expect(service.calls, isEmpty);
    });

    test('fails closed when action and original offer owners differ', () async {
      final original = _originalOffer(now: now);
      final service = _FakeRedispatcher((_, _, _) async {
        fail('Service must not run for an ownership mismatch.');
      });

      await expectLater(
        _executor(
          original: original,
          service: service,
        ).execute(_action(now: now, driverId: 'another-driver')),
        throwsA(
          isA<DriverOfferRedispatchInvariantException>().having(
            (error) => error.invariant,
            'invariant',
            DriverOfferRedispatchInvariant.ownerMismatch,
          ),
        ),
      );
      expect(service.calls, isEmpty);
    });

    test('fails closed when original offer is missing', () async {
      final service = _FakeRedispatcher((_, _, _) async {
        fail('Service must not run without the source offer.');
      });

      await expectLater(
        _executor(original: null, service: service).execute(_action(now: now)),
        throwsA(
          isA<DriverOfferRedispatchInvariantException>().having(
            (error) => error.invariant,
            'invariant',
            DriverOfferRedispatchInvariant.originalOfferNotFound,
          ),
        ),
      );
      expect(service.calls, isEmpty);
    });

    test(
      'does not turn a lease-lost conflict into a successful result',
      () async {
        final original = _originalOffer(now: now);
        final service = _FakeRedispatcher((_, _, _) async {
          throw const AutomaticRedispatchConflictException(
            AutomaticRedispatchConflict.leaseLost,
          );
        });

        await expectLater(
          _executor(
            original: original,
            service: service,
          ).execute(_action(now: now)),
          throwsA(isA<AutomaticRedispatchConflictException>()),
        );
      },
    );

    test('does not hide an unexpected database error', () async {
      final original = _originalOffer(now: now);
      final service = _FakeRedispatcher((_, _, _) async {
        throw StateError('simulated database failure');
      });

      await expectLater(
        _executor(
          original: original,
          service: service,
        ).execute(_action(now: now)),
        throwsA(isA<StateError>()),
      );
    });

    test('fails closed if the service reports a different ride', () async {
      final original = _originalOffer(now: now);
      final service = _FakeRedispatcher(
        (_, _, _) async => AutomaticDispatchRedispatchCreated(
          _redispatchedOffer(now: now, rideId: 'unexpected-ride'),
        ),
      );

      await expectLater(
        _executor(
          original: original,
          service: service,
        ).execute(_action(now: now)),
        throwsA(
          isA<DriverOfferRedispatchInvariantException>().having(
            (error) => error.invariant,
            'invariant',
            DriverOfferRedispatchInvariant.resultRideMismatch,
          ),
        ),
      );
    });
  });

  group('Outbox worker with automatic redispatch executor', () {
    test('unsupported waiting-board action is not marked completed', () async {
      final repository = _MemoryWorkerRepository(now: now);
      final original = _originalOffer(
        now: now,
        source: RideOfferSource.waitingBoard,
      );
      final service = _FakeRedispatcher((_, _, _) async {
        fail('Waiting-board work must not enter automatic redispatch.');
      });
      final worker = _worker(
        repository: repository,
        executor: _executor(original: original, service: service),
        tokens: ['lease-waiting-board'],
      );

      final result = await worker.runOnce();

      expect(
        result.disposition,
        DriverOfferActionOutboxWorkerDisposition.needsReview,
      );
      expect(repository.record.lastErrorCode, 'unsupported_offer_source');
      expect(repository.completedCalls, 0);
      expect(service.calls, isEmpty);
    });

    test('bounds no-eligible retries and never marks them completed', () async {
      final repository = _MemoryWorkerRepository(now: now);
      final original = _originalOffer(now: now);
      final service = _FakeRedispatcher(
        (_, _, _) async => const AutomaticDispatchRedispatchNoEligibleDriver(),
      );
      final worker = _worker(
        repository: repository,
        executor: _executor(original: original, service: service),
        tokens: ['lease-1', 'lease-2'],
        maxAttempts: 2,
      );

      final first = await worker.runOnce();
      expect(
        first.disposition,
        DriverOfferActionOutboxWorkerDisposition.retryScheduled,
      );
      expect(
        repository.record.redispatchStatus,
        DriverOfferRedispatchStatus.retryable,
      );
      expect(repository.record.lastErrorCode, 'no_eligible_driver');
      expect(repository.completedCalls, 0);

      repository.now = repository.record.availableAt;
      final second = await worker.runOnce();

      expect(
        second.disposition,
        DriverOfferActionOutboxWorkerDisposition.needsReview,
      );
      expect(
        repository.record.redispatchStatus,
        DriverOfferRedispatchStatus.needsReview,
      );
      expect(repository.record.lastErrorCode, 'attempts_exhausted');
      expect(repository.completedCalls, 0);
      expect(service.calls.map((call) => call.actionId), [
        'action-stable-1',
        'action-stable-1',
      ]);
    });

    test(
      'retry after committed offer reuses action id and creates no duplicate',
      () async {
        final repository = _MemoryWorkerRepository(
          now: now,
          failFirstCompletion: true,
        );
        final original = _originalOffer(now: now);
        RideOffer? persistedOffer;
        var createCount = 0;
        final service = _FakeRedispatcher((rideId, actionId, leaseToken) async {
          final existing = persistedOffer;
          if (existing != null) {
            return AutomaticDispatchRedispatchAlreadyProgressed(existing);
          }
          createCount++;
          persistedOffer = _redispatchedOffer(now: now, rideId: rideId);
          return AutomaticDispatchRedispatchCreated(persistedOffer!);
        });
        final worker = _worker(
          repository: repository,
          executor: _executor(original: original, service: service),
          tokens: ['lease-worker-a', 'lease-worker-b'],
        );

        await expectLater(worker.runOnce(), throwsA(isA<StateError>()));
        expect(persistedOffer, isNotNull);
        expect(
          repository.record.redispatchStatus,
          DriverOfferRedispatchStatus.leased,
        );

        repository.now = repository.record.leaseUntil!.add(
          const Duration(milliseconds: 1),
        );
        final recovered = await worker.runOnce();

        expect(
          recovered.disposition,
          DriverOfferActionOutboxWorkerDisposition.completed,
        );
        expect(
          repository.record.redispatchStatus,
          DriverOfferRedispatchStatus.completed,
        );
        expect(createCount, 1);
        expect(service.calls, hasLength(2));
        expect(service.calls.map((call) => call.actionId).toSet(), {
          'action-stable-1',
        });
        expect(service.calls.map((call) => call.leaseToken), [
          'lease-worker-a',
          'lease-worker-b',
        ]);
      },
    );

    test('expired lease cannot create or complete after leaseLost', () async {
      final repository = _MemoryWorkerRepository(now: now);
      final original = _originalOffer(now: now);
      final service = _FakeRedispatcher((_, _, _) async {
        repository.now = repository.record.leaseUntil!.add(
          const Duration(milliseconds: 1),
        );
        throw const AutomaticRedispatchConflictException(
          AutomaticRedispatchConflict.leaseLost,
        );
      });
      final worker = _worker(
        repository: repository,
        executor: _executor(original: original, service: service),
        tokens: ['stale-lease'],
      );

      final result = await worker.runOnce();

      expect(
        result.disposition,
        DriverOfferActionOutboxWorkerDisposition.leaseLost,
      );
      expect(repository.completedCalls, 0);
      expect(
        repository.record.redispatchStatus,
        DriverOfferRedispatchStatus.leased,
      );
      expect(service.calls.single.actionId, 'action-stable-1');
      expect(service.calls.single.leaseToken, 'stale-lease');
    });

    test(
      'unexpected service failure goes to review without false success',
      () async {
        final repository = _MemoryWorkerRepository(now: now);
        final original = _originalOffer(now: now);
        final service = _FakeRedispatcher((_, _, _) async {
          throw StateError('unexpected database error');
        });
        final worker = _worker(
          repository: repository,
          executor: _executor(original: original, service: service),
          tokens: ['lease-failure'],
        );

        final result = await worker.runOnce();

        expect(
          result.disposition,
          DriverOfferActionOutboxWorkerDisposition.needsReview,
        );
        expect(repository.completedCalls, 0);
        expect(
          repository.record.redispatchStatus,
          DriverOfferRedispatchStatus.needsReview,
        );
        expect(repository.record.lastErrorCode, 'unexpected_failure');
      },
    );
  });
}

AutomaticDispatchRedispatchExecutor _executor({
  required RideOffer? original,
  required _FakeRedispatcher service,
}) => AutomaticDispatchRedispatchExecutor(
  offerRepository: _FakeRideOfferRepository(original),
  redispatchService: service,
);

DriverOfferActionOutboxWorker _worker({
  required _MemoryWorkerRepository repository,
  required DriverOfferRedispatchExecutor executor,
  required List<String> tokens,
  int maxAttempts = 5,
}) {
  var tokenIndex = 0;
  return DriverOfferActionOutboxWorker(
    repository: repository,
    executor: executor,
    leaseDuration: const Duration(seconds: 30),
    maxAttempts: maxAttempts,
    baseRetryDelay: const Duration(seconds: 5),
    maxRetryDelay: const Duration(minutes: 5),
    leaseTokenFactory: () => tokens[tokenIndex++],
  );
}

RideOffer _originalOffer({
  required DateTime now,
  RideOfferSource source = RideOfferSource.automatic,
  bool rejected = true,
  String driverId = 'driver-owner',
}) {
  final offer = RideOffer.create(
    id: 'offer-original',
    rideId: 'ride-original',
    driverId: driverId,
    vehicleId: 'vehicle-original',
    etaSeconds: 80,
    distanceMeters: 500,
    source: source,
    offeredAt: now.subtract(const Duration(minutes: 1)),
    timeout: const Duration(minutes: 5),
  );
  return rejected ? offer.reject(now) : offer;
}

RideOffer _redispatchedOffer({required DateTime now, required String rideId}) =>
    RideOffer.create(
      id: 'offer-redispatched',
      rideId: rideId,
      driverId: 'driver-next',
      vehicleId: 'vehicle-next',
      etaSeconds: 90,
      distanceMeters: 600,
      source: RideOfferSource.automatic,
      offeredAt: now,
      timeout: const Duration(seconds: 15),
    );

DriverOfferActionOutboxRecord _action({
  required DateTime now,
  String driverId = 'driver-owner',
  DriverOfferAction action = DriverOfferAction.reject,
  DriverOfferRedispatchStatus status = DriverOfferRedispatchStatus.leased,
  String? leaseToken = 'lease-current',
}) => DriverOfferActionOutboxRecord(
  actionId: 'action-stable-1',
  offerId: 'offer-original',
  driverId: driverId,
  action: action,
  idempotencyKey: 'request-key-1',
  requestHash: List.filled(64, 'a').join(),
  policyOutcome: action == DriverOfferAction.reject ? 'not_eligible' : null,
  redispatchStatus: status,
  attemptCount: status == DriverOfferRedispatchStatus.leased ? 1 : 0,
  availableAt: now,
  leaseToken: status == DriverOfferRedispatchStatus.leased ? leaseToken : null,
  leaseUntil: status == DriverOfferRedispatchStatus.leased
      ? now.add(const Duration(seconds: 30))
      : null,
  lastErrorCode: null,
  redispatchResult: null,
  createdAt: now.subtract(const Duration(minutes: 1)),
  settledAt: now.subtract(const Duration(minutes: 1)),
  updatedAt: now,
  redispatchCompletedAt: null,
);

final class _FakeRedispatcher implements AutomaticDispatchRedispatcher {
  _FakeRedispatcher(this.handler);

  final Future<AutomaticDispatchRedispatchResult> Function(
    String rideId,
    String actionId,
    String leaseToken,
  )
  handler;
  final calls = <({String rideId, String actionId, String leaseToken})>[];

  @override
  Future<AutomaticDispatchRedispatchResult> redispatch({
    required String rideId,
    required String actionId,
    required String leaseToken,
  }) {
    calls.add((rideId: rideId, actionId: actionId, leaseToken: leaseToken));
    return handler(rideId, actionId, leaseToken);
  }
}

final class _FakeRideOfferRepository implements RideOfferRepository {
  _FakeRideOfferRepository(this.offer);

  final RideOffer? offer;

  @override
  Future<RideOffer?> findById(String id) async => offer;

  @override
  Future<List<RideOffer>> findByRideId(String rideId) async =>
      throw UnimplementedError();

  @override
  Future<List<RideOffer>> findPendingExpiredAt(DateTime now) async =>
      throw UnimplementedError();

  @override
  Future<void> create(RideOffer offer) async => throw UnimplementedError();

  @override
  Future<bool> resolve(RideOffer offer) async => throw UnimplementedError();

  @override
  Future<bool> markDisplayed({
    required String offerId,
    required String driverId,
    required DateTime displayedAt,
  }) async => throw UnimplementedError();
}

final class _MemoryWorkerRepository
    implements DriverOfferActionOutboxWorkerRepository {
  _MemoryWorkerRepository({required this.now, this.failFirstCompletion = false})
    : record = _action(now: now, status: DriverOfferRedispatchStatus.queued);

  DateTime now;
  DriverOfferActionOutboxRecord record;
  bool failFirstCompletion;
  int completedCalls = 0;

  @override
  Future<DriverOfferActionOutboxRecord?> claimNext({
    required String leaseToken,
    required Duration leaseDuration,
    required int maxAttempts,
  }) async {
    final exhausted = record.attemptCount >= maxAttempts;
    final available = switch (record.redispatchStatus) {
      DriverOfferRedispatchStatus.queued ||
      DriverOfferRedispatchStatus.retryable => !record.availableAt.isAfter(now),
      DriverOfferRedispatchStatus.leased =>
        record.leaseUntil != null && !record.leaseUntil!.isAfter(now),
      _ => false,
    };
    if (exhausted) {
      record = _copy(
        record,
        status: DriverOfferRedispatchStatus.needsReview,
        attemptCount: record.attemptCount,
        availableAt: record.availableAt,
        leaseToken: null,
        leaseUntil: null,
        lastErrorCode: 'attempts_exhausted',
        completedAt: null,
        updatedAt: now,
      );
      return null;
    }
    if (!available) return null;
    record = _copy(
      record,
      status: DriverOfferRedispatchStatus.leased,
      attemptCount: record.attemptCount + 1,
      availableAt: record.availableAt,
      leaseToken: leaseToken,
      leaseUntil: now.add(leaseDuration),
      lastErrorCode: null,
      completedAt: null,
      updatedAt: now,
    );
    return record;
  }

  @override
  Future<bool> markCompleted({
    required String actionId,
    required String leaseToken,
  }) async {
    completedCalls++;
    if (failFirstCompletion) {
      failFirstCompletion = false;
      throw StateError('simulated completion interruption');
    }
    if (!_ownsLease(actionId, leaseToken)) return false;
    record = _copy(
      record,
      status: DriverOfferRedispatchStatus.completed,
      attemptCount: record.attemptCount,
      availableAt: record.availableAt,
      leaseToken: null,
      leaseUntil: null,
      lastErrorCode: null,
      completedAt: now,
      updatedAt: now,
    );
    return true;
  }

  @override
  Future<bool> markRetryable({
    required String actionId,
    required String leaseToken,
    required Duration retryAfter,
    required DriverOfferActionOutboxErrorCode errorCode,
  }) async {
    if (!_ownsLease(actionId, leaseToken)) return false;
    record = _copy(
      record,
      status: DriverOfferRedispatchStatus.retryable,
      attemptCount: record.attemptCount,
      availableAt: now.add(retryAfter),
      leaseToken: null,
      leaseUntil: null,
      lastErrorCode: errorCode.databaseValue,
      completedAt: null,
      updatedAt: now,
    );
    return true;
  }

  @override
  Future<bool> markNeedsReview({
    required String actionId,
    required String leaseToken,
    required DriverOfferActionOutboxErrorCode errorCode,
  }) async {
    if (!_ownsLease(actionId, leaseToken)) return false;
    record = _copy(
      record,
      status: DriverOfferRedispatchStatus.needsReview,
      attemptCount: record.attemptCount,
      availableAt: record.availableAt,
      leaseToken: null,
      leaseUntil: null,
      lastErrorCode: errorCode.databaseValue,
      completedAt: null,
      updatedAt: now,
    );
    return true;
  }

  bool _ownsLease(String actionId, String leaseToken) =>
      record.actionId == actionId &&
      record.redispatchStatus == DriverOfferRedispatchStatus.leased &&
      record.leaseToken == leaseToken &&
      record.leaseUntil != null &&
      record.leaseUntil!.isAfter(now);

  DriverOfferActionOutboxRecord _copy(
    DriverOfferActionOutboxRecord source, {
    required DriverOfferRedispatchStatus status,
    required int attemptCount,
    required DateTime availableAt,
    required String? leaseToken,
    required DateTime? leaseUntil,
    required String? lastErrorCode,
    required DateTime? completedAt,
    required DateTime updatedAt,
  }) => DriverOfferActionOutboxRecord(
    actionId: source.actionId,
    offerId: source.offerId,
    driverId: source.driverId,
    action: source.action,
    idempotencyKey: source.idempotencyKey,
    requestHash: source.requestHash,
    policyOutcome: source.policyOutcome,
    redispatchStatus: status,
    attemptCount: attemptCount,
    availableAt: availableAt,
    leaseToken: leaseToken,
    leaseUntil: leaseUntil,
    lastErrorCode: lastErrorCode,
    redispatchResult: status == DriverOfferRedispatchStatus.completed
        ? const {'outcome': 'confirmed'}
        : null,
    createdAt: source.createdAt,
    settledAt: source.settledAt,
    updatedAt: updatedAt,
    redispatchCompletedAt: completedAt,
  );
}
