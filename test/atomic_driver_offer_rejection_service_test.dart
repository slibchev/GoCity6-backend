import 'package:gocity6_backend/dispatch/atomic_driver_offer_rejection_service.dart';
import 'package:gocity6_backend/dispatch/driver_dispatch_state.dart';
import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_repository.dart';
import 'package:gocity6_backend/dispatch/driver_offer_rejection_transaction.dart';
import 'package:gocity6_backend/dispatch/ride_offer.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 25, 12);

  AtomicDriverOfferRejectionService serviceFor(_MemoryRunner runner) =>
      AtomicDriverOfferRejectionService(
        transactionRunner: runner,
        clock: () => now,
        actionIdFactory: () => 'action-generated',
      );

  test(
    'eligible standard rejection atomically applies policy and queues work',
    () async {
      final runner = _MemoryRunner(
        _MemoryState(
          offer: _offer(now: now, dispatchRound: 1),
          requestedAt: now.subtract(const Duration(minutes: 2)),
          queue: const DriverOfferRejectionQueue(
            shiftId: 'shift-1',
            vehicleId: 'vehicle-1',
            availability: 'available',
            hasPendingOffer: true,
          ),
          dispatchState: const DriverDispatchState(
            driverId: 'driver-1',
            consecutiveRejects: 2,
            penaltyLevel: 0,
            dispatchBlockedUntil: null,
            penaltyResetEligibleAt: null,
          ),
        ),
      );

      final result = await serviceFor(runner).reject(
        driverId: 'driver-1',
        offerId: 'offer-1',
        idempotencyKey: 'request-1',
      );

      expect(result, isA<AtomicDriverOfferRejectionApplied>());
      final applied = result as AtomicDriverOfferRejectionApplied;
      expect(
        applied.policyOutcome,
        DriverOfferRejectionPolicyOutcome.standardEligible,
      );
      expect(
        applied.outboxRecord.redispatchStatus,
        DriverOfferRedispatchStatus.queued,
      );
      expect(applied.outboxRecord.settledAt, applied.outboxRecord.createdAt);
      expect(applied.dispatchState?.consecutiveRejects, 0);
      expect(applied.dispatchState?.penaltyLevel, 1);
      expect(
        applied.dispatchState?.dispatchBlockedUntil,
        now.add(const Duration(minutes: 30)),
      );
      expect(runner.state.offer.status, RideOfferStatus.rejected);
      expect(runner.state.queue?.hasPendingOffer, isFalse);
      expect(runner.state.records, hasLength(1));
    },
  );

  test(
    'eligible bonus rejection keeps fixed cooldown and does not escalate level',
    () async {
      final runner = _MemoryRunner(
        _MemoryState(
          offer: _offer(now: now, dispatchRound: 2),
          requestedAt: now.subtract(const Duration(minutes: 2)),
          queue: _availableQueue(),
          dispatchState: const DriverDispatchState(
            driverId: 'driver-1',
            consecutiveRejects: 2,
            penaltyLevel: 3,
            dispatchBlockedUntil: null,
            penaltyResetEligibleAt: null,
            requiresCompletedRideAfterPenalty: true,
          ),
        ),
      );

      final result = await serviceFor(runner)
          .reject(driverId: 'driver-1', offerId: 'offer-1');

      final applied = result as AtomicDriverOfferRejectionApplied;
      expect(
        applied.policyOutcome,
        DriverOfferRejectionPolicyOutcome.bonusEligible,
      );
      expect(applied.dispatchState?.consecutiveRejects, 0);
      expect(applied.dispatchState?.penaltyLevel, 3);
      expect(applied.dispatchState?.requiresCompletedRideAfterPenalty, isTrue);
      expect(
        applied.dispatchState?.dispatchBlockedUntil,
        now.add(const Duration(minutes: 30)),
      );
    },
  );

  test(
    'ineligible rejection releases offer without changing policy state',
    () async {
      final initial = const DriverDispatchState(
        driverId: 'driver-1',
        consecutiveRejects: 2,
        penaltyLevel: 1,
        dispatchBlockedUntil: null,
        penaltyResetEligibleAt: null,
      );
      final runner = _MemoryRunner(
        _MemoryState(
          offer: _offer(now: now, dispatchRound: 1),
          requestedAt: now.subtract(const Duration(minutes: 21)),
          queue: _availableQueue(),
          dispatchState: initial,
        ),
      );

      final result = await serviceFor(runner)
          .reject(driverId: 'driver-1', offerId: 'offer-1');

      final applied = result as AtomicDriverOfferRejectionApplied;
      expect(
        applied.policyOutcome,
        DriverOfferRejectionPolicyOutcome.notEligible,
      );
      expect(applied.dispatchState, isNull);
      expect(runner.state.dispatchState, same(initial));
      expect(runner.state.offer.status, RideOfferStatus.rejected);
      expect(runner.state.queue?.hasPendingOffer, isFalse);
    },
  );

  test(
    'owner mismatch does not mutate offer, queue, policy, or outbox',
    () async {
      final runner = _baseRunner(offerDriverId: 'other-driver');

      final result = await serviceFor(runner)
          .reject(driverId: 'driver-1', offerId: 'offer-1');

      expect(
        (result as AtomicDriverOfferRejectionConflictResult).reason,
        AtomicDriverOfferRejectionConflictReason.offerOwnedByAnotherDriver,
      );
      expect(runner.state.offer.status, RideOfferStatus.pending);
      expect(runner.state.queue?.hasPendingOffer, isTrue);
      expect(runner.state.records, isEmpty);
    },
  );

  test('expired or already processed offers are not changed', () async {
    final expired = _baseRunner(
      offer: _offer(now: now, expiresAt: now),
    );
    final expiredResult = await serviceFor(expired)
        .reject(driverId: 'driver-1', offerId: 'offer-1');
    expect(
      (expiredResult as AtomicDriverOfferRejectionConflictResult).reason,
      AtomicDriverOfferRejectionConflictReason.offerExpired,
    );
    expect(expired.state.offer.status, RideOfferStatus.pending);
    expect(expired.state.queue?.hasPendingOffer, isTrue);

    final processed = _baseRunner(
      offer: _offer(now: now, status: RideOfferStatus.rejected),
    );
    final processedResult = await serviceFor(processed)
        .reject(driverId: 'driver-1', offerId: 'offer-1');
    expect(
      (processedResult as AtomicDriverOfferRejectionConflictResult).reason,
      AtomicDriverOfferRejectionConflictReason.offerAlreadyProcessed,
    );
    expect(processed.state.records, isEmpty);
  });

  test(
    'identical retry returns recorded action without a second sanction',
    () async {
      final runner = _baseRunner(
        consecutiveRejects: 2,
        requestedAt: now.subtract(const Duration(minutes: 2)),
      );
      final service = serviceFor(runner);

      final first = await service.reject(
        driverId: 'driver-1',
        offerId: 'offer-1',
        idempotencyKey: 'same-request',
      );
      final second = await service.reject(
        driverId: 'driver-1',
        offerId: 'offer-1',
        idempotencyKey: 'same-request',
      );

      expect(first, isA<AtomicDriverOfferRejectionApplied>());
      expect(second, isA<AtomicDriverOfferRejectionAlreadyRecorded>());
      expect(runner.state.dispatchState?.penaltyLevel, 1);
      expect(runner.state.records, hasLength(1));
    },
  );

  test(
    'existing accept action conflicts with reject without side effects',
    () async {
      final runner = _baseRunner();
      runner.state.records.add(
        _record(
          action: DriverOfferAction.accept,
          policyOutcome: null,
          redispatchStatus: DriverOfferRedispatchStatus.notRequired,
          idempotencyKey: null,
          now: now,
        ),
      );

      final result = await serviceFor(runner)
          .reject(driverId: 'driver-1', offerId: 'offer-1');

      expect(
        (result as AtomicDriverOfferRejectionConflictResult).reason,
        AtomicDriverOfferRejectionConflictReason.offerActionConflict,
      );
      expect(runner.state.offer.status, RideOfferStatus.pending);
      expect(runner.state.queue?.hasPendingOffer, isTrue);
      expect(runner.state.records, hasLength(1));
    },
  );

  test('reused idempotency key on another offer is a conflict', () async {
    final runner = _baseRunner();
    runner.state.records.add(
      _record(
        offerId: 'offer-2',
        action: DriverOfferAction.reject,
        policyOutcome: 'standard_eligible',
        redispatchStatus: DriverOfferRedispatchStatus.queued,
        idempotencyKey: 'reused-key',
        now: now,
      ),
    );

    final result = await serviceFor(runner).reject(
      driverId: 'driver-1',
      offerId: 'offer-1',
      idempotencyKey: 'reused-key',
    );

    expect(
      (result as AtomicDriverOfferRejectionConflictResult).reason,
      AtomicDriverOfferRejectionConflictReason.idempotencyConflict,
    );
    expect(runner.state.offer.status, RideOfferStatus.pending);
    expect(runner.state.queue?.hasPendingOffer, isTrue);
    expect(runner.state.records, hasLength(1));
  });

  test('policy update failure rolls back all transaction state', () async {
    final runner = _baseRunner(failPolicyUpdate: true);
    final before = runner.state.snapshot();

    await expectLater(
      serviceFor(runner).reject(driverId: 'driver-1', offerId: 'offer-1'),
      throwsA(isA<StateError>()),
    );

    expect(runner.state.sameAs(before), isTrue);
  });

  test(
    'outbox insert failure rolls back policy, offer, and queue changes',
    () async {
      final runner = _baseRunner(failOutboxInsert: true);
      final before = runner.state.snapshot();

      await expectLater(
        serviceFor(runner).reject(driverId: 'driver-1', offerId: 'offer-1'),
        throwsA(isA<StateError>()),
      );

      expect(runner.state.sameAs(before), isTrue);
    },
  );

  test(
    'outbox uniqueness conflict after writes forces a full rollback',
    () async {
      final runner = _baseRunner(forceInsertConflict: true);
      final before = runner.state.snapshot();

      final result = await serviceFor(runner)
          .reject(driverId: 'driver-1', offerId: 'offer-1');

      expect(
        (result as AtomicDriverOfferRejectionConflictResult).reason,
        AtomicDriverOfferRejectionConflictReason.offerActionConflict,
      );
      expect(runner.state.sameAs(before), isTrue);
    },
  );

  test('request hash is stable, versioned semantic SHA-256', () {
    final first = AtomicDriverOfferRejectionService.requestHashForReject(
      driverId: 'driver-1',
      offerId: 'offer-1',
    );
    final retry = AtomicDriverOfferRejectionService.requestHashForReject(
      driverId: 'driver-1',
      offerId: 'offer-1',
    );
    final otherOffer = AtomicDriverOfferRejectionService.requestHashForReject(
      driverId: 'driver-1',
      offerId: 'offer-2',
    );

    expect(first, hasLength(64));
    expect(first, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(first, retry);
    expect(first, isNot(otherOffer));
  });
}

_MemoryRunner _baseRunner({
  DriverOfferRejectionOffer? offer,
  String offerDriverId = 'driver-1',
  DateTime? requestedAt,
  int consecutiveRejects = 0,
  bool failPolicyUpdate = false,
  bool failOutboxInsert = false,
  bool forceInsertConflict = false,
}) {
  final now = DateTime.utc(2026, 10, 25, 12);
  return _MemoryRunner(
    _MemoryState(
      offer: offer ?? _offer(now: now, driverId: offerDriverId),
      requestedAt: requestedAt ?? now.subtract(const Duration(minutes: 2)),
      queue: _availableQueue(),
      dispatchState: DriverDispatchState(
        driverId: 'driver-1',
        consecutiveRejects: consecutiveRejects,
        penaltyLevel: 0,
        dispatchBlockedUntil: null,
        penaltyResetEligibleAt: null,
      ),
      failPolicyUpdate: failPolicyUpdate,
      failOutboxInsert: failOutboxInsert,
      forceInsertConflict: forceInsertConflict,
    ),
  );
}

DriverOfferRejectionQueue _availableQueue() => const DriverOfferRejectionQueue(
  shiftId: 'shift-1',
  vehicleId: 'vehicle-1',
  availability: 'available',
  hasPendingOffer: true,
);

DriverOfferRejectionOffer _offer({
  required DateTime now,
  String driverId = 'driver-1',
  int dispatchRound = 1,
  DateTime? expiresAt,
  RideOfferStatus status = RideOfferStatus.pending,
}) => DriverOfferRejectionOffer(
  id: 'offer-1',
  rideId: 'ride-1',
  driverId: driverId,
  vehicleId: 'vehicle-1',
  dispatchRound: dispatchRound,
  offeredAt: now.subtract(const Duration(seconds: 1)),
  expiresAt: expiresAt ?? now.add(const Duration(seconds: 14)),
  status: status,
);

DriverOfferActionOutboxRecord _record({
  String offerId = 'offer-1',
  required DriverOfferAction action,
  required String? policyOutcome,
  required DriverOfferRedispatchStatus redispatchStatus,
  required String? idempotencyKey,
  required DateTime now,
}) => DriverOfferActionOutboxRecord(
  actionId: 'existing-action',
  offerId: offerId,
  driverId: 'driver-1',
  action: action,
  idempotencyKey: idempotencyKey,
  requestHash: AtomicDriverOfferRejectionService.requestHashForReject(
    driverId: 'driver-1',
    offerId: offerId,
  ),
  policyOutcome: policyOutcome,
  redispatchStatus: redispatchStatus,
  attemptCount: 0,
  availableAt: now,
  leaseToken: null,
  leaseUntil: null,
  lastErrorCode: null,
  redispatchResult: null,
  createdAt: now,
  settledAt: now,
  updatedAt: now,
  redispatchCompletedAt: null,
);

final class _MemoryState {
  _MemoryState({
    required this.offer,
    required this.requestedAt,
    required this.queue,
    required this.dispatchState,
    List<DriverOfferActionOutboxRecord>? records,
    this.failPolicyUpdate = false,
    this.failOutboxInsert = false,
    this.forceInsertConflict = false,
  }) : records = records ?? [];

  DriverOfferRejectionOffer offer;
  DateTime requestedAt;
  DriverOfferRejectionQueue? queue;
  DriverDispatchState? dispatchState;
  List<DriverOfferActionOutboxRecord> records;
  bool failPolicyUpdate;
  bool failOutboxInsert;
  bool forceInsertConflict;

  _MemoryState copy() => _MemoryState(
    offer: offer,
    requestedAt: requestedAt,
    queue: queue,
    dispatchState: dispatchState,
    records: [...records],
    failPolicyUpdate: failPolicyUpdate,
    failOutboxInsert: failOutboxInsert,
    forceInsertConflict: forceInsertConflict,
  );

  _MemoryState snapshot() => copy();

  bool sameAs(_MemoryState other) =>
      offer.status == other.offer.status &&
      offer.expiresAt == other.offer.expiresAt &&
      queue?.hasPendingOffer == other.queue?.hasPendingOffer &&
      queue?.shiftId == other.queue?.shiftId &&
      dispatchState?.consecutiveRejects ==
          other.dispatchState?.consecutiveRejects &&
      dispatchState?.penaltyLevel == other.dispatchState?.penaltyLevel &&
      dispatchState?.dispatchBlockedUntil ==
          other.dispatchState?.dispatchBlockedUntil &&
      dispatchState?.requiresCompletedRideAfterPenalty ==
          other.dispatchState?.requiresCompletedRideAfterPenalty &&
      records.length == other.records.length;
}

final class _MemoryRunner implements DriverOfferRejectionTransactionRunner {
  _MemoryRunner(this.state);

  _MemoryState state;

  @override
  Future<T> run<T>(
    Future<T> Function(DriverOfferRejectionTransaction transaction) action,
  ) async {
    final working = state.copy();
    final result = await action(_MemoryTransaction(working));
    state = working;
    return result;
  }
}

final class _MemoryTransaction implements DriverOfferRejectionTransaction {
  _MemoryTransaction(this.state);

  final _MemoryState state;

  @override
  Future<DriverOfferRejectionOffer?> lockOffer(String offerId) async =>
      state.offer.id == offerId ? state.offer : null;

  @override
  Future<DateTime?> findRideRequestedAt(String rideId) async =>
      rideId == state.offer.rideId ? state.requestedAt : null;

  @override
  Future<DriverOfferRejectionQueue?> lockActiveQueue(String driverId) async =>
      state.queue;

  @override
  Future<DriverOfferActionOutboxRecord?> findActionForDriver({
    required String offerId,
    required String driverId,
  }) async {
    for (final record in state.records) {
      if (record.offerId == offerId && record.driverId == driverId) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<DriverOfferActionOutboxRecord?> findActionByIdempotencyKey({
    required String driverId,
    required String idempotencyKey,
  }) async {
    for (final record in state.records) {
      if (record.driverId == driverId &&
          record.idempotencyKey == idempotencyKey) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<DriverDispatchState> updateDispatchState({
    required String driverId,
    required DriverDispatchState Function(DriverDispatchState) transform,
  }) async {
    if (state.failPolicyUpdate) {
      state.dispatchState = const DriverDispatchState(
        driverId: 'driver-1',
        consecutiveRejects: 99,
        penaltyLevel: 99,
        dispatchBlockedUntil: null,
        penaltyResetEligibleAt: null,
      );
      throw StateError('Synthetic policy update failure.');
    }
    final current =
        state.dispatchState ??
        DriverDispatchState(
          driverId: driverId,
          consecutiveRejects: 0,
          penaltyLevel: 0,
          dispatchBlockedUntil: null,
          penaltyResetEligibleAt: null,
        );
    final next = transform(current);
    state.dispatchState = next;
    return next;
  }

  @override
  Future<bool> rejectPendingOffer({
    required String offerId,
    required String driverId,
    required DateTime rejectedAt,
  }) async {
    if (state.offer.id != offerId ||
        state.offer.driverId != driverId ||
        state.offer.status != RideOfferStatus.pending) {
      return false;
    }
    state.offer = DriverOfferRejectionOffer(
      id: state.offer.id,
      rideId: state.offer.rideId,
      driverId: state.offer.driverId,
      vehicleId: state.offer.vehicleId,
      dispatchRound: state.offer.dispatchRound,
      offeredAt: state.offer.offeredAt,
      expiresAt: state.offer.expiresAt,
      status: RideOfferStatus.rejected,
    );
    return true;
  }

  @override
  Future<bool> releaseQueue({
    required String shiftId,
    required DateTime queuePrioritySince,
  }) async {
    if (state.queue?.shiftId != shiftId ||
        state.queue?.availability != 'available' ||
        state.queue?.hasPendingOffer != true) {
      return false;
    }
    final queue = state.queue!;
    state.queue = DriverOfferRejectionQueue(
      shiftId: queue.shiftId,
      vehicleId: queue.vehicleId,
      availability: queue.availability,
      hasPendingOffer: false,
    );
    return true;
  }

  @override
  Future<DriverOfferActionInsertResult> insertAction(
    DriverOfferActionOutboxRecord record,
  ) async {
    if (state.failOutboxInsert) {
      throw StateError('Synthetic outbox insert failure.');
    }
    if (state.forceInsertConflict) {
      return const DriverOfferActionOfferConflict();
    }
    for (final existing in state.records) {
      if (record.idempotencyKey != null &&
          existing.driverId == record.driverId &&
          existing.idempotencyKey == record.idempotencyKey) {
        return existing.hasSameRequestAs(record)
            ? DriverOfferActionAlreadyExists(record: existing)
            : const DriverOfferActionIdempotencyConflict();
      }
      if (existing.offerId == record.offerId) {
        return existing.hasSameRequestAs(record)
            ? DriverOfferActionAlreadyExists(record: existing)
            : const DriverOfferActionOfferConflict();
      }
    }
    state.records.add(record);
    return DriverOfferActionInserted(record);
  }
}
