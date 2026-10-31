import 'passenger_authentication_service.dart';
import 'passenger_token_service.dart';

enum PassengerIdentityState { anonymous, authenticated, invalid, unavailable }

class PassengerRequestIdentity {
  const PassengerRequestIdentity._(this.state, this.passenger);

  const PassengerRequestIdentity.anonymous()
    : this._(PassengerIdentityState.anonymous, null);

  const PassengerRequestIdentity.invalid()
    : this._(PassengerIdentityState.invalid, null);

  const PassengerRequestIdentity.unavailable()
    : this._(PassengerIdentityState.unavailable, null);

  PassengerRequestIdentity.authenticated(AuthenticatedPassenger passenger)
    : this._(PassengerIdentityState.authenticated, passenger);

  final PassengerIdentityState state;
  final AuthenticatedPassenger? passenger;
}

Future<PassengerRequestIdentity> resolvePassengerRequestIdentity({
  required String? authorizationHeader,
  required PassengerAuthenticationService? authenticationService,
  required PassengerTokenService? tokenService,
}) async {
  if (authorizationHeader == null) {
    return const PassengerRequestIdentity.anonymous();
  }

  if (authenticationService == null || tokenService == null) {
    return const PassengerRequestIdentity.unavailable();
  }

  final match = RegExp(
    r'^Bearer\s+(.+)$',
    caseSensitive: false,
  ).firstMatch(authorizationHeader.trim());
  if (match == null) {
    return const PassengerRequestIdentity.invalid();
  }

  final payload = tokenService.verifyToken(match.group(1)!.trim());
  if (payload == null) {
    return const PassengerRequestIdentity.invalid();
  }

  final passenger = await authenticationService.resolveActiveSession(
    passengerId: payload.passengerId,
  );
  if (passenger == null) {
    return const PassengerRequestIdentity.invalid();
  }

  return PassengerRequestIdentity.authenticated(passenger);
}
