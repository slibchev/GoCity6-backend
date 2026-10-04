import 'package:bcrypt/bcrypt.dart';
import 'package:gocity6_backend/auth/driver_authentication_service.dart';
import 'package:test/test.dart';

class _FakeDriverAuthRepository implements DriverAuthRepository {
  _FakeDriverAuthRepository(this.driver);

  final DriverAuthRecord? driver;

  @override
  Future<DriverAuthRecord?> findByUsername(String username) async {
    if (driver == null) {
      return null;
    }

    if (driver!.username.toLowerCase() != username.toLowerCase()) {
      return null;
    }

    return driver;
  }
}

void main() {
  group('DriverAuthenticationService', () {
    test('authenticates active driver with correct password', () async {
      final passwordHash = BCrypt.hashpw(
        'secret123',
        BCrypt.gensalt(),
      );

      final repository = _FakeDriverAuthRepository(
        DriverAuthRecord(
          id: 'driver-001',
          username: 'driver1',
          passwordHash: passwordHash,
          firstName: 'Ivan',
          lastName: 'Ivanov',
          phone: '+359888123456',
          isActive: true,
        ),
      );

      final service = DriverAuthenticationService(
        repository: repository,
      );

      final result = await service.authenticate(
        username: 'driver1',
        password: 'secret123',
      );

      expect(result, isNotNull);
      expect(result!.id, 'driver-001');
      expect(result.username, 'driver1');
      expect(result.firstName, 'Ivan');
      expect(result.lastName, 'Ivanov');
      expect(result.phone, '+359888123456');
    });

    test('rejects incorrect password', () async {
      final passwordHash = BCrypt.hashpw(
        'secret123',
        BCrypt.gensalt(),
      );

      final repository = _FakeDriverAuthRepository(
        DriverAuthRecord(
          id: 'driver-001',
          username: 'driver1',
          passwordHash: passwordHash,
          firstName: 'Ivan',
          lastName: 'Ivanov',
          phone: '+359888123456',
          isActive: true,
        ),
      );

      final service = DriverAuthenticationService(
        repository: repository,
      );

      final result = await service.authenticate(
        username: 'driver1',
        password: 'wrong-password',
      );

      expect(result, isNull);
    });

    test('rejects inactive driver', () async {
      final passwordHash = BCrypt.hashpw(
        'secret123',
        BCrypt.gensalt(),
      );

      final repository = _FakeDriverAuthRepository(
        DriverAuthRecord(
          id: 'driver-001',
          username: 'driver1',
          passwordHash: passwordHash,
          firstName: 'Ivan',
          lastName: 'Ivanov',
          phone: '+359888123456',
          isActive: false,
        ),
      );

      final service = DriverAuthenticationService(
        repository: repository,
      );

      final result = await service.authenticate(
        username: 'driver1',
        password: 'secret123',
      );

      expect(result, isNull);
    });
  });
}