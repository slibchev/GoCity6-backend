import 'package:gocity6_backend/auth/passenger_phone_identity.dart';
import 'package:gocity6_backend/auth/passenger_phone_identity_service.dart';
import 'package:gocity6_backend/auth/passenger_phone_restriction_service.dart';
import 'package:test/test.dart';

class _PhonePolicyRepository
    implements
        PassengerPhoneRestrictionRepository,
        PassengerPhoneIdentityRepository {
  final restrictions = <PassengerPhoneRestrictionRecord>[];
  final restrictionAudit = <PassengerPhoneRestrictionAuditRecord>[];
  final phoneAudit = <PassengerPhoneIdentityAuditRecord>[];
  final passengerPhones = <String, String?>{};
  var _nextAuditId = 1;

  @override
  Future<bool> hasActiveRestriction(String phoneE164) async {
    final now = DateTime.now().toUtc();
    return restrictions.any(
      (record) =>
          record.phoneE164 == phoneE164 &&
          record.liftedAt == null &&
          (record.expiresAt == null || record.expiresAt!.isAfter(now)),
    );
  }

  @override
  Future<PassengerPhoneRestrictionRecord> imposeRestriction({
    required String restrictionId,
    required String phoneE164,
    required String adminActor,
    required String reason,
    required int? durationSeconds,
  }) async {
    final now = DateTime.now().toUtc();
    final record = PassengerPhoneRestrictionRecord(
      restrictionId: restrictionId,
      phoneE164: phoneE164,
      imposedAt: now,
      expiresAt: durationSeconds == null
          ? null
          : now.add(Duration(seconds: durationSeconds)),
      reason: reason,
      adminActor: adminActor,
      liftedAt: null,
      liftedBy: null,
      liftReason: null,
    );
    restrictions.add(record);
    restrictionAudit.add(
      PassengerPhoneRestrictionAuditRecord(
        auditId: _nextAuditId++,
        restrictionId: restrictionId,
        phoneE164: phoneE164,
        action: 'imposed',
        adminActor: adminActor,
        reason: reason,
        occurredAt: now,
      ),
    );
    return record;
  }

  @override
  Future<int> liftRestrictions({
    required String phoneE164,
    required String adminActor,
    required String reason,
  }) async {
    final now = DateTime.now().toUtc();
    var liftedCount = 0;
    for (var index = 0; index < restrictions.length; index++) {
      final current = restrictions[index];
      if (current.phoneE164 != phoneE164 ||
          current.liftedAt != null ||
          (current.expiresAt != null && !current.expiresAt!.isAfter(now))) {
        continue;
      }
      restrictions[index] = PassengerPhoneRestrictionRecord(
        restrictionId: current.restrictionId,
        phoneE164: current.phoneE164,
        imposedAt: current.imposedAt,
        expiresAt: current.expiresAt,
        reason: current.reason,
        adminActor: current.adminActor,
        liftedAt: now,
        liftedBy: adminActor,
        liftReason: reason,
      );
      restrictionAudit.add(
        PassengerPhoneRestrictionAuditRecord(
          auditId: _nextAuditId++,
          restrictionId: current.restrictionId,
          phoneE164: phoneE164,
          action: 'lifted',
          adminActor: adminActor,
          reason: reason,
          occurredAt: now,
        ),
      );
      liftedCount++;
    }
    if (liftedCount == 0) {
      restrictionAudit.add(
        PassengerPhoneRestrictionAuditRecord(
          auditId: _nextAuditId++,
          restrictionId: null,
          phoneE164: phoneE164,
          action: 'lift_no_active',
          adminActor: adminActor,
          reason: reason,
          occurredAt: now,
        ),
      );
    }
    return liftedCount;
  }

  @override
  Future<List<PassengerPhoneRestrictionRecord>> findRestrictions({
    required String phoneE164,
  }) async =>
      restrictions.where((record) => record.phoneE164 == phoneE164).toList();

  @override
  Future<List<PassengerPhoneRestrictionAuditRecord>> findAuditHistory({
    required String phoneE164,
  }) async => restrictionAudit
      .where((record) => record.phoneE164 == phoneE164)
      .toList();

  @override
  Future<PassengerPhoneAssignmentResult> assignUnverifiedPhone({
    required String passengerId,
    required String phoneE164,
    required String adminActor,
    required String reason,
  }) async {
    if (!passengerPhones.containsKey(passengerId)) {
      return PassengerPhoneAssignmentResult.passengerNotFound;
    }
    if (await hasActiveRestriction(phoneE164)) {
      return PassengerPhoneAssignmentResult.restricted;
    }
    if (passengerPhones.values.contains(phoneE164)) {
      throw StateError('Phone number is already linked.');
    }
    final previousPhone = passengerPhones[passengerId];
    if (previousPhone == phoneE164) {
      return PassengerPhoneAssignmentResult.unchanged;
    }
    passengerPhones[passengerId] = phoneE164;
    final action = previousPhone == null ? 'assigned' : 'changed';
    _addPhoneAudit(passengerId, phoneE164, action, adminActor, reason);
    return previousPhone == null
        ? PassengerPhoneAssignmentResult.assigned
        : PassengerPhoneAssignmentResult.changed;
  }

  @override
  Future<PassengerPhoneAssignmentResult> clearPhone({
    required String passengerId,
    required String adminActor,
    required String reason,
  }) async {
    if (!passengerPhones.containsKey(passengerId)) {
      return PassengerPhoneAssignmentResult.passengerNotFound;
    }
    final phone = passengerPhones[passengerId];
    if (phone == null) {
      return PassengerPhoneAssignmentResult.unchanged;
    }
    passengerPhones[passengerId] = null;
    _addPhoneAudit(passengerId, phone, 'unlinked', adminActor, reason);
    return PassengerPhoneAssignmentResult.changed;
  }

  @override
  Future<List<PassengerPhoneIdentityAuditRecord>> findPhoneHistory({
    required String passengerId,
  }) async =>
      phoneAudit.where((record) => record.passengerId == passengerId).toList();

  void _addPhoneAudit(
    String passengerId,
    String phoneE164,
    String action,
    String adminActor,
    String reason,
  ) {
    phoneAudit.add(
      PassengerPhoneIdentityAuditRecord(
        passengerId: passengerId,
        phoneE164: phoneE164,
        action: action,
        adminActor: adminActor,
        reason: reason,
        occurredAt: DateTime.now().toUtc(),
      ),
    );
  }
}

void main() {
  test('E.164 validation accepts canonical numbers only', () {
    expect(isValidE164PhoneNumber('+359888123456'), isTrue);
    expect(isValidE164PhoneNumber('+12025550123'), isTrue);
    expect(isValidE164PhoneNumber('359888123456'), isFalse);
    expect(isValidE164PhoneNumber('+012345'), isFalse);
    expect(isValidE164PhoneNumber('+359 888 123 456'), isFalse);
    expect(isValidE164PhoneNumber('+1234567890123456'), isFalse);
  });

  test('temporary and indefinite manual restrictions are auditable', () async {
    final repository = _PhonePolicyRepository();
    final service = PassengerPhoneRestrictionService(repository: repository);

    final temporary = await service.impose(
      phoneE164: '+359888123456',
      adminActor: 'admin-01',
      reason: 'Manual review',
      duration: const Duration(hours: 2),
    );
    final indefinite = await service.impose(
      phoneE164: '+359888123457',
      adminActor: 'admin-02',
      reason: 'Manual indefinite block',
    );

    expect(temporary.expiresAt, isNotNull);
    expect(temporary.expiresAt!.isAfter(temporary.imposedAt), isTrue);
    expect(indefinite.expiresAt, isNull);
    expect(await service.hasActiveRestriction('+359888123456'), isTrue);
    expect(await service.hasActiveRestriction('+359888123457'), isTrue);
    expect(
      (await service.reviewAuditHistory(phoneE164: '+359888123456'))
          .single
          .action,
      'imposed',
    );
  });

  test(
    'manual lift records actor and reason and leaves expired blocks inactive',
    () async {
      final repository = _PhonePolicyRepository();
      final service = PassengerPhoneRestrictionService(repository: repository);
      final restriction = await service.impose(
        phoneE164: '+359888123458',
        adminActor: 'admin-01',
        reason: 'Manual test block',
      );

      expect(
        await service.lift(
          phoneE164: '+359888123458',
          adminActor: 'admin-02',
          reason: 'Reviewed and restored',
        ),
        1,
      );
      expect(await service.hasActiveRestriction('+359888123458'), isFalse);
      final record = (await service.reviewRestrictions(
        phoneE164: '+359888123458',
      )).single;
      expect(record.restrictionId, restriction.restrictionId);
      expect(record.liftedBy, 'admin-02');
      expect(record.liftReason, 'Reviewed and restored');
      expect(
        (await service.reviewAuditHistory(phoneE164: '+359888123458'))
            .map((event) => event.action),
        ['imposed', 'lifted'],
      );

      expect(
        await service.lift(
          phoneE164: '+359888123458',
          adminActor: 'admin-02',
          reason: 'Confirm no active block',
        ),
        0,
      );
      expect(
        (await service.reviewAuditHistory(phoneE164: '+359888123458'))
            .last
            .action,
        'lift_no_active',
      );
    },
  );

  test(
    'phone assignment cannot use a restricted number and changes are audited',
    () async {
      final repository = _PhonePolicyRepository()
        ..passengerPhones.addAll({
          'passenger-one': null,
          'passenger-two': null,
        });
      final restrictionService = PassengerPhoneRestrictionService(
        repository: repository,
      );
      final identityService = PassengerPhoneIdentityService(
        repository: repository,
      );

      await restrictionService.impose(
        phoneE164: '+359888123459',
        adminActor: 'admin-01',
        reason: 'Manual restriction',
      );
      expect(
        await identityService.assignUnverifiedPhone(
          passengerId: 'passenger-one',
          phoneE164: '+359888123459',
          adminActor: 'admin-01',
          reason: 'Attempted association',
        ),
        PassengerPhoneAssignmentResult.restricted,
      );
      expect(
        await identityService.assignUnverifiedPhone(
          passengerId: 'passenger-one',
          phoneE164: '+359888123460',
          adminActor: 'admin-01',
          reason: 'First phone association',
        ),
        PassengerPhoneAssignmentResult.assigned,
      );
      expect(
        await identityService.assignUnverifiedPhone(
          passengerId: 'passenger-one',
          phoneE164: '+359888123461',
          adminActor: 'admin-01',
          reason: 'Phone correction',
        ),
        PassengerPhoneAssignmentResult.changed,
      );
      expect(
        await identityService.clearPhone(
          passengerId: 'passenger-one',
          adminActor: 'admin-01',
          reason: 'Number no longer belongs to account',
        ),
        PassengerPhoneAssignmentResult.changed,
      );
      expect(
        (await identityService.reviewHistory(passengerId: 'passenger-one'))
            .map((event) => event.action),
        ['assigned', 'changed', 'unlinked'],
      );
      expect(
        await restrictionService.hasActiveRestriction('+359888123459'),
        isTrue,
      );
    },
  );

  test('invalid duration and unaudited admin actions are rejected', () async {
    final service = PassengerPhoneRestrictionService(
      repository: _PhonePolicyRepository(),
    );
    expect(
      () => service.impose(
        phoneE164: '+359888123462',
        adminActor: 'admin',
        reason: 'reason',
        duration: Duration.zero,
      ),
      throwsArgumentError,
    );
    expect(
      () => service.impose(
        phoneE164: '+359888123462',
        adminActor: ' ',
        reason: 'reason',
      ),
      throwsArgumentError,
    );
    expect(
      () => service.lift(
        phoneE164: '+359888123462',
        adminActor: 'admin',
        reason: ' ',
      ),
      throwsArgumentError,
    );
  });
}
