import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

class DriverTokenPayload {
  const DriverTokenPayload({
    required this.driverId,
    required this.username,
  });

  final String driverId;
  final String username;
}

class DriverTokenService {
  DriverTokenService({
    required String secret,
    this.tokenLifetime = const Duration(hours: 12),
  }) : _secretKey = SecretKey(secret);

  final SecretKey _secretKey;
  final Duration tokenLifetime;

  String createToken({
    required String driverId,
    required String username,
  }) {
    final jwt = JWT(
      {
        'driverId': driverId,
        'username': username,
        'role': 'driver',
      },
      subject: driverId,
      issuer: 'city6-backend',
    );

    return jwt.sign(
      _secretKey,
      expiresIn: tokenLifetime,
    );
  }

  DriverTokenPayload? verifyToken(String token) {
    try {
      final jwt = JWT.verify(
        token,
        _secretKey,
        issuer: 'city6-backend',
      );

      final payload = jwt.payload;

      if (payload is! Map<String, dynamic>) {
        return null;
      }

      final driverId = payload['driverId'];
      final username = payload['username'];
      final role = payload['role'];

      if (driverId is! String ||
          driverId.isEmpty ||
          username is! String ||
          username.isEmpty ||
          role != 'driver') {
        return null;
      }

      return DriverTokenPayload(
        driverId: driverId,
        username: username,
      );
    } on JWTException {
      return null;
    }
  }
}