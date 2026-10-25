import 'dart:async';

import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_repository.dart';
import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_worker.dart';
import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_worker_repository.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 25, 12);

  test('claims and completes a queued job', () async {
    final repository = _FakeWorkerRepository(now: now)..add(_record(now: now));
    final executor = _FakeExecutor();
    final worker = _worker(
      repository: repository,
      executor: executor,
      token: 'lease-queued',
    );

    final result = await worker.runOnce();

    expect(
      result.disposition,
      DriverOfferActionOutboxWorkerDisposition.completed,
    );
    expect(result.attemptCount, 1);
    expect(executor.actions.single.leaseToken, 'lease-queued');
    expect(
      repository.records['action-1']!.redispatchStatus,
      DriverOfferRedispatchStatus.completed,
    );
    expect(repository.records['action-1']!.redispatchCompletedAt, now);
  });

  test('claims a due retryable job', () async {
    final repository = _FakeWorkerRepository(now: now)
      ..add(
        _record(
          now: now,
          status: DriverOfferRedispatchStatus.retryable,
          attemptCount: 1,
          availableAt: now.subtract(const Duration(seconds: 1)),
          lastErrorCode: 'transient_failure',
        ),
      );
    final worker = _worker(
      repository: repository,
      executor: _FakeExecutor(),
      token: 'lease-retry',
    );

    final result = await worker.runOnce();

    expect(
      result.disposition,
      DriverOfferActionOutboxWorkerDisposition.completed,
    );
    expect(result.attemptCount, 2);
  });

  test(
    'reclaims an expired lease with a new token and another attempt',
    () async {
      final repository = _FakeWorkerRepository(now: now)
        ..add(
          _record(
            now: now,
            status: DriverOfferRedispatchStatus.leased,
            attemptCount: 1,
            leaseToken: 'stale-token',
            leaseUntil: now.subtract(const Duration(seconds: 1)),
          ),
        );
      final executor = _FakeExecutor();
      final worker = _worker(
        repository: repository,
        executor: executor,
        token: 'replacement-token',
      );

      final result = await worker.runOnce();

      expect(
        result.disposition,
        DriverOfferActionOutboxWorkerDisposition.completed,
      );
      expect(result.attemptCount, 2);
      expect(executor.actions.single.leaseToken, 'replacement-token');
      expect(repository.records['action-1']!.leaseToken, isNull);
    },
  );

  test('two competing workers execute a single claimed job', () async {
    final repository = _FakeWorkerRepository(now: now)..add(_record(now: now));
    final started = Completer<void>();
    final finish = Completer<DriverOfferRedispatchExecutionResult>();
    final executor = _FakeExecutor(
      onExecute: (action) {
        if (!started.isCompleted) started.complete();
        return finish.future;
      },
    );
    final first = _worker(
      repository: repository,
      executor: executor,
      token: 'lease-first',
    );
    final second = _worker(
      repository: repository,
      executor: executor,
      token: 'lease-second',
    );

    final firstRun = first.runOnce();
    await started.future;
    final secondResult = await second.runOnce();
    finish.complete(const DriverOfferRedispatchConfirmed());
    final firstResult = await firstRun;

    expect(
      firstResult.disposition,
      DriverOfferActionOutboxWorkerDisposition.completed,
    );
    expect(
      secondResult.disposition,
      DriverOfferActionOutboxWorkerDisposition.idle,
    );
    expect(executor.actions, hasLength(1));
  });

  test('a stale lease token cannot finalize after lease replacement', () async {
    final repository = _FakeWorkerRepository(now: now)..add(_record(now: now));
    final firstClaim = await repository.claimNext(
      leaseToken: 'old-token',
      leaseDuration: const Duration(seconds: 1),
      maxAttempts: 5,
    );
    expect(firstClaim, isNotNull);

    repository.now = now.add(const Duration(seconds: 2));
    final replacement = await repository.claimNext(
      leaseToken: 'new-token',
      leaseDuration: const Duration(seconds: 30),
      maxAttempts: 5,
    );
    expect(replacement?.leaseToken, 'new-token');

    final finalized = await repository.markCompleted(
      actionId: 'action-1',
      leaseToken: 'old-token',
    );

    expect(finalized, isFalse);
    expect(
      repository.records['action-1']!.redispatchStatus,
      DriverOfferRedispatchStatus.leased,
    );
    expect(repository.records['action-1']!.leaseToken, 'new-token');
  });

  test('temporary failure schedules bounded exponential backoff', () async {
    final repository = _FakeWorkerRepository(now: now)..add(_record(now: now));
    final worker = _worker(
      repository: repository,
      executor: _FakeExecutor(
        result: const DriverOfferRedispatchTemporaryFailure(
          errorCode: DriverOfferActionOutboxErrorCode.dependencyUnavailable,
        ),
      ),
      token: 'lease-retryable',
    );

    final result = await worker.runOnce();
    final record = repository.records['action-1']!;

    expect(
      result.disposition,
      DriverOfferActionOutboxWorkerDisposition.retryScheduled,
    );
    expect(result.retryAfter, const Duration(seconds: 5));
    expect(record.redispatchStatus, DriverOfferRedispatchStatus.retryable);
    expect(record.availableAt, now.add(const Duration(seconds: 5)));
    expect(record.lastErrorCode, 'dependency_unavailable');
    expect(record.leaseToken, isNull);
    expect(record.redispatchCompletedAt, isNull);
  });

  test('permanent failure moves the job to needs_review', () async {
    final repository = _FakeWorkerRepository(now: now)..add(_record(now: now));
    final worker = _worker(
      repository: repository,
      executor: _FakeExecutor(
        result: const DriverOfferRedispatchPermanentFailure(),
      ),
      token: 'lease-permanent',
    );

    final result = await worker.runOnce();

    expect(
      result.disposition,
      DriverOfferActionOutboxWorkerDisposition.needsReview,
    );
    expect(
      repository.records['action-1']!.redispatchStatus,
      DriverOfferRedispatchStatus.needsReview,
    );
    expect(repository.records['action-1']!.lastErrorCode, 'permanent_failure');
    expect(repository.records['action-1']!.leaseUntil, isNull);
  });

  test(
    'the maximum attempt is moved to needs_review without another retry',
    () async {
      final repository = _FakeWorkerRepository(now: now)
        ..add(_record(now: now));
      final worker = DriverOfferActionOutboxWorker(
        repository: repository,
        executor: _FakeExecutor(
          result: const DriverOfferRedispatchTemporaryFailure(),
        ),
        leaseDuration: const Duration(seconds: 30),
        maxAttempts: 1,
        baseRetryDelay: const Duration(seconds: 5),
        maxRetryDelay: const Duration(minutes: 5),
        leaseTokenFactory: () => 'lease-final-attempt',
      );

      final result = await worker.runOnce();

      expect(
        result.disposition,
        DriverOfferActionOutboxWorkerDisposition.needsReview,
      );
      expect(repository.records['action-1']!.attemptCount, 1);
      expect(
        repository.records['action-1']!.redispatchStatus,
        DriverOfferRedispatchStatus.needsReview,
      );
      expect(
        repository.records['action-1']!.lastErrorCode,
        'attempts_exhausted',
      );
    },
  );

  test('an unknown execution outcome is never marked completed', () async {
    final repository = _FakeWorkerRepository(now: now)..add(_record(now: now));
    final worker = _worker(
      repository: repository,
      executor: _FakeExecutor(
        result: const DriverOfferRedispatchOutcomeUnknown(),
      ),
      token: 'lease-unknown',
    );

    final result = await worker.runOnce();

    expect(
      result.disposition,
      DriverOfferActionOutboxWorkerDisposition.needsReview,
    );
    expect(
      repository.records['action-1']!.redispatchStatus,
      DriverOfferRedispatchStatus.needsReview,
    );
    expect(repository.records['action-1']!.redispatchCompletedAt, isNull);
  });

  test(
    'unexpected executor exception is sanitized and not completed',
    () async {
      final repository = _FakeWorkerRepository(now: now)
        ..add(_record(now: now));
      final worker = _worker(
        repository: repository,
        executor: _FakeExecutor(
          throwOnExecute: StateError('raw private details'),
        ),
        token: 'lease-exception',
      );

      final result = await worker.runOnce();
      final record = repository.records['action-1']!;

      expect(
        result.disposition,
        DriverOfferActionOutboxWorkerDisposition.needsReview,
      );
      expect(record.redispatchStatus, DriverOfferRedispatchStatus.needsReview);
      expect(record.lastErrorCode, 'unexpected_failure');
      expect(record.lastErrorCode, isNot(contains('raw private details')));
      expect(record.redispatchCompletedAt, isNull);
    },
  );

  test('does not claim a job before available_at', () async {
    final repository = _FakeWorkerRepository(
      now: now,
    )..add(_record(now: now, availableAt: now.add(const Duration(minutes: 1))));
    final executor = _FakeExecutor();
    final worker = _worker(
      repository: repository,
      executor: executor,
      token: 'lease-not-ready',
    );

    final result = await worker.runOnce();

    expect(result.disposition, DriverOfferActionOutboxWorkerDisposition.idle);
    expect(executor.actions, isEmpty);
  });

  test('moves an expired lease at the attempt limit to needs_review', () async {
    final repository = _FakeWorkerRepository(now: now)
      ..add(
        _record(
          now: now,
          status: DriverOfferRedispatchStatus.leased,
          attemptCount: 2,
          leaseToken: 'expired-token',
          leaseUntil: now.subtract(const Duration(seconds: 1)),
        ),
      );
    final executor = _FakeExecutor();
    final worker = DriverOfferActionOutboxWorker(
      repository: repository,
      executor: executor,
      leaseDuration: const Duration(seconds: 30),
      maxAttempts: 2,
      leaseTokenFactory: () => 'unused-token',
    );

    final result = await worker.runOnce();

    expect(result.disposition, DriverOfferActionOutboxWorkerDisposition.idle);
    expect(
      repository.records['action-1']!.redispatchStatus,
      DriverOfferRedispatchStatus.needsReview,
    );
    expect(repository.records['action-1']!.lastErrorCode, 'attempts_exhausted');
    expect(repository.records['action-1']!.leaseToken, isNull);
    expect(executor.actions, isEmpty);
  });
}

DriverOfferActionOutboxWorker _worker({
  required _FakeWorkerRepository repository,
  required _FakeExecutor executor,
  required String token,
}) => DriverOfferActionOutboxWorker(
  repository: repository,
  executor: executor,
  leaseDuration: const Duration(seconds: 30),
  maxAttempts: 5,
  baseRetryDelay: const Duration(seconds: 5),
  maxRetryDelay: const Duration(minutes: 5),
  leaseTokenFactory: () => token,
);

DriverOfferActionOutboxRecord _record({
  required DateTime now,
  DriverOfferRedispatchStatus status = DriverOfferRedispatchStatus.queued,
  int attemptCount = 0,
  DateTime? availableAt,
  String? leaseToken,
  DateTime? leaseUntil,
  String? lastErrorCode,
}) => DriverOfferActionOutboxRecord(
  actionId: 'action-1',
  offerId: 'offer-1',
  driverId: 'driver-1',
  action: DriverOfferAction.reject,
  idempotencyKey: null,
  requestHash: List.filled(64, 'a').join(),
  policyOutcome: 'not_eligible',
  redispatchStatus: status,
  attemptCount: attemptCount,
  availableAt: availableAt ?? now,
  leaseToken: leaseToken,
  leaseUntil: leaseUntil,
  lastErrorCode: lastErrorCode,
  redispatchResult: null,
  createdAt: now.subtract(const Duration(minutes: 1)),
  settledAt: now.subtract(const Duration(minutes: 1)),
  updatedAt: now,
  redispatchCompletedAt: null,
);

final class _FakeExecutor implements DriverOfferRedispatchExecutor {
  _FakeExecutor({
    this.result = const DriverOfferRedispatchConfirmed(),
    this.throwOnExecute,
    this.onExecute,
  });

  final DriverOfferRedispatchExecutionResult result;
  final Object? throwOnExecute;
  final Future<DriverOfferRedispatchExecutionResult> Function(
    DriverOfferActionOutboxRecord,
  )?
  onExecute;
  final actions = <DriverOfferActionOutboxRecord>[];

  @override
  Future<DriverOfferRedispatchExecutionResult> execute(
    DriverOfferActionOutboxRecord action,
  ) async {
    actions.add(action);
    if (throwOnExecute != null) throw throwOnExecute!;
    final callback = onExecute;
    if (callback != null) return callback(action);
    return result;
  }
}

final class _FakeWorkerRepository
    implements DriverOfferActionOutboxWorkerRepository {
  _FakeWorkerRepository({required this.now});

  DateTime now;
  final Map<String, DriverOfferActionOutboxRecord> records = {};

  void add(DriverOfferActionOutboxRecord record) {
    records[record.actionId] = record;
  }

  @override
  Future<DriverOfferActionOutboxRecord?> claimNext({
    required String leaseToken,
    required Duration leaseDuration,
    required int maxAttempts,
  }) async {
    final exhausted = records.values
        .where(
          (record) =>
              record.action == DriverOfferAction.reject &&
              record.attemptCount >= maxAttempts &&
              ((record.redispatchStatus == DriverOfferRedispatchStatus.queued ||
                      record.redispatchStatus ==
                          DriverOfferRedispatchStatus.retryable) ||
                  (record.redispatchStatus ==
                          DriverOfferRedispatchStatus.leased &&
                      !record.leaseUntil!.isAfter(now))),
        )
        .toList();
    if (exhausted.isNotEmpty) {
      final record = exhausted.first;
      records[record.actionId] = _copyRecord(
        record,
        status: DriverOfferRedispatchStatus.needsReview,
        leaseToken: null,
        leaseUntil: null,
        lastErrorCode: 'attempts_exhausted',
        updatedAt: now,
      );
    }

    final candidates =
        records.values.where((record) {
          if (record.action != DriverOfferAction.reject ||
              record.attemptCount >= maxAttempts) {
            return false;
          }
          if ((record.redispatchStatus == DriverOfferRedispatchStatus.queued ||
                  record.redispatchStatus ==
                      DriverOfferRedispatchStatus.retryable) &&
              !record.availableAt.isAfter(now)) {
            return true;
          }
          return record.redispatchStatus ==
                  DriverOfferRedispatchStatus.leased &&
              !record.leaseUntil!.isAfter(now);
        }).toList()..sort((a, b) {
          final available = a.availableAt.compareTo(b.availableAt);
          if (available != 0) return available;
          final created = a.createdAt.compareTo(b.createdAt);
          return created != 0 ? created : a.actionId.compareTo(b.actionId);
        });
    if (candidates.isEmpty) return null;
    final record = candidates.first;
    final claimed = _copyRecord(
      record,
      status: DriverOfferRedispatchStatus.leased,
      attemptCount: record.attemptCount + 1,
      leaseToken: leaseToken,
      leaseUntil: now.add(leaseDuration),
      updatedAt: now,
    );
    records[record.actionId] = claimed;
    return claimed;
  }

  @override
  Future<bool> markCompleted({
    required String actionId,
    required String leaseToken,
  }) async {
    final record = _currentLease(actionId, leaseToken);
    if (record == null) return false;
    records[actionId] = _copyRecord(
      record,
      status: DriverOfferRedispatchStatus.completed,
      leaseToken: null,
      leaseUntil: null,
      lastErrorCode: null,
      redispatchResult: const {'outcome': 'confirmed'},
      redispatchCompletedAt: now,
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
    final record = _currentLease(actionId, leaseToken);
    if (record == null) return false;
    records[actionId] = _copyRecord(
      record,
      status: DriverOfferRedispatchStatus.retryable,
      leaseToken: null,
      leaseUntil: null,
      lastErrorCode: errorCode.databaseValue,
      availableAt: now.add(retryAfter),
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
    final record = _currentLease(actionId, leaseToken);
    if (record == null) return false;
    records[actionId] = _copyRecord(
      record,
      status: DriverOfferRedispatchStatus.needsReview,
      leaseToken: null,
      leaseUntil: null,
      lastErrorCode: errorCode.databaseValue,
      updatedAt: now,
    );
    return true;
  }

  DriverOfferActionOutboxRecord? _currentLease(
    String actionId,
    String leaseToken,
  ) {
    final record = records[actionId];
    if (record == null ||
        record.redispatchStatus != DriverOfferRedispatchStatus.leased ||
        record.leaseToken != leaseToken ||
        !record.leaseUntil!.isAfter(now)) {
      return null;
    }
    return record;
  }
}

DriverOfferActionOutboxRecord _copyRecord(
  DriverOfferActionOutboxRecord record, {
  DriverOfferRedispatchStatus? status,
  int? attemptCount,
  DateTime? availableAt,
  String? leaseToken,
  DateTime? leaseUntil,
  String? lastErrorCode,
  Object? redispatchResult,
  DateTime? redispatchCompletedAt,
  DateTime? updatedAt,
}) => DriverOfferActionOutboxRecord(
  actionId: record.actionId,
  offerId: record.offerId,
  driverId: record.driverId,
  action: record.action,
  idempotencyKey: record.idempotencyKey,
  requestHash: record.requestHash,
  policyOutcome: record.policyOutcome,
  redispatchStatus: status ?? record.redispatchStatus,
  attemptCount: attemptCount ?? record.attemptCount,
  availableAt: availableAt ?? record.availableAt,
  leaseToken: leaseToken,
  leaseUntil: leaseUntil,
  lastErrorCode: lastErrorCode,
  redispatchResult: redispatchResult,
  createdAt: record.createdAt,
  settledAt: record.settledAt,
  updatedAt: updatedAt ?? record.updatedAt,
  redispatchCompletedAt: redispatchCompletedAt,
);
