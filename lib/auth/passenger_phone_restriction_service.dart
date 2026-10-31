import 'package:uuid/uuid.dart';

import 'passenger_phone_identity.dart';

abstract interface class PassengerPhoneRestrictionChecker {
  Future<bool> hasActiveRestriction(String phoneE164);
}

abstract interface class PassengerPhoneRestrictionRepository
    implements PassengerPhoneRestrictionChecker {
  Future<PassengerPhoneRestrictionRecord> imposeRestriction({
    required String restrictionId,
    required String phoneE164,
    required String adminActor,
    required String reason,
    required int? durationSeconds,
  });

  Future<int> liftRestrictions({
    required String phoneE164,
    required String adminActor,
    required String reason,
  });

  Future<List<PassengerPhoneRestrictionRecord>> findRestrictions({
    required String phoneE164,
  });

  Future<List<PassengerPhoneRestrictionAuditRecord>> findAuditHistory({
    required String phoneE164,
  });
}

class PassengerPhoneRestrictionRecord {
  const PassengerPhoneRestrictionRecord({
    required this.restrictionId,
    required this.phoneE164,
    required this.imposedAt,
    required this.expiresAt,
    required this.reason,
    required this.adminActor,
    required this.liftedAt,
    required this.liftedBy,
    required this.liftReason,
  });

  final String restrictionId;
  final String phoneE164;
  final DateTime imposedAt;
  final DateTime? expiresAt;
  final String reason;
  final String adminActor;
  final DateTime? liftedAt;
  final String? liftedBy;
  final String? liftReason;
}

class PassengerPhoneRestrictionAuditRecord {
  const PassengerPhoneRestrictionAuditRecord({
    required this.auditId,
    required this.restrictionId,
    required this.phoneE164,
    required this.action,
    required this.adminActor,
    required this.reason,
    required this.occurredAt,
  });

  final int auditId;
  final String? restrictionId;
  final String phoneE164;
  final String action;
  final String adminActor;
  final String reason;
  final DateTime occurredAt;
}

class PassengerPhoneRestrictionService {
  PassengerPhoneRestrictionService({required this.repository})
    : _uuid = const Uuid();

  final PassengerPhoneRestrictionRepository repository;
  final Uuid _uuid;

  Future<bool> hasActiveRestriction(String phoneE164) {
    _validatePhone(phoneE164);
    return repository.hasActiveRestriction(phoneE164);
  }

  Future<PassengerPhoneRestrictionRecord> impose({
    required String phoneE164,
    required String adminActor,
    required String reason,
    Duration? duration,
  }) {
    _validatePhone(phoneE164);
    _validateAuditFields(adminActor: adminActor, reason: reason);
    if (duration != null && duration.inSeconds <= 0) {
      throw ArgumentError.value(duration, 'duration');
    }

    return repository.imposeRestriction(
      restrictionId: _uuid.v4(),
      phoneE164: phoneE164,
      adminActor: adminActor.trim(),
      reason: reason.trim(),
      durationSeconds: duration?.inSeconds,
    );
  }

  Future<int> lift({
    required String phoneE164,
    required String adminActor,
    required String reason,
  }) {
    _validatePhone(phoneE164);
    _validateAuditFields(adminActor: adminActor, reason: reason);
    return repository.liftRestrictions(
      phoneE164: phoneE164,
      adminActor: adminActor.trim(),
      reason: reason.trim(),
    );
  }

  Future<List<PassengerPhoneRestrictionRecord>> reviewRestrictions({
    required String phoneE164,
  }) {
    _validatePhone(phoneE164);
    return repository.findRestrictions(phoneE164: phoneE164);
  }

  Future<List<PassengerPhoneRestrictionAuditRecord>> reviewAuditHistory({
    required String phoneE164,
  }) {
    _validatePhone(phoneE164);
    return repository.findAuditHistory(phoneE164: phoneE164);
  }

  static void _validatePhone(String phoneE164) {
    if (!isValidE164PhoneNumber(phoneE164)) {
      throw FormatException('Phone number must be in E.164 format.');
    }
  }

  static void _validateAuditFields({
    required String adminActor,
    required String reason,
  }) {
    if (adminActor.trim().isEmpty) {
      throw ArgumentError.value(adminActor, 'adminActor');
    }
    if (reason.trim().isEmpty) {
      throw ArgumentError.value(reason, 'reason');
    }
  }
}
