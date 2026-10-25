import 'package:gocity6_backend/dispatch/driver_offer_action_outbox_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_offer_action_outbox_repository.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

void main() {
  final createdAt = DateTime.utc(2026, 10, 24, 12);
  final settledAt = createdAt.add(const Duration(milliseconds: 10));

  DriverOfferActionOutboxRecord record({
    String actionId = 'action-001',
    String offerId = 'offer-001',
    String driverId = 'driver-001',
    DriverOfferAction action = DriverOfferAction.reject,
    String? idempotencyKey = 'request-001',
    String requestHash =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    String? policyOutcome = 'penalty_applied',
    DriverOfferRedispatchStatus redispatchStatus =
        DriverOfferRedispatchStatus.queued,
    int attemptCount = 0,
    DateTime? availableAt,
    String? leaseToken,
    DateTime? leaseUntil,
    String? lastErrorCode,
    Object? redispatchResult,
    DateTime? createdAtOverride,
    DateTime? settledAtOverride,
    DateTime? updatedAt,
    DateTime? redispatchCompletedAt,
  }) => DriverOfferActionOutboxRecord(
    actionId: actionId,
    offerId: offerId,
    driverId: driverId,
    action: action,
    idempotencyKey: idempotencyKey,
    requestHash: requestHash,
    policyOutcome: action == DriverOfferAction.accept ? null : policyOutcome,
    redispatchStatus: action == DriverOfferAction.accept
        ? DriverOfferRedispatchStatus.notRequired
        : redispatchStatus,
    attemptCount: attemptCount,
    availableAt: availableAt ?? createdAt,
    leaseToken: leaseToken,
    leaseUntil: leaseUntil,
    lastErrorCode: lastErrorCode,
    redispatchResult: redispatchResult,
    createdAt: createdAtOverride ?? createdAt,
    settledAt: settledAtOverride ?? settledAt,
    updatedAt: updatedAt ?? settledAt,
    redispatchCompletedAt: redispatchCompletedAt,
  );

  Map<String, Object?> rowOf(DriverOfferActionOutboxRecord value) => {
    'action_id': value.actionId,
    'offer_id': value.offerId,
    'driver_id': value.driverId,
    'action': value.action.name,
    'idempotency_key': value.idempotencyKey,
    'request_hash': value.requestHash,
    'policy_outcome': value.policyOutcome,
    'redispatch_status': value.redispatchStatus.value,
    'attempt_count': value.attemptCount,
    'available_at': value.availableAt,
    'lease_token': value.leaseToken,
    'lease_until': value.leaseUntil,
    'last_error_code': value.lastErrorCode,
    'redispatch_result': value.redispatchResult,
    'created_at': value.createdAt,
    'settled_at': value.settledAt,
    'updated_at': value.updatedAt,
    'redispatch_completed_at': value.redispatchCompletedAt,
  };

  group('DriverOfferActionOutboxRecord', () {
    test('maps nullable fields, JSONB and UTC timestamps', () {
      final value = record(
        redispatchResult: {
          'result': 'offer_created',
          'attempt': 1,
          'metadata': {'eligible': true},
        },
        leaseToken: 'lease-001',
        leaseUntil: createdAt.add(const Duration(seconds: 10)),
        availableAt: createdAt.add(const Duration(seconds: 1)),
        lastErrorCode: 'route_unavailable',
        redispatchStatus: DriverOfferRedispatchStatus.leased,
      );
      final restored = DriverOfferActionOutboxRecord.fromRow(rowOf(value));

      expect(restored.actionId, value.actionId);
      expect(restored.offerId, value.offerId);
      expect(restored.driverId, value.driverId);
      expect(restored.action, DriverOfferAction.reject);
      expect(restored.redispatchStatus, DriverOfferRedispatchStatus.leased);
      expect(restored.idempotencyKey, value.idempotencyKey);
      expect(restored.leaseToken, value.leaseToken);
      expect(restored.leaseUntil, value.leaseUntil);
      expect(restored.lastErrorCode, 'route_unavailable');
      expect(restored.redispatchResult, value.redispatchResult);
      expect(restored.createdAt.isUtc, isTrue);
      expect(restored.settledAt.isUtc, isTrue);
      expect(restored.redispatchCompletedAt, isNull);
    });

    test('serializes JSONB and UTC timestamps for insert', () {
      final value = record(
        idempotencyKey: null,
        redispatchResult: {'result': 'no_candidate', 'count': 0},
      );

      final parameters = value.toInsertParameters();

      expect(
        parameters['redispatchResult'],
        '{"result":"no_candidate","count":0}',
      );
      expect(parameters['idempotencyKey'], isNull);
      expect(parameters['leaseUntil'], isNull);
      expect(parameters['redispatchCompletedAt'], isNull);
      expect((parameters['availableAt']! as DateTime).isUtc, isTrue);
      expect((parameters['createdAt']! as DateTime).isUtc, isTrue);
    });

    test('preserves JSONB scalar strings and SQL NULL distinctly', () {
      final textResult = DriverOfferActionOutboxRecord.fromRow({
        ...rowOf(record()),
        'redispatch_result': 'safe_code',
      });
      final nullResult = DriverOfferActionOutboxRecord.fromRow({
        ...rowOf(record()),
        'redispatch_result': null,
      });

      expect(textResult.redispatchResult, 'safe_code');
      expect(nullResult.redispatchResult, isNull);
    });

    test('distinguishes JSONB null from SQL NULL on PostgreSQL rows', () {
      final values = rowOf(record())..['redispatch_result'] = null;
      final jsonNullRow = _result([values]).single;
      final sqlNullRow = _result(
        [values],
        sqlNullColumns: {'redispatch_result'},
      ).single;

      final jsonNull = DriverOfferActionOutboxRecord.fromResultRow(jsonNullRow);
      final sqlNull = DriverOfferActionOutboxRecord.fromResultRow(sqlNullRow);

      expect(jsonNull.redispatchResult, DriverOfferActionJsonbNull.value);
      expect(jsonNull.toInsertParameters()['redispatchResult'], 'null');
      expect(sqlNull.redispatchResult, isNull);
      expect(sqlNull.toInsertParameters()['redispatchResult'], isNull);
    });

    test('restores completed status and its completion timestamp', () {
      final value = record(
        redispatchStatus: DriverOfferRedispatchStatus.completed,
        redispatchCompletedAt: settledAt,
        attemptCount: 1,
      );

      final restored = DriverOfferActionOutboxRecord.fromRow(rowOf(value));

      expect(restored.redispatchStatus, DriverOfferRedispatchStatus.completed);
      expect(restored.redispatchCompletedAt, settledAt);
    });

    test(
      'reads schema-valid diagnostic text but only inserts sanitized codes',
      () {
        final persisted = DriverOfferActionOutboxRecord.fromRow({
          ...rowOf(record()),
          'last_error_code': 'ROUTE_TIMEOUT',
        });

        expect(persisted.lastErrorCode, 'ROUTE_TIMEOUT');
        expect(() => persisted.toInsertParameters(), throwsFormatException);
        expect(
          record(lastErrorCode: 'route_timeout').toInsertParameters(),
          isNotEmpty,
        );
      },
    );

    test('rejects invalid hash and schema-inconsistent state', () {
      expect(() => record(requestHash: 'not-a-sha256'), throwsFormatException);
      expect(
        () => DriverOfferActionOutboxRecord(
          actionId: 'action-001',
          offerId: 'offer-001',
          driverId: 'driver-001',
          action: DriverOfferAction.accept,
          idempotencyKey: null,
          requestHash: record().requestHash,
          policyOutcome: 'penalty_applied',
          redispatchStatus: DriverOfferRedispatchStatus.queued,
          attemptCount: 0,
          availableAt: createdAt,
          leaseToken: null,
          leaseUntil: null,
          lastErrorCode: null,
          redispatchResult: null,
          createdAt: createdAt,
          settledAt: settledAt,
          updatedAt: settledAt,
          redispatchCompletedAt: null,
        ),
        throwsFormatException,
      );
      expect(
        () => record(redispatchStatus: DriverOfferRedispatchStatus.completed),
        throwsFormatException,
      );
    });
  });

  group('PostgresDriverOfferActionOutboxRepository', () {
    final repository = PostgresDriverOfferActionOutboxRepository();

    test(
      'inserts through the supplied session and returns the inserted row',
      () async {
        final supplied = record(redispatchResult: {'result': 'queued'});
        final session = _FakeSession([
          _result([rowOf(supplied)]),
        ]);

        final result = await repository.insert(
          transaction: session,
          record: supplied,
        );

        expect(result, isA<DriverOfferActionInserted>());
        expect(
          (result as DriverOfferActionInserted).record.offerId,
          'offer-001',
        );
        expect(session.calls, hasLength(1));
        expect(session.calls.single.parameters['offerId'], 'offer-001');
        expect(
          session.calls.single.parameters['redispatchResult'],
          '{"result":"queued"}',
        );
      },
    );

    test(
      'reports an identical action as already existing, not inserted',
      () async {
        final existing = record();
        final session = _FakeSession([
          _result([]),
          _result([rowOf(existing)]),
        ]);

        final result = await repository.insert(
          transaction: session,
          record: record(actionId: 'new-action-id'),
        );

        expect(result, isA<DriverOfferActionAlreadyExists>());
        expect(
          (result as DriverOfferActionAlreadyExists).record.actionId,
          'action-001',
        );
        expect(session.calls, hasLength(2));
        expect(session.calls[1].parameters, {
          'driverId': 'driver-001',
          'idempotencyKey': 'request-001',
        });
      },
    );

    test('recognizes an identical retry with a null idempotency key', () async {
      final existing = record(idempotencyKey: null);
      final session = _FakeSession([
        _result([]),
        _result([]),
        _result([rowOf(existing)]),
      ]);

      final result = await repository.insert(
        transaction: session,
        record: record(actionId: 'new-action-id', idempotencyKey: null),
      );

      expect(result, isA<DriverOfferActionAlreadyExists>());
      expect(
        (result as DriverOfferActionAlreadyExists).record.actionId,
        'action-001',
      );
      expect(session.calls, hasLength(3));
    });

    test(
      'accept versus reject for the same offer is an offer conflict',
      () async {
        final session = _FakeSession([
          _result([]),
          _result([]),
          _result([rowOf(record())]),
        ]);

        final result = await repository.insert(
          transaction: session,
          record: record(
            actionId: 'new-action-id',
            action: DriverOfferAction.accept,
            idempotencyKey: null,
          ),
        );

        expect(result, isA<DriverOfferActionOfferConflict>());
        expect(result, isNot(isA<DriverOfferActionAlreadyExists>()));
      },
    );

    test(
      'same action with a different request hash is an offer conflict',
      () async {
        final session = _FakeSession([
          _result([]),
          _result([]),
          _result([]),
          _result([rowOf(record())]),
        ]);

        final result = await repository.insert(
          transaction: session,
          record: record(
            actionId: 'new-action-id',
            idempotencyKey: 'different-key',
            requestHash: 'b' * 64,
          ),
        );

        expect(result, isA<DriverOfferActionOfferConflict>());
        expect(result, isNot(isA<DriverOfferActionAlreadyExists>()));
      },
    );

    test(
      'same action and hash with a different key is an offer conflict',
      () async {
        final session = _FakeSession([
          _result([]),
          _result([]),
          _result([]),
          _result([rowOf(record())]),
        ]);

        final result = await repository.insert(
          transaction: session,
          record: record(
            actionId: 'new-action-id',
            idempotencyKey: 'other-key',
          ),
        );

        expect(result, isA<DriverOfferActionOfferConflict>());
        expect(result, isNot(isA<DriverOfferActionAlreadyExists>()));
      },
    );

    test(
      'null and non-null idempotency keys are not identical requests',
      () async {
        final existingWithoutKey = record(idempotencyKey: null);
        final sessionWithKey = _FakeSession([
          _result([]),
          _result([]),
          _result([]),
          _result([rowOf(existingWithoutKey)]),
        ]);

        final withKey = await repository.insert(
          transaction: sessionWithKey,
          record: record(actionId: 'new-action-id', idempotencyKey: 'new-key'),
        );

        expect(withKey, isA<DriverOfferActionOfferConflict>());
        expect(withKey, isNot(isA<DriverOfferActionAlreadyExists>()));

        final existingWithKey = record(idempotencyKey: 'request-001');
        final sessionWithoutKey = _FakeSession([
          _result([]),
          _result([]),
          _result([rowOf(existingWithKey)]),
        ]);

        final withoutKey = await repository.insert(
          transaction: sessionWithoutKey,
          record: record(actionId: 'new-action-id', idempotencyKey: null),
        );

        expect(withoutKey, isA<DriverOfferActionOfferConflict>());
        expect(withoutKey, isNot(isA<DriverOfferActionAlreadyExists>()));
      },
    );

    test(
      'reports key reuse with a different request as an idempotency conflict',
      () async {
        final existing = record(offerId: 'other-offer');
        final session = _FakeSession([
          _result([]),
          _result([rowOf(existing)]),
        ]);

        final result = await repository.insert(
          transaction: session,
          record: record(requestHash: 'b' * 64),
        );

        expect(result, isA<DriverOfferActionIdempotencyConflict>());
        expect(session.calls, hasLength(2));
      },
    );

    test(
      'returns an opaque offer conflict for an action owned by another driver',
      () async {
        final session = _FakeSession([
          _result([]),
          _result([]),
          _result([]),
          _result([
            {'action_exists': true},
          ]),
        ]);

        final result = await repository.insert(
          transaction: session,
          record: record(idempotencyKey: null),
        );

        expect(result, isA<DriverOfferActionOfferConflict>());
        expect(result, isNot(isA<DriverOfferActionAlreadyExists>()));
        expect(session.calls, hasLength(4));
        expect(session.calls.last.parameters, {'offerId': 'offer-001'});
      },
    );

    test(
      'does not treat an unclassifiable uniqueness conflict as success',
      () async {
        final session = _FakeSession([
          _result([]),
          _result([]),
          _result([]),
          _result([]),
        ]);

        final result = await repository.insert(
          transaction: session,
          record: record(idempotencyKey: null),
        );

        expect(result, isA<DriverOfferActionConflictUnresolved>());
      },
    );

    test('does not treat an action primary-key collision as success', () async {
      final session = _FakeSession([
        _result([]),
        _result([rowOf(record())]),
      ]);

      await expectLater(
        repository.insert(
          transaction: session,
          record: record(idempotencyKey: null),
        ),
        throwsA(isA<DriverOfferActionIdConflictException>()),
      );
    });

    test('does not swallow unexpected database errors', () async {
      final failure = StateError('synthetic database failure');
      final session = _FakeSession([], failure: failure);

      await expectLater(
        repository.insert(transaction: session, record: record()),
        throwsA(same(failure)),
      );
    });

    test(
      'owner-filtered read returns null for an unknown or foreign action',
      () async {
        final session = _FakeSession([_result([])]);

        final result = await repository.findForDriver(
          session: session,
          offerId: 'offer-001',
          driverId: 'other-driver',
        );

        expect(result, isNull);
        expect(session.calls.single.parameters, {
          'offerId': 'offer-001',
          'driverId': 'other-driver',
        });
      },
    );

    test('reads by driver and idempotency key', () async {
      final expected = record();
      final session = _FakeSession([
        _result([rowOf(expected)]),
      ]);

      final result = await repository.findByDriverAndIdempotencyKey(
        session: session,
        driverId: 'driver-001',
        idempotencyKey: 'request-001',
      );

      expect(result?.actionId, 'action-001');
      expect(session.calls.single.parameters, {
        'driverId': 'driver-001',
        'idempotencyKey': 'request-001',
      });
    });
  });
}

class _FakeSession implements TxSession {
  _FakeSession(this.results, {this.failure});

  final List<Result> results;
  final Object? failure;
  final List<_Call> calls = [];

  @override
  bool get isOpen => true;

  @override
  Future<void> get closed => Future<void>.value();

  @override
  Future<void> rollback() async {}

  @override
  Future<Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
    QueryMode? queryMode,
    Duration? timeout,
  }) async {
    calls.add(
      _Call(query, (parameters as Map?)?.cast<String, Object?>() ?? {}),
    );
    if (failure != null) throw failure!;
    return results.removeAt(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Call {
  const _Call(this.query, this.parameters);

  final Object query;
  final Map<String, Object?> parameters;
}

Result _result(
  List<Map<String, Object?>> rows, {
  Set<String> sqlNullColumns = const {},
}) {
  final names = rows.isEmpty ? <String>[] : rows.first.keys.toList();
  final schema = ResultSchema([
    for (final name in names)
      ResultSchemaColumn(typeOid: 25, type: Type.text, columnName: name),
  ]);
  return Result(
    rows: [
      for (final row in rows)
        ResultRow(
          values: [for (final name in names) row[name]],
          schema: schema,
          sqlNulls: [for (final name in names) sqlNullColumns.contains(name)],
        ),
    ],
    affectedRows: rows.length,
    schema: schema,
  );
}
