import 'package:uuid/uuid.dart';

import 'driver_offer_action_outbox_repository.dart';
import 'driver_offer_action_outbox_worker_repository.dart';

/// Result reported by a redispatch adapter.
///
/// Only [DriverOfferRedispatchConfirmed] is sufficient to mark a job
/// completed. Unknown outcomes are moved to `needs_review`, since retrying a
/// potentially completed external action could duplicate dispatch work.
sealed class DriverOfferRedispatchExecutionResult {
  const DriverOfferRedispatchExecutionResult();
}

final class DriverOfferRedispatchConfirmed
    extends DriverOfferRedispatchExecutionResult {
  const DriverOfferRedispatchConfirmed();
}

final class DriverOfferRedispatchTemporaryFailure
    extends DriverOfferRedispatchExecutionResult {
  const DriverOfferRedispatchTemporaryFailure({
    this.errorCode = DriverOfferActionOutboxErrorCode.transientFailure,
  });

  final DriverOfferActionOutboxErrorCode errorCode;
}

final class DriverOfferRedispatchPermanentFailure
    extends DriverOfferRedispatchExecutionResult {
  const DriverOfferRedispatchPermanentFailure({
    this.errorCode = DriverOfferActionOutboxErrorCode.permanentFailure,
  });

  final DriverOfferActionOutboxErrorCode errorCode;
}

final class DriverOfferRedispatchOutcomeUnknown
    extends DriverOfferRedispatchExecutionResult {
  const DriverOfferRedispatchOutcomeUnknown({
    this.errorCode = DriverOfferActionOutboxErrorCode.outcomeUnknown,
  });

  final DriverOfferActionOutboxErrorCode errorCode;
}

/// Adapter boundary for future, idempotent redispatch continuation.
///
/// The stable [DriverOfferActionOutboxRecord.actionId] must be available to a
/// future implementation as its idempotency identity. This interface is not
/// currently connected to production dispatch services.
abstract interface class DriverOfferRedispatchExecutor {
  Future<DriverOfferRedispatchExecutionResult> execute(
    DriverOfferActionOutboxRecord action,
  );
}

enum DriverOfferActionOutboxWorkerDisposition {
  idle,
  completed,
  retryScheduled,
  needsReview,
  leaseLost,
}

final class DriverOfferActionOutboxWorkerResult {
  const DriverOfferActionOutboxWorkerResult({
    required this.disposition,
    this.actionId,
    this.attemptCount,
    this.retryAfter,
  });

  final DriverOfferActionOutboxWorkerDisposition disposition;
  final String? actionId;
  final int? attemptCount;
  final Duration? retryAfter;
}

/// Executes at most one durable outbox job per call.
///
/// Claim and finalization use short repository transactions. The executor is
/// awaited only after the claim transaction has committed.
final class DriverOfferActionOutboxWorker {
  DriverOfferActionOutboxWorker({
    required this.repository,
    required this.executor,
    this.leaseDuration = const Duration(seconds: 30),
    this.maxAttempts = 5,
    this.baseRetryDelay = const Duration(seconds: 5),
    this.maxRetryDelay = const Duration(minutes: 5),
    String Function()? leaseTokenFactory,
  }) : leaseTokenFactory = leaseTokenFactory ?? const Uuid().v4 {
    if (leaseDuration.inMilliseconds <= 0) {
      throw ArgumentError.value(leaseDuration, 'leaseDuration');
    }
    if (maxAttempts < 1) {
      throw ArgumentError.value(maxAttempts, 'maxAttempts');
    }
    if (baseRetryDelay.inMilliseconds <= 0 ||
        maxRetryDelay.inMilliseconds < baseRetryDelay.inMilliseconds) {
      throw ArgumentError('Retry delays must be positive and ordered.');
    }
  }

  final DriverOfferActionOutboxWorkerRepository repository;
  final DriverOfferRedispatchExecutor executor;
  final Duration leaseDuration;
  final int maxAttempts;
  final Duration baseRetryDelay;
  final Duration maxRetryDelay;
  final String Function() leaseTokenFactory;

  Future<DriverOfferActionOutboxWorkerResult> runOnce() async {
    final leaseToken = leaseTokenFactory();
    final action = await repository.claimNext(
      leaseToken: leaseToken,
      leaseDuration: leaseDuration,
      maxAttempts: maxAttempts,
    );
    if (action == null) {
      return const DriverOfferActionOutboxWorkerResult(
        disposition: DriverOfferActionOutboxWorkerDisposition.idle,
      );
    }
    if (action.action != DriverOfferAction.reject ||
        action.redispatchStatus != DriverOfferRedispatchStatus.leased ||
        action.leaseToken != leaseToken ||
        action.leaseUntil == null ||
        action.attemptCount < 1) {
      throw StateError('Outbox repository returned an invalid lease.');
    }

    DriverOfferRedispatchExecutionResult executionResult;
    try {
      executionResult = await executor.execute(action);
    } on Object {
      // The exception may have happened after an external side effect. Do not
      // persist its text or claim success; stop automatic retries for review.
      final updated = await repository.markNeedsReview(
        actionId: action.actionId,
        leaseToken: leaseToken,
        errorCode: DriverOfferActionOutboxErrorCode.unexpectedFailure,
      );
      return _finalizedResult(
        action: action,
        updated: updated,
        disposition: DriverOfferActionOutboxWorkerDisposition.needsReview,
      );
    }

    return switch (executionResult) {
      DriverOfferRedispatchConfirmed() => _complete(action, leaseToken),
      DriverOfferRedispatchTemporaryFailure(:final errorCode) => _retryOrReview(
        action,
        leaseToken,
        errorCode,
      ),
      DriverOfferRedispatchPermanentFailure(:final errorCode) => _needsReview(
        action,
        leaseToken,
        errorCode,
      ),
      DriverOfferRedispatchOutcomeUnknown(:final errorCode) => _needsReview(
        action,
        leaseToken,
        errorCode,
      ),
    };
  }

  Future<DriverOfferActionOutboxWorkerResult> _complete(
    DriverOfferActionOutboxRecord action,
    String leaseToken,
  ) async {
    final updated = await repository.markCompleted(
      actionId: action.actionId,
      leaseToken: leaseToken,
    );
    return _finalizedResult(
      action: action,
      updated: updated,
      disposition: DriverOfferActionOutboxWorkerDisposition.completed,
    );
  }

  Future<DriverOfferActionOutboxWorkerResult> _retryOrReview(
    DriverOfferActionOutboxRecord action,
    String leaseToken,
    DriverOfferActionOutboxErrorCode errorCode,
  ) async {
    if (action.attemptCount >= maxAttempts) {
      return _needsReview(
        action,
        leaseToken,
        DriverOfferActionOutboxErrorCode.attemptsExhausted,
      );
    }
    final delay = retryDelayForAttempt(action.attemptCount);
    final updated = await repository.markRetryable(
      actionId: action.actionId,
      leaseToken: leaseToken,
      retryAfter: delay,
      errorCode: errorCode,
    );
    return _finalizedResult(
      action: action,
      updated: updated,
      disposition: DriverOfferActionOutboxWorkerDisposition.retryScheduled,
      retryAfter: delay,
    );
  }

  Future<DriverOfferActionOutboxWorkerResult> _needsReview(
    DriverOfferActionOutboxRecord action,
    String leaseToken,
    DriverOfferActionOutboxErrorCode errorCode,
  ) async {
    final updated = await repository.markNeedsReview(
      actionId: action.actionId,
      leaseToken: leaseToken,
      errorCode: errorCode,
    );
    return _finalizedResult(
      action: action,
      updated: updated,
      disposition: DriverOfferActionOutboxWorkerDisposition.needsReview,
    );
  }

  DriverOfferActionOutboxWorkerResult _finalizedResult({
    required DriverOfferActionOutboxRecord action,
    required bool updated,
    required DriverOfferActionOutboxWorkerDisposition disposition,
    Duration? retryAfter,
  }) => DriverOfferActionOutboxWorkerResult(
    disposition: updated
        ? disposition
        : DriverOfferActionOutboxWorkerDisposition.leaseLost,
    actionId: action.actionId,
    attemptCount: action.attemptCount,
    retryAfter: retryAfter,
  );

  Duration retryDelayForAttempt(int attemptCount) {
    if (attemptCount < 1) {
      throw ArgumentError.value(attemptCount, 'attemptCount');
    }
    final maxMilliseconds = maxRetryDelay.inMilliseconds;
    var delayMilliseconds = baseRetryDelay.inMilliseconds;
    for (var attempt = 1; attempt < attemptCount; attempt++) {
      if (delayMilliseconds >= maxMilliseconds ~/ 2) {
        return maxRetryDelay;
      }
      delayMilliseconds *= 2;
    }
    if (delayMilliseconds > maxMilliseconds) {
      delayMilliseconds = maxMilliseconds;
    }
    return Duration(milliseconds: delayMilliseconds);
  }
}
