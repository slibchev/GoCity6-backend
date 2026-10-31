import 'passenger_phone_identity.dart';

class PassengerPhoneIdentityService {
  const PassengerPhoneIdentityService({required this.repository});

  final PassengerPhoneIdentityRepository repository;

  Future<PassengerPhoneAssignmentResult> assignUnverifiedPhone({
    required String passengerId,
    required String phoneE164,
    required String adminActor,
    required String reason,
  }) {
    _validatePhone(phoneE164);
    _validateAuditFields(adminActor: adminActor, reason: reason);
    if (passengerId.trim().isEmpty) {
      throw ArgumentError.value(passengerId, 'passengerId');
    }

    return repository.assignUnverifiedPhone(
      passengerId: passengerId,
      phoneE164: phoneE164,
      adminActor: adminActor.trim(),
      reason: reason.trim(),
    );
  }

  Future<PassengerPhoneAssignmentResult> clearPhone({
    required String passengerId,
    required String adminActor,
    required String reason,
  }) {
    _validateAuditFields(adminActor: adminActor, reason: reason);
    if (passengerId.trim().isEmpty) {
      throw ArgumentError.value(passengerId, 'passengerId');
    }

    return repository.clearPhone(
      passengerId: passengerId,
      adminActor: adminActor.trim(),
      reason: reason.trim(),
    );
  }

  Future<List<PassengerPhoneIdentityAuditRecord>> reviewHistory({
    required String passengerId,
  }) {
    if (passengerId.trim().isEmpty) {
      throw ArgumentError.value(passengerId, 'passengerId');
    }
    return repository.findPhoneHistory(passengerId: passengerId.trim());
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
