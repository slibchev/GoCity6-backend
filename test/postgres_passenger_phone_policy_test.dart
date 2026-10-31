import 'dart:io';
import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/auth/passenger_authentication_service.dart';
import 'package:gocity6_backend/auth/passenger_phone_identity.dart';
import 'package:gocity6_backend/auth/passenger_phone_identity_service.dart';
import 'package:gocity6_backend/auth/passenger_phone_restriction_service.dart';
import 'package:gocity6_backend/auth/postgres_passenger_auth_repository.dart';
import 'package:gocity6_backend/auth/postgres_passenger_phone_policy_repository.dart';

void main() {
  final dbPassword = Platform.environment['CITY6_TEST_DB_PASSWORD'];
  final passengerOneId = const Uuid().v4();
  final passengerTwoId = const Uuid().v4();
  final usernameSuffix = const Uuid().v4();
  final passengerOneUsername = 'phone-policy-$usernameSuffix-1';
  final passengerTwoUsername = 'phone-policy-$usernameSuffix-2';
  String createPhone() =>
      '+359${List.generate(10, (_) => Random.secure().nextInt(10)).join()}';
  final phoneE164 = createPhone();
  final expiredPhoneE164 = createPhone();
  final uniquePhoneE164 = createPhone();

  Connection? database;
  late PostgresPassengerPhonePolicyRepository phoneRepository;
  late PassengerPhoneRestrictionService restrictionService;
  late PassengerPhoneIdentityService identityService;

  Future<Connection> openDatabase() {
    final password = dbPassword;
    if (password == null || password.isEmpty) {
      throw StateError('CITY6_TEST_DB_PASSWORD is required.');
    }
    return Connection.open(
      Endpoint(
        host: 'localhost',
        port: 5432,
        database: 'city6_test',
        username: 'city6_app',
        password: password,
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  }

  setUpAll(() async {
    final password = dbPassword;
    if (password == null || password.isEmpty) {
      return;
    }
    database = await openDatabase();
    final identity = await database!.execute(
      'SELECT current_database(), current_user, current_schema(), '
      'host(inet_server_addr()), inet_server_port()',
    );
    expect(identity.single[0], 'city6_test');
    expect(identity.single[1], 'city6_app');
    expect(identity.single[2], 'public');
    expect(['127.0.0.1', '::1'], contains(identity.single[3]));
    expect(identity.single[4], 5432);

    final schema = await database!.execute(
      "SELECT to_regclass('public.passenger_phone_restrictions'), "
      "to_regclass('public.passenger_phone_restriction_audit'), "
      "to_regclass('public.passenger_phone_identity_audit'), "
      "EXISTS (SELECT 1 FROM information_schema.columns "
      "WHERE table_schema='public' AND table_name='passengers' "
      "AND column_name='phone_verified_at')",
    );
    expect(schema.single[0], isNotNull, reason: 'Migration 021 is required.');
    expect(schema.single[1], isNotNull);
    expect(schema.single[2], isNotNull);
    expect(schema.single[3], isTrue);

    phoneRepository = PostgresPassengerPhonePolicyRepository(
      database: database!,
    );
    restrictionService = PassengerPhoneRestrictionService(
      repository: phoneRepository,
    );
    identityService = PassengerPhoneIdentityService(
      repository: phoneRepository,
    );

    await database!.execute(
      Sql.named('''
        INSERT INTO passengers (id, username, password_hash, status)
        VALUES
          (@passengerOneId, @passengerOneUsername, @hashOne, 'active'),
          (@passengerTwoId, @passengerTwoUsername, @hashTwo, 'active')
      '''),
      parameters: {
        'passengerOneId': passengerOneId,
        'passengerOneUsername': passengerOneUsername,
        'hashOne': BCrypt.hashpw('phone-policy-password-one', BCrypt.gensalt()),
        'passengerTwoId': passengerTwoId,
        'passengerTwoUsername': passengerTwoUsername,
        'hashTwo': BCrypt.hashpw('phone-policy-password-two', BCrypt.gensalt()),
      },
    );
  });

  tearDownAll(() async {
    final db = database;
    if (db == null) {
      return;
    }
    try {
      await db.execute(
        Sql.named('''
          DELETE FROM passenger_phone_restriction_audit
          WHERE phone_e164 IN (@phoneE164, @expiredPhoneE164, @uniquePhoneE164)
        '''),
        parameters: {
          'phoneE164': phoneE164,
          'expiredPhoneE164': expiredPhoneE164,
          'uniquePhoneE164': uniquePhoneE164,
        },
      );
      await db.execute(
        Sql.named('''
          DELETE FROM passenger_phone_identity_audit
          WHERE passenger_id IN (@passengerOneId, @passengerTwoId)
        '''),
        parameters: {
          'passengerOneId': passengerOneId,
          'passengerTwoId': passengerTwoId,
        },
      );
      await db.execute(
        Sql.named('''
          DELETE FROM passenger_phone_restrictions
          WHERE phone_e164 IN (@phoneE164, @expiredPhoneE164, @uniquePhoneE164)
        '''),
        parameters: {
          'phoneE164': phoneE164,
          'expiredPhoneE164': expiredPhoneE164,
          'uniquePhoneE164': uniquePhoneE164,
        },
      );
      await db.execute(
        Sql.named('''
          DELETE FROM passengers
          WHERE id IN (@passengerOneId, @passengerTwoId)
        '''),
        parameters: {
          'passengerOneId': passengerOneId,
          'passengerTwoId': passengerTwoId,
        },
      );
      final residue = await db.execute(
        Sql.named('''
          SELECT
            (SELECT count(*) FROM passengers
             WHERE id IN (@passengerOneId, @passengerTwoId))
            + (SELECT count(*) FROM passenger_phone_restrictions
               WHERE phone_e164 = @phoneE164)
            + (SELECT count(*) FROM passenger_phone_restriction_audit
               WHERE phone_e164 IN (@phoneE164, @expiredPhoneE164, @uniquePhoneE164))
            + (SELECT count(*) FROM passenger_phone_identity_audit
               WHERE passenger_id IN (@passengerOneId, @passengerTwoId))
            + (SELECT count(*) FROM passenger_phone_restrictions
               WHERE phone_e164 IN (@expiredPhoneE164, @uniquePhoneE164))
        '''),
        parameters: {
          'passengerOneId': passengerOneId,
          'passengerTwoId': passengerTwoId,
          'phoneE164': phoneE164,
          'expiredPhoneE164': expiredPhoneE164,
          'uniquePhoneE164': uniquePhoneE164,
        },
      );
      expect(
        residue.single[0],
        0,
        reason: 'Phone policy test fixtures remained.',
      );
    } finally {
      await db.close();
    }
  });

  test('verified phone restriction blocks login, sessions, and reassignment; lift restores access', () async {
    final db = database!;
    expect(
      await identityService.assignUnverifiedPhone(
        passengerId: passengerOneId,
        phoneE164: phoneE164,
        adminActor: 'test-admin',
        reason: 'Integration identity assignment',
      ),
      PassengerPhoneAssignmentResult.assigned,
    );

    await db.execute(
      Sql.named('''
          UPDATE passengers
          SET phone_verified_at = clock_timestamp()
          WHERE id = @passengerId
        '''),
      parameters: {'passengerId': passengerOneId},
    );

    final authRepository = PostgresPassengerAuthRepository(database: db);
    final authService = PassengerAuthenticationService(
      repository: authRepository,
      phoneRestrictionChecker: phoneRepository,
    );
    expect(
      (await authService.authenticate(
        username: passengerOneUsername,
        password: 'phone-policy-password-one',
      ))?.id,
      passengerOneId,
    );

    await restrictionService.impose(
      phoneE164: phoneE164,
      adminActor: 'test-admin',
      reason: 'Verified integration restriction',
      duration: const Duration(hours: 1),
    );
    expect(await restrictionService.hasActiveRestriction(phoneE164), isTrue);
    expect(
      await authService.authenticate(
        username: passengerOneUsername,
        password: 'phone-policy-password-one',
      ),
      isNull,
    );
    expect(
      await authService.resolveActiveSession(passengerId: passengerOneId),
      isNull,
    );
    expect(
      await identityService.assignUnverifiedPhone(
        passengerId: passengerTwoId,
        phoneE164: phoneE164,
        adminActor: 'test-admin',
        reason: 'Attempt to reuse restricted phone',
      ),
      PassengerPhoneAssignmentResult.restricted,
    );

    final liftedCount = await restrictionService.lift(
      phoneE164: phoneE164,
      adminActor: 'test-admin-2',
      reason: 'Integration review completed',
    );
    expect(liftedCount, 1);
    expect(await restrictionService.hasActiveRestriction(phoneE164), isFalse);
    expect(
      (await authService.authenticate(
        username: passengerOneUsername,
        password: 'phone-policy-password-one',
      ))?.id,
      passengerOneId,
    );

    final storedPassenger = await authRepository.findById(passengerOneId);
    expect(storedPassenger?.status, 'active');
    expect(storedPassenger?.phoneE164, phoneE164);
    expect(storedPassenger?.phoneVerifiedAt, isNotNull);

    final audit = await restrictionService.reviewAuditHistory(
      phoneE164: phoneE164,
    );
    expect(audit.map((event) => event.action), ['imposed', 'lifted']);
    expect(audit.first.adminActor, 'test-admin');
    expect(audit.first.reason, 'Verified integration restriction');
    expect(audit.last.adminActor, 'test-admin-2');
    expect(audit.last.reason, 'Integration review completed');

    expect(
      await identityService.clearPhone(
        passengerId: passengerOneId,
        adminActor: 'test-admin-2',
        reason: 'Test cleanup identity release',
      ),
      PassengerPhoneAssignmentResult.changed,
    );
    expect(
      await identityService.assignUnverifiedPhone(
        passengerId: passengerTwoId,
        phoneE164: phoneE164,
        adminActor: 'test-admin-2',
        reason: 'Test phone holder change',
      ),
      PassengerPhoneAssignmentResult.assigned,
    );
    expect(
      (await identityService.reviewHistory(passengerId: passengerOneId))
          .map((event) => event.action),
      ['assigned', 'unlinked'],
    );
    expect(
      (await identityService.reviewHistory(passengerId: passengerTwoId))
          .single
          .action,
      'assigned',
    );
    expect(
      await identityService.clearPhone(
        passengerId: passengerTwoId,
        adminActor: 'test-admin-2',
        reason: 'Test cleanup phone release',
      ),
      PassengerPhoneAssignmentResult.changed,
    );
  });

  test('expired and indefinite restrictions use database time and remain auditable', () async {
    final db = database!;
    final expiredRestrictionId = const Uuid().v4();
    await db.execute(
      Sql.named('''
        WITH inserted AS (
          INSERT INTO passenger_phone_restrictions (
            restriction_id,
            phone_e164,
            imposed_at,
            expires_at,
            reason,
            admin_actor
          )
          VALUES (
            @restrictionId::uuid,
            @phoneE164,
            clock_timestamp() - INTERVAL '2 hours',
            clock_timestamp() - INTERVAL '1 hour',
            'Expired restriction fixture',
            'test-admin'
          )
          RETURNING restriction_id, phone_e164, imposed_at
        )
        INSERT INTO passenger_phone_restriction_audit (
          restriction_id,
          phone_e164,
          action,
          admin_actor,
          reason,
          occurred_at
        )
        SELECT
          restriction_id,
          phone_e164,
          'imposed',
          'test-admin',
          'Expired restriction fixture',
          imposed_at
        FROM inserted
      '''),
      parameters: {
        'restrictionId': expiredRestrictionId,
        'phoneE164': expiredPhoneE164,
      },
    );
    expect(
      await restrictionService.hasActiveRestriction(expiredPhoneE164),
      isFalse,
    );
    expect(
      await restrictionService.lift(
        phoneE164: expiredPhoneE164,
        adminActor: 'test-admin',
        reason: 'Record no-active lift action',
      ),
      0,
    );

    final indefinite = await restrictionService.impose(
      phoneE164: expiredPhoneE164,
      adminActor: 'test-admin',
      reason: 'Indefinite restriction fixture',
    );
    expect(indefinite.expiresAt, isNull);
    expect(
      await restrictionService.hasActiveRestriction(expiredPhoneE164),
      isTrue,
    );
    expect(
      await restrictionService.lift(
        phoneE164: expiredPhoneE164,
        adminActor: 'test-admin',
        reason: 'Lift indefinite test restriction',
      ),
      1,
    );
    expect(
      await restrictionService.hasActiveRestriction(expiredPhoneE164),
      isFalse,
    );
    expect(
      (await restrictionService.reviewAuditHistory(phoneE164: expiredPhoneE164))
          .map((event) => event.action),
      ['imposed', 'lift_no_active', 'imposed', 'lifted'],
    );
  });

  test('unique E.164 ownership is enforced by PostgreSQL', () async {
    final db = database!;
    expect(
      await identityService.assignUnverifiedPhone(
        passengerId: passengerOneId,
        phoneE164: uniquePhoneE164,
        adminActor: 'test-admin',
        reason: 'Unique phone fixture assignment',
      ),
      PassengerPhoneAssignmentResult.assigned,
    );
    await expectLater(
      identityService.assignUnverifiedPhone(
        passengerId: passengerTwoId,
        phoneE164: uniquePhoneE164,
        adminActor: 'test-admin',
        reason: 'Duplicate phone fixture assignment',
      ),
      throwsA(anything),
    );
    final secondPassenger = await PostgresPassengerAuthRepository(database: db)
        .findById(passengerTwoId);
    expect(secondPassenger?.phoneE164, isNull);
    expect(secondPassenger?.phoneVerifiedAt, isNull);
  });
}
