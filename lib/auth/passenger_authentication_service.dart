import 'package:bcrypt/bcrypt.dart';

class PassengerAuthRecord {
  const PassengerAuthRecord({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.status,
  });

  final String id;
  final String username;
  final String passwordHash;
  final String status;

  bool get isActive => status == 'active';
}

abstract interface class PassengerAuthRepository {
  Future<PassengerAuthRecord?> findByUsername(String username);
  Future<PassengerAuthRecord?> findById(String passengerId);
}

class AuthenticatedPassenger {
  const AuthenticatedPassenger({required this.id, required this.username});

  final String id;
  final String username;
}

class PassengerAuthenticationService {
  const PassengerAuthenticationService({required this.repository});

  final PassengerAuthRepository repository;

  Future<AuthenticatedPassenger?> authenticate({
    required String username,
    required String password,
  }) async {
    final normalizedUsername = username.trim();
    if (normalizedUsername.isEmpty || password.isEmpty) {
      return null;
    }

    final passenger = await repository.findByUsername(normalizedUsername);
    if (passenger == null || !passenger.isActive) {
      return null;
    }

    try {
      if (!BCrypt.checkpw(password, passenger.passwordHash)) {
        return null;
      }
    } catch (_) {
      return null;
    }

    return AuthenticatedPassenger(
      id: passenger.id,
      username: passenger.username,
    );
  }

  /// Resolves the token subject against PostgreSQL on each authenticated
  /// request so disabled accounts lose access without waiting for token expiry.
  Future<AuthenticatedPassenger?> resolveActiveSession({
    required String passengerId,
  }) async {
    final passenger = await repository.findById(passengerId);
    if (passenger == null || !passenger.isActive) {
      return null;
    }

    return AuthenticatedPassenger(
      id: passenger.id,
      username: passenger.username,
    );
  }
}
