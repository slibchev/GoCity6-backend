import 'package:gocity6_backend/auth/driver_token_service.dart';
import 'package:test/test.dart';

void main() {
  group('DriverTokenService', () {
    test('creates and verifies driver token', () {
      final service = DriverTokenService(
        secret: 'test-secret-that-is-long-enough',
      );

      final token = service.createToken(
        driverId: 'driver-001',
        username: 'driver1',
      );

      final payload = service.verifyToken(token);

      expect(payload, isNotNull);
      expect(payload!.driverId, 'driver-001');
      expect(payload.username, 'driver1');
    });

    test('rejects token signed with different secret', () {
      final issuer = DriverTokenService(
        secret: 'first-test-secret',
      );

      final verifier = DriverTokenService(
        secret: 'second-test-secret',
      );

      final token = issuer.createToken(
        driverId: 'driver-001',
        username: 'driver1',
      );

      expect(verifier.verifyToken(token), isNull);
    });

    test('rejects malformed token', () {
      final service = DriverTokenService(
        secret: 'test-secret-that-is-long-enough',
      );

      expect(service.verifyToken('not-a-jwt'), isNull);
    });
  });
}