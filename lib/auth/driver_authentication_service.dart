import 'package:bcrypt/bcrypt.dart';

class DriverAuthRecord {
  const DriverAuthRecord({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.firstName,
    required this.lastName,
    required this.phone,
    required this.isActive,
  });

  final String id;
  final String username;
  final String passwordHash;
  final String firstName;
  final String lastName;
  final String phone;
  final bool isActive;
}

abstract interface class DriverAuthRepository {
  Future<DriverAuthRecord?> findByUsername(String username);
}

class AuthenticatedDriver {
  const AuthenticatedDriver({
    required this.id,
    required this.username,
    required this.firstName,
    required this.lastName,
    required this.phone,
  });

  final String id;
  final String username;
  final String firstName;
  final String lastName;
  final String phone;
}

class DriverAuthenticationService {
  const DriverAuthenticationService({
    required this.repository,
  });

  final DriverAuthRepository repository;

  Future<AuthenticatedDriver?> authenticate({
    required String username,
    required String password,
  }) async {
    final normalizedUsername = username.trim();

    if (normalizedUsername.isEmpty || password.isEmpty) {
      return null;
    }

    final driver = await repository.findByUsername(normalizedUsername);

    if (driver == null || !driver.isActive) {
      return null;
    }

    bool passwordMatches;

    try {
      passwordMatches = BCrypt.checkpw(
        password,
        driver.passwordHash,
      );
    } catch (_) {
      return null;
    }

    if (!passwordMatches) {
      return null;
    }

    return AuthenticatedDriver(
      id: driver.id,
      username: driver.username,
      firstName: driver.firstName,
      lastName: driver.lastName,
      phone: driver.phone,
    );
  }
}