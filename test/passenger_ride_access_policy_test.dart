import 'package:gocity6_backend/auth/passenger_ride_access_policy.dart';
import 'package:test/test.dart';

void main() {
  test('Passenger can access own linked ride', () {
    expect(
      passengerRideAccess(
        ridePassengerId: 'passenger-1',
        authenticatedPassengerId: 'passenger-1',
      ),
      PassengerRideAccess.allowed,
    );
  });

  test('another Passenger cannot access linked ride', () {
    expect(
      passengerRideAccess(
        ridePassengerId: 'passenger-1',
        authenticatedPassengerId: 'passenger-2',
      ),
      PassengerRideAccess.notFound,
    );
  });

  test('anonymous caller cannot access a linked ride', () {
    expect(
      passengerRideAccess(
        ridePassengerId: 'passenger-1',
        authenticatedPassengerId: null,
      ),
      PassengerRideAccess.authenticationRequired,
    );
  });

  test('legacy unowned ride remains available only to anonymous clients', () {
    expect(
      passengerRideAccess(
        ridePassengerId: null,
        authenticatedPassengerId: null,
      ),
      PassengerRideAccess.allowed,
    );
    expect(
      passengerRideAccess(
        ridePassengerId: null,
        authenticatedPassengerId: 'passenger-1',
      ),
      PassengerRideAccess.notFound,
    );
  });
}
