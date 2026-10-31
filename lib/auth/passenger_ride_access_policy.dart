enum PassengerRideAccess { allowed, authenticationRequired, notFound }

/// Keeps legacy unowned rides compatible with the legacy anonymous app while
/// preventing an authenticated Passenger from reading or changing another
/// Passenger's owned ride.
PassengerRideAccess passengerRideAccess({
  required String? ridePassengerId,
  required String? authenticatedPassengerId,
}) {
  if (ridePassengerId == null) {
    return authenticatedPassengerId == null
        ? PassengerRideAccess.allowed
        : PassengerRideAccess.notFound;
  }

  if (authenticatedPassengerId == null) {
    return PassengerRideAccess.authenticationRequired;
  }

  return ridePassengerId == authenticatedPassengerId
      ? PassengerRideAccess.allowed
      : PassengerRideAccess.notFound;
}
