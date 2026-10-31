import 'package:bcrypt/bcrypt.dart';
import 'package:gocity6_backend/auth/driver_token_service.dart';
import 'package:gocity6_backend/auth/passenger_authentication_service.dart';
import 'package:gocity6_backend/auth/passenger_request_identity.dart';
import 'package:gocity6_backend/auth/passenger_token_service.dart';
import 'package:test/test.dart';

class _PassengerRepository implements PassengerAuthRepository {
  _PassengerRepository(Iterable<PassengerAuthRecord> passengers)
    : _byId = {for (final passenger in passengers) passenger.id: passenger},
      _byUsername = {
        for (final passenger in passengers)
          passenger.username.toLowerCase(): passenger,
      };

  final Map<String, PassengerAuthRecord> _byId;
  final Map<String, PassengerAuthRecord> _byUsername;

  @override
  Future<PassengerAuthRecord?> findById(String passengerId) async =>
      _byId[passengerId];

  @override
  Future<PassengerAuthRecord?> findByUsername(String username) async =>
      _byUsername[username.toLowerCase()];
}

void main() {
  const passengerSecret = 'test-passenger-signing-secret';
  const driverSecret = 'test-driver-signing-secret';
  final passwordHash = BCrypt.hashpw(
    'correct horse battery staple',
    BCrypt.gensalt(),
  );
  final repository = _PassengerRepository([
    PassengerAuthRecord(
      id: 'passenger-01',
      username: 'city6_passenger_01',
      passwordHash: passwordHash,
      status: 'active',
    ),
    PassengerAuthRecord(
      id: 'passenger-02',
      username: 'city6_passenger_02',
      passwordHash: passwordHash,
      status: 'active',
    ),
    PassengerAuthRecord(
      id: 'passenger-disabled',
      username: 'disabled',
      passwordHash: passwordHash,
      status: 'disabled',
    ),
  ]);

  test(
    'accepts the correct password and rejects an incorrect password',
    () async {
      final validService = PassengerAuthenticationService(
        repository: repository,
      );
      final authenticated = await validService.authenticate(
        username: ' city6_passenger_01 ',
        password: 'correct horse battery staple',
      );

      expect(authenticated?.id, 'passenger-01');
      expect(authenticated?.username, 'city6_passenger_01');
      expect(
        await validService.authenticate(
          username: 'city6_passenger_01',
          password: 'incorrect',
        ),
        isNull,
      );
      expect(
        await validService.authenticate(
          username: 'unknown',
          password: 'anything',
        ),
        isNull,
      );
      expect(
        await validService.authenticate(
          username: 'disabled',
          password: 'correct horse battery staple',
        ),
        isNull,
      );
    },
  );

  test('Passenger JWT is role-separated from Driver JWT', () async {
    final passengerService = PassengerTokenService(secret: passengerSecret);
    final driverService = DriverTokenService(secret: driverSecret);
    final passengerToken = passengerService.createToken(
      passengerId: 'passenger-01',
      username: 'city6_passenger_01',
    );
    final driverToken = driverService.createToken(
      driverId: 'driver-01',
      username: 'driver',
    );

    expect(
      passengerService.verifyToken(passengerToken)?.passengerId,
      'passenger-01',
    );
    expect(driverService.verifyToken(passengerToken), isNull);
    expect(passengerService.verifyToken(driverToken), isNull);
  });

  test(
    'session resolution reloads current account status from repository',
    () async {
      final service = PassengerAuthenticationService(repository: repository);
      final active = await service.resolveActiveSession(
        passengerId: 'passenger-02',
      );
      final disabled = await service.resolveActiveSession(
        passengerId: 'passenger-disabled',
      );

      expect(active?.id, 'passenger-02');
      expect(disabled, isNull);
    },
  );

  test(
    'authorization resolver distinguishes anonymous and invalid tokens',
    () async {
      final service = PassengerAuthenticationService(repository: repository);
      final tokenService = PassengerTokenService(secret: passengerSecret);

      final anonymous = await resolvePassengerRequestIdentity(
        authorizationHeader: null,
        authenticationService: service,
        tokenService: tokenService,
      );
      final invalid = await resolvePassengerRequestIdentity(
        authorizationHeader: 'Bearer not-a-token',
        authenticationService: service,
        tokenService: tokenService,
      );

      expect(anonymous.state, PassengerIdentityState.anonymous);
      expect(invalid.state, PassengerIdentityState.invalid);
    },
  );
}
