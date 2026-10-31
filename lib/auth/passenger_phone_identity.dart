bool isValidE164PhoneNumber(String value) =>
    RegExp(r'^\+[1-9][0-9]{1,14}$').hasMatch(value);

enum PassengerPhoneAssignmentResult {
  assigned,
  changed,
  unchanged,
  passengerNotFound,
  restricted,
}

class PassengerPhoneIdentityAuditRecord {
  const PassengerPhoneIdentityAuditRecord({
    required this.passengerId,
    required this.phoneE164,
    required this.action,
    required this.adminActor,
    required this.reason,
    required this.occurredAt,
  });

  final String passengerId;
  final String phoneE164;
  final String action;
  final String adminActor;
  final String reason;
  final DateTime occurredAt;
}

abstract interface class PassengerPhoneIdentityRepository {
  Future<PassengerPhoneAssignmentResult> assignUnverifiedPhone({
    required String passengerId,
    required String phoneE164,
    required String adminActor,
    required String reason,
  });

  Future<PassengerPhoneAssignmentResult> clearPhone({
    required String passengerId,
    required String adminActor,
    required String reason,
  });

  Future<List<PassengerPhoneIdentityAuditRecord>> findPhoneHistory({
    required String passengerId,
  });
}
