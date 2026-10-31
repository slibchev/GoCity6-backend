import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

/// Derives a cryptographically separate Passenger signing key from the
/// configured Driver key using an explicit domain-separation label.
String derivePassengerTokenSecret(String driverSecret) {
  if (driverSecret.isEmpty) {
    throw ArgumentError.value(
      driverSecret,
      'driverSecret',
      'Must not be empty.',
    );
  }

  final derived = Hmac(
    sha256,
    utf8.encode(driverSecret),
  ).convert(utf8.encode('city6/passenger-jwt-signing-key/v1'));
  return base64UrlEncode(derived.bytes);
}

class PassengerTokenPayload {
  const PassengerTokenPayload({
    required this.passengerId,
    required this.username,
  });

  final String passengerId;
  final String username;
}

class PassengerTokenService {
  PassengerTokenService({
    required String secret,
    this.tokenLifetime = const Duration(hours: 12),
  }) : _secretKey = SecretKey(secret);

  final SecretKey _secretKey;
  final Duration tokenLifetime;

  String createToken({required String passengerId, required String username}) {
    final jwt = JWT(
      {'passengerId': passengerId, 'username': username, 'role': 'passenger'},
      subject: passengerId,
      issuer: 'city6-backend-passenger',
    );

    return jwt.sign(_secretKey, expiresIn: tokenLifetime);
  }

  PassengerTokenPayload? verifyToken(String token) {
    try {
      final jwt = JWT.verify(
        token,
        _secretKey,
        issuer: 'city6-backend-passenger',
      );
      final payload = jwt.payload;
      if (payload is! Map<String, dynamic>) {
        return null;
      }

      final passengerId = payload['passengerId'];
      final username = payload['username'];
      if (passengerId is! String ||
          passengerId.isEmpty ||
          username is! String ||
          username.isEmpty ||
          payload['role'] != 'passenger') {
        return null;
      }

      return PassengerTokenPayload(
        passengerId: passengerId,
        username: username,
      );
    } on JWTException {
      return null;
    }
  }
}
