import 'dart:convert';

import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:shelf/shelf.dart';

import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:shelf_router/shelf_router.dart';

import 'package:gocity6_backend/ride/assigned_driver_info_service.dart';

import 'package:gocity6_backend/ride/in_memory_ride_request_repository.dart';

import 'package:gocity6_backend/ride/postgres_assigned_driver_info_repository.dart';

import 'package:gocity6_backend/ride/ride_lifecycle_service.dart';

import 'package:gocity6_backend/ride/ride_request.dart';

import 'package:gocity6_backend/ride/ride_dispatch_service.dart';

import 'package:postgres/postgres.dart';

import 'package:gocity6_backend/ride/postgres_ride_request_repository.dart';

import 'package:gocity6_backend/ride/ride_request_repository.dart';

import 'package:uuid/uuid.dart';

import 'package:gocity6_backend/dispatch/atomic_waiting_ride_acceptance_repository.dart';

import 'package:gocity6_backend/dispatch/postgres_atomic_waiting_ride_acceptance_repository.dart';

import 'package:gocity6_backend/dispatch/atomic_ride_reservation_repository.dart';

import 'package:gocity6_backend/dispatch/driver_shift_repository.dart';

import 'package:gocity6_backend/dispatch/postgres_atomic_ride_reservation_repository.dart';

import 'package:gocity6_backend/dispatch/postgres_driver_shift_repository.dart';
import 'package:gocity6_backend/dispatch/driver_assigned_vehicle_repository.dart';
import 'package:gocity6_backend/dispatch/driver_shift_start_service.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_assigned_vehicle_repository.dart';

import 'package:gocity6_backend/routing/google_route_estimator.dart';

import 'package:gocity6_backend/routing/route_estimator.dart';
import 'package:gocity6_backend/auth/driver_authentication_service.dart';
import 'package:gocity6_backend/auth/driver_token_service.dart';
import 'package:gocity6_backend/auth/postgres_driver_auth_repository.dart';
import 'package:gocity6_backend/dispatch/driver_state_service.dart';
import 'package:gocity6_backend/dispatch/driver_work_state_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_driver_work_state_repository.dart';
import 'package:gocity6_backend/dispatch/atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/driver_ride_offer_action_service.dart';
import 'package:gocity6_backend/dispatch/postgres_atomic_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/postgres_ride_offer_repository.dart';
import 'package:gocity6_backend/dispatch/ride_offer_repository.dart';

Future<Map<String, double>> geocodeAddress(
  String address,

  String apiKey,
) async {
  final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
    'address': address,

    'key': apiKey,
  });

  final response = await http.get(uri);

  if (response.statusCode != 200) {
    throw Exception('Geocoding request failed.');
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;

  if (data['status'] != 'OK') {
    throw Exception(
      'Geocoding failed for "$address". '
      'Status: ${data['status']}. '
      'Message: ${data['error_message'] ?? 'No error message'}',
    );
  }

  final results = data['results'] as List<dynamic>;

  final location =
      results.first['geometry']['location'] as Map<String, dynamic>;

  return {
    'lat': (location['lat'] as num).toDouble(),

    'lng': (location['lng'] as num).toDouble(),
  };
}

Future<Map<String, dynamic>> buildRouteWaypoint({
  required String address,

  required String apiKey,

  String? placeId,

  double? latitude,

  double? longitude,
}) async {
  if (latitude != null && longitude != null) {
    return {
      'location': {
        'latLng': {'latitude': latitude, 'longitude': longitude},
      },
    };
  }

  if (placeId != null && placeId.isNotEmpty) {
    return {'placeId': placeId};
  }

  final coordinates = await geocodeAddress(address, apiKey);

  return {
    'location': {
      'latLng': {
        'latitude': coordinates['lat'],

        'longitude': coordinates['lng'],
      },
    },
  };
}

Future<Map<String, dynamic>> calculateRoute(
  String pickup,

  String destination,

  String apiKey, {

  String? pickupPlaceId,

  String? destinationPlaceId,

  double? pickupLatitude,

  double? pickupLongitude,
}) async {
  final origin = await buildRouteWaypoint(
    address: pickup,

    apiKey: apiKey,

    placeId: pickupPlaceId,

    latitude: pickupLatitude,

    longitude: pickupLongitude,
  );

  final destinationWaypoint = await buildRouteWaypoint(
    address: destination,

    apiKey: apiKey,

    placeId: destinationPlaceId,
  );

  final uri = Uri.parse(
    'https://routes.googleapis.com/directions/v2:computeRoutes',
  );

  final response = await http.post(
    uri,

    headers: {
      'Content-Type': 'application/json',

      'X-Goog-Api-Key': apiKey,

      'X-Goog-FieldMask':
          'routes.distanceMeters,'
          'routes.duration,'
          'routes.legs.startLocation,'
          'routes.legs.endLocation,'
          'routes.polyline.encodedPolyline',
    },

    body: jsonEncode({
      'origin': origin,

      'destination': destinationWaypoint,

      'travelMode': 'DRIVE',

      'routingPreference': 'TRAFFIC_AWARE',

      'units': 'METRIC',
    }),
  );

  if (response.statusCode != 200) {
    throw Exception('Route request failed.');
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;

  final routes = data['routes'] as List<dynamic>? ?? <dynamic>[];

  if (routes.isEmpty) {
    throw Exception('No route found. Google response: ${response.body}');
  }

  final route = routes.first as Map<String, dynamic>;

  print('Google route response: ${response.body}');

  final polyline = route['polyline'] as Map<String, dynamic>?;

  final encodedPolyline = polyline?['encodedPolyline'] as String?;

  final distanceMeters = (route['distanceMeters'] as num?)?.toDouble() ?? 0.0;

  final durationText = route['duration'] as String? ?? '0s';

  final durationSeconds = double.parse(durationText.replaceAll('s', ''));

  final legs = route['legs'] as List<dynamic>?;

  if (legs == null || legs.isEmpty) {
    throw Exception('Route has no legs.');
  }

  final firstLeg = legs.first as Map<String, dynamic>;

  final lastLeg = legs.last as Map<String, dynamic>;

  final startLocation = firstLeg['startLocation'] as Map<String, dynamic>;

  final startLatLng = startLocation['latLng'] as Map<String, dynamic>;

  final endLocation = lastLeg['endLocation'] as Map<String, dynamic>;

  final endLatLng = endLocation['latLng'] as Map<String, dynamic>;

  return {
    'distanceKm': distanceMeters / 1000,

    'durationMinutes': durationSeconds / 60,

    'pickupLatitude': (startLatLng['latitude'] as num).toDouble(),

    'pickupLongitude': (startLatLng['longitude'] as num).toDouble(),

    'destinationLatitude': (endLatLng['latitude'] as num).toDouble(),

    'destinationLongitude': (endLatLng['longitude'] as num).toDouble(),

    'encodedPolyline': encodedPolyline,
  };
}

Future<Map<String, dynamic>> rideRequestToJson(
  RideRequest ride, {

  AssignedDriverInfoService? assignedDriverInfoService,
}) async {
  final driverInfo = await assignedDriverInfoService?.findForRide(ride);

  return {
    'id': ride.id,

    'pickup': ride.pickup,

    'destination': ride.destination,

    'passengers': ride.passengers,

    'hasLuggage': ride.hasLuggage,

    'requestedAt': ride.requestedAt.toUtc().toIso8601String(),

    'status': ride.status.name,

    'assignedDriverId': ride.assignedDriverId,

    'assignedVehicleId': ride.assignedVehicleId,

    'driverInfo': driverInfo?.toJson(),

    'currency': ride.currency,

    'meterFareMinor': ride.meterFareMinor,

    'commissionRateBps': ride.commissionRateBps,

    'commissionAmountMinor': ride.commissionAmountMinor,

    'completedByDriverId': ride.completedByDriverId,

    'completedAt': ride.completedAt?.toUtc().toIso8601String(),
  };
}

const corsResponseHeaders = {
  'Access-Control-Allow-Origin': '*',

  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',

  'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept',
};

Middleware corsMiddleware() {
  return createMiddleware(
    requestHandler: (request) {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: corsResponseHeaders);
      }

      return null;
    },

    responseHandler: (response) {
      return response.change(headers: corsResponseHeaders);
    },
  );
}

Future<List<Map<String, String>>> autocompletePlaces(
  String input,

  String apiKey, {

  String? sessionToken,
}) async {
  final response = await http.post(
    Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),

    headers: {
      'Content-Type': 'application/json; charset=utf-8',

      'X-Goog-Api-Key': apiKey,

      'X-Goog-FieldMask':
          'suggestions.placePrediction.placeId,'
          'suggestions.placePrediction.text.text',
    },

    body: jsonEncode({
      'input': input,

      'includedRegionCodes': ['bg'],

      'languageCode': 'bg',

      if (sessionToken != null && sessionToken.isNotEmpty)
        'sessionToken': sessionToken,
    }),
  );

  if (response.statusCode != 200) {
    throw Exception(
      'Places autocomplete failed with status '
      '${response.statusCode}.',
    );
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;

  final suggestions = data['suggestions'] as List<dynamic>? ?? <dynamic>[];

  final results = <Map<String, String>>[];

  for (final suggestion in suggestions) {
    final prediction =
        (suggestion as Map<String, dynamic>)['placePrediction']
            as Map<String, dynamic>?;

    if (prediction == null) {
      continue;
    }

    final placeId = prediction['placeId'] as String?;

    final textData = prediction['text'] as Map<String, dynamic>?;

    final text = textData?['text'] as String?;

    if (placeId != null && text != null) {
      results.add({'placeId': placeId, 'text': text});
    }
  }

  return results;
}

void main(List<String> args) async {
  final apiKey = Platform.environment['GOOGLE_MAPS_API_KEY'];

  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('GOOGLE_MAPS_API_KEY is not configured.');

    exit(1);
  }

  final router = Router();

  final rideStorage = Platform.environment['CITY6_RIDE_STORAGE'] ?? 'memory';

  late final RideRequestRepository rideRepository;
  DriverAuthenticationService? driverAuthenticationService;
  DriverTokenService? driverTokenService;
  DriverAssignedVehicleRepository? driverAssignedVehicleRepository;
  DriverShiftStartService? driverShiftStartService;
  DriverStateService? driverStateService;
  DriverWorkStateRepository? driverWorkStateRepository;
  RideOfferRepository? rideOfferRepository;
  AtomicRideOfferRepository? atomicRideOfferRepository;
  DriverRideOfferActionService? driverRideOfferActionService;

  AssignedDriverInfoService? assignedDriverInfoService;

  AtomicWaitingRideAcceptanceRepository? waitingRideAcceptanceRepository;

  DriverShiftRepository? driverShiftRepository;

  AtomicRideReservationRepository? rideReservationRepository;

  RouteEstimator? routeEstimator;

  if (rideStorage == 'postgres') {
    final databasePassword = Platform.environment['CITY6_DB_PASSWORD'];

    if (databasePassword == null || databasePassword.isEmpty) {
      throw StateError(
        'CITY6_DB_PASSWORD is required when '
        'CITY6_RIDE_STORAGE=postgres.',
      );
    }

    final databasePool = Pool.withEndpoints([
      Endpoint(
        host: 'localhost',

        port: 5432,

        database: 'city6',

        username: 'city6_app',

        password: databasePassword,
      ),
    ], settings: PoolSettings(sslMode: SslMode.disable, maxConnectionCount: 5));

    await databasePool.execute('SELECT 1');

    rideRepository = PostgresRideRequestRepository(database: databasePool);

    assignedDriverInfoService = AssignedDriverInfoService(
      repository: PostgresAssignedDriverInfoRepository(database: databasePool),
    );

    waitingRideAcceptanceRepository =
        PostgresAtomicWaitingRideAcceptanceRepository(database: databasePool);

    driverShiftRepository = PostgresDriverShiftRepository(
      database: databasePool,
    );
    driverWorkStateRepository = PostgresDriverWorkStateRepository(
      database: databasePool,
    );
    rideOfferRepository = PostgresRideOfferRepository(database: databasePool);

    atomicRideOfferRepository = PostgresAtomicRideOfferRepository(
      database: databasePool,
    );
    driverAssignedVehicleRepository = PostgresDriverAssignedVehicleRepository(
      database: databasePool,
    );

    rideReservationRepository = PostgresAtomicRideReservationRepository(
      database: databasePool,
    );

    routeEstimator = GoogleRouteEstimator(apiKey: apiKey);
    final driverJwtSecret = Platform.environment['CITY6_DRIVER_JWT_SECRET'];

    if (driverJwtSecret == null || driverJwtSecret.isEmpty) {
      throw StateError(
        'CITY6_DRIVER_JWT_SECRET is required when '
        'CITY6_RIDE_STORAGE=postgres.',
      );
    }

    driverAuthenticationService = DriverAuthenticationService(
      repository: PostgresDriverAuthRepository(database: databasePool),
    );

    driverTokenService = DriverTokenService(secret: driverJwtSecret);

    print('Ride storage: PostgreSQL');
  } else if (rideStorage == 'memory') {
    rideRepository = InMemoryRideRequestRepository();

    print('Ride storage: in-memory');
  } else {
    throw StateError('Unsupported CITY6_RIDE_STORAGE: $rideStorage');
  }

  final rideLifecycleService = RideLifecycleService(repository: rideRepository);

  final rideDispatchService = RideDispatchService(
    repository: rideRepository,

    waitingRideAcceptanceRepository: waitingRideAcceptanceRepository,

    driverShiftRepository: driverShiftRepository,

    rideReservationRepository: rideReservationRepository,

    routeEstimator: routeEstimator,
  );

  const uuid = Uuid();
  final shiftRepository = driverShiftRepository;
  final assignedVehicleRepository = driverAssignedVehicleRepository;

  if (shiftRepository != null && assignedVehicleRepository != null) {
    driverShiftStartService = DriverShiftStartService(
      shiftRepository: shiftRepository,
      assignedVehicleRepository: assignedVehicleRepository,
      shiftIdFactory: () => uuid.v4(),
      now: () => DateTime.now().toUtc(),
    );
  }
  final workStateRepository = driverWorkStateRepository;

  if (workStateRepository != null) {
    driverStateService = DriverStateService(repository: workStateRepository);
  }
  final offerRepository = rideOfferRepository;
  final atomicOfferRepository = atomicRideOfferRepository;

  if (offerRepository != null && atomicOfferRepository != null) {
    driverRideOfferActionService = DriverRideOfferActionService(
      offerRepository: offerRepository,
      atomicOfferRepository: atomicOfferRepository,
    );
  }

  router.get('/', (Request request) {
    return Response.ok('GoCity6 backend is running');
  });
  router.post('/driver/login', (Request request) async {
    try {
      final authService = driverAuthenticationService;
      final tokenService = driverTokenService;

      if (authService == null || tokenService == null) {
        return Response(
          503,
          body: jsonEncode({'error': 'Driver authentication is unavailable.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final decodedBody = jsonDecode(await request.readAsString());

      if (decodedBody is! Map<String, dynamic>) {
        return Response(
          400,
          body: jsonEncode({'error': 'Request body must be a JSON object.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final username = decodedBody['username'];
      final password = decodedBody['password'];

      if (username is! String ||
          username.trim().isEmpty ||
          password is! String ||
          password.isEmpty) {
        return Response(
          400,
          body: jsonEncode({'error': 'Username and password are required.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final driver = await authService.authenticate(
        username: username,
        password: password,
      );

      if (driver == null) {
        return Response(
          401,
          body: jsonEncode({'error': 'Invalid username or password.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final token = tokenService.createToken(
        driverId: driver.id,
        username: driver.username,
      );

      return Response.ok(
        jsonEncode({
          'token': token,
          'driver': {
            'id': driver.id,
            'username': driver.username,
            'firstName': driver.firstName,
            'lastName': driver.lastName,
            'phone': driver.phone,
          },
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException {
      return Response(
        400,
        body: jsonEncode({'error': 'Invalid JSON body.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Driver login error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Driver login failed.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });
  router.post('/driver/shift/start', (Request request) async {
    final tokenService = driverTokenService;
    final shiftStartService = driverShiftStartService;

    if (tokenService == null || shiftStartService == null) {
      return Response(
        503,
        body: jsonEncode({'error': 'Driver shift service is unavailable.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final authorization = request.headers['authorization'];

    if (authorization == null || !authorization.startsWith('Bearer ')) {
      return Response(
        401,
        body: jsonEncode({'error': 'Authentication required.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final token = authorization.substring(7).trim();
    final tokenPayload = tokenService.verifyToken(token);

    if (tokenPayload == null) {
      return Response(
        401,
        body: jsonEncode({'error': 'Invalid or expired token.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    try {
      final shift = await shiftStartService.start(
        driverId: tokenPayload.driverId,
      );

      return Response.ok(
        jsonEncode({
          'shift': {
            'id': shift.id,
            'driverId': shift.driverId,
            'vehicleId': shift.vehicleId,
            'startedAt': shift.startedAt.toUtc().toIso8601String(),
            'availability': shift.queueState.availability.name,
          },
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } on DriverShiftStartException catch (error) {
      switch (error.failure) {
        case DriverShiftStartFailure.noAssignedVehicle:
          return Response(
            409,
            body: jsonEncode({
              'code': 'noAssignedVehicle',
              'error': 'Driver has no assigned vehicle.',
            }),
            headers: {'Content-Type': 'application/json'},
          );

        case DriverShiftStartFailure.assignedVehicleInactive:
          return Response(
            409,
            body: jsonEncode({
              'code': 'assignedVehicleInactive',
              'error': 'Assigned vehicle is inactive.',
            }),
            headers: {'Content-Type': 'application/json'},
          );
      }
    } catch (error) {
      print('Driver shift start error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Driver shift could not be started.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  router.post('/rides', (Request request) async {
    try {
      final decodedBody = jsonDecode(await request.readAsString());

      if (decodedBody is! Map<String, dynamic>) {
        return Response(
          400,

          body: jsonEncode({'error': 'Request body must be a JSON object.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final pickup = decodedBody['pickup'];

      final destination = decodedBody['destination'];

      final passengers = decodedBody['passengers'];

      final hasLuggage = decodedBody['hasLuggage'];

      if (pickup is! String ||
          pickup.trim().isEmpty ||
          destination is! String ||
          destination.trim().isEmpty) {
        return Response(
          400,

          body: jsonEncode({'error': 'Pickup and destination are required.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      if (passengers is! int || passengers < 1) {
        return Response(
          400,

          body: jsonEncode({'error': 'Passengers must be a positive integer.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      if (hasLuggage != null && hasLuggage is! bool) {
        return Response(
          400,

          body: jsonEncode({'error': 'hasLuggage must be a boolean.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final ride = RideRequest(
        id: uuid.v4(),

        pickup: pickup.trim(),

        destination: destination.trim(),

        passengers: passengers,

        hasLuggage: hasLuggage as bool? ?? false,

        requestedAt: DateTime.now().toUtc(),
      );

      final submittedRide = await rideLifecycleService.submitRide(ride);

      return Response(
        201,

        body: jsonEncode(
          await rideRequestToJson(
            submittedRide,
            assignedDriverInfoService: assignedDriverInfoService,
          ),
        ),

        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException {
      return Response(
        400,

        body: jsonEncode({'error': 'Invalid JSON body.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Create ride error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Ride creation failed.'}),

        headers: {'Content-Type': 'application/json'},
      );
    }
  });
  router.get('/driver/state', (Request request) async {
    final tokenService = driverTokenService;
    final stateService = driverStateService;

    if (tokenService == null || stateService == null) {
      return Response(
        503,
        body: jsonEncode({'error': 'Driver state service is unavailable.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final authorization = request.headers['authorization'];

    if (authorization == null || !authorization.startsWith('Bearer ')) {
      return Response(
        401,
        body: jsonEncode({'error': 'Authentication required.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final token = authorization.substring(7).trim();
    final tokenPayload = tokenService.verifyToken(token);

    if (tokenPayload == null) {
      return Response(
        401,
        body: jsonEncode({'error': 'Invalid or expired token.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    try {
      final state = await stateService.load(driverId: tokenPayload.driverId);

      final shift = state.activeShift;
      final pendingOffer = state.pendingOffer;
      final currentRide = state.currentRide;
      final reservedRide = state.reservedRide;

      return Response.ok(
        jsonEncode({
          'isWorking': state.isWorking,
          'shift': shift == null
              ? null
              : {
                  'id': shift.id,
                  'driverId': shift.driverId,
                  'vehicleId': shift.vehicleId,
                  'startedAt': shift.startedAt.toUtc().toIso8601String(),
                  'queue': {
                    'availability': shift.queueState.availability.name,
                    'queuePrioritySince': shift.queueState.queuePrioritySince
                        .toUtc()
                        .toIso8601String(),
                    'shortBreaksUsed': shift.queueState.shortBreaksUsed,
                    'breakStartedAt': shift.queueState.breakStartedAt
                        ?.toUtc()
                        .toIso8601String(),
                    'hasPendingOffer': shift.queueState.hasPendingOffer,
                  },
                },
          'pendingOffer': pendingOffer == null
              ? null
              : {
                  'id': pendingOffer.offer.id,
                  'rideId': pendingOffer.offer.rideId,
                  'driverId': pendingOffer.offer.driverId,
                  'vehicleId': pendingOffer.offer.vehicleId,
                  'etaSeconds': pendingOffer.offer.etaSeconds,
                  'distanceMeters': pendingOffer.offer.distanceMeters,
                  'dispatchRound': pendingOffer.offer.dispatchRound,
                  'bonusMinor': pendingOffer.offer.bonusMinor,
                  'offeredAt': pendingOffer.offer.offeredAt
                      .toUtc()
                      .toIso8601String(),
                  'expiresAt': pendingOffer.offer.expiresAt
                      .toUtc()
                      .toIso8601String(),
                  'status': pendingOffer.offer.status.name,
                  'ride': await rideRequestToJson(
                    pendingOffer.ride,
                    assignedDriverInfoService: assignedDriverInfoService,
                  ),
                },
          'currentRide': currentRide == null
              ? null
              : await rideRequestToJson(
                  currentRide,
                  assignedDriverInfoService: assignedDriverInfoService,
                ),
          'reservedRide': reservedRide == null
              ? null
              : await rideRequestToJson(
                  reservedRide,
                  assignedDriverInfoService: assignedDriverInfoService,
                ),
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Driver state error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Driver state could not be loaded.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });
  router.post('/driver/offers/<offerId>/accept', (
    Request request,
    String offerId,
  ) async {
    final tokenService = driverTokenService;
    final actionService = driverRideOfferActionService;

    if (tokenService == null || actionService == null) {
      return Response(
        503,
        body: jsonEncode({
          'error': 'Driver offer action service is unavailable.',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final authorization = request.headers['authorization'];

    if (authorization == null || !authorization.startsWith('Bearer ')) {
      return Response(
        401,
        body: jsonEncode({'error': 'Authentication required.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final token = authorization.substring(7).trim();
    final tokenPayload = tokenService.verifyToken(token);

    if (tokenPayload == null) {
      return Response(
        401,
        body: jsonEncode({'error': 'Invalid or expired token.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    try {
      final offer = await actionService.accept(
        driverId: tokenPayload.driverId,
        offerId: offerId,
        now: DateTime.now().toUtc(),
      );

      return Response.ok(
        jsonEncode({
          'id': offer.id,
          'rideId': offer.rideId,
          'status': offer.status.name,
          'resolvedAt': offer.resolvedAt?.toUtc().toIso8601String(),
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } on DriverRideOfferActionException {
      return Response(
        404,
        body: jsonEncode({'error': 'Offer not found.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } on AtomicRideOfferConflictException {
      return Response(
        409,
        body: jsonEncode({'error': 'Offer cannot be accepted.'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Driver offer accept error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Offer acceptance failed.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  router.get('/rides/<rideId>', (Request request, String rideId) async {
    try {
      final ride = await rideLifecycleService.getRide(rideId);

      return Response.ok(
        jsonEncode(
          await rideRequestToJson(
            ride,
            assignedDriverInfoService: assignedDriverInfoService,
          ),
        ),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleNotFoundException {
      return Response(
        404,

        body: jsonEncode({'error': 'Ride not found.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Get ride error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to load ride.'}),

        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  router.post('/rides/<rideId>/cancel', (Request request, String rideId) async {
    try {
      final cancelledRide = await rideLifecycleService.cancelRide(rideId);

      return Response.ok(
        jsonEncode(
          await rideRequestToJson(
            cancelledRide,
            assignedDriverInfoService: assignedDriverInfoService,
          ),
        ),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleNotFoundException {
      return Response(
        404,

        body: jsonEncode({'error': 'Ride not found.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleConflictException {
      return Response(
        409,

        body: jsonEncode({'error': 'Ride cannot be cancelled.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Cancel ride error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Ride cancellation failed.'}),

        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  router.post('/rides/<rideId>/select', (Request request, String rideId) async {
    try {
      final decodedBody = jsonDecode(await request.readAsString());

      if (decodedBody is! Map<String, dynamic>) {
        return Response(
          400,

          body: jsonEncode({'error': 'Request body must be a JSON object.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final driverId = decodedBody['driverId'];

      final vehicleId = decodedBody['vehicleId'];

      final driverLatitude = decodedBody['driverLatitude'];

      final driverLongitude = decodedBody['driverLongitude'];

      if (driverId is! String || driverId.trim().isEmpty) {
        return Response(
          400,

          body: jsonEncode({'error': 'driverId is required.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      if (vehicleId is! String || vehicleId.trim().isEmpty) {
        return Response(
          400,

          body: jsonEncode({'error': 'vehicleId is required.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      if (driverLatitude != null && driverLatitude is! num) {
        return Response(
          400,

          body: jsonEncode({'error': 'driverLatitude must be a number.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      if (driverLongitude != null && driverLongitude is! num) {
        return Response(
          400,

          body: jsonEncode({'error': 'driverLongitude must be a number.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      if ((driverLatitude == null) != (driverLongitude == null)) {
        return Response(
          400,

          body: jsonEncode({
            'error':
                'driverLatitude and driverLongitude must be provided together.',
          }),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final selectedRide = await rideDispatchService.selectWaitingRide(
        rideId: rideId,

        driverId: driverId.trim(),

        vehicleId: vehicleId.trim(),

        driverLatitude: (driverLatitude as num?)?.toDouble(),

        driverLongitude: (driverLongitude as num?)?.toDouble(),

        reservationId: uuid.v4(),

        now: DateTime.now().toUtc(),
      );

      return Response.ok(
        jsonEncode(
          await rideRequestToJson(
            selectedRide,
            assignedDriverInfoService: assignedDriverInfoService,
          ),
        ),

        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException {
      return Response(
        400,

        body: jsonEncode({'error': 'Invalid JSON body.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideDispatchInputException {
      return Response(
        400,

        body: jsonEncode({
          'error': 'Current driver location is required for reservation.',
        }),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideNotFoundException {
      return Response(
        404,

        body: jsonEncode({'error': 'Ride not found.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideDispatchConflictException {
      return Response(
        409,

        body: jsonEncode({'error': 'Ride cannot be selected.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Select ride error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Ride selection failed.'}),

        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  router.post('/rides/<rideId>/promote', (
    Request request,

    String rideId,
  ) async {
    try {
      final decodedBody = jsonDecode(await request.readAsString());

      if (decodedBody is! Map<String, dynamic>) {
        return Response(
          400,

          body: jsonEncode({'error': 'Request body must be a JSON object.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final driverId = decodedBody['driverId'];

      if (driverId is! String || driverId.trim().isEmpty) {
        return Response(
          400,

          body: jsonEncode({'error': 'driverId is required.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final promotedRide = await rideDispatchService.promoteReservedRide(
        rideId: rideId,

        driverId: driverId.trim(),
      );

      return Response.ok(
        jsonEncode(
          await rideRequestToJson(
            promotedRide,
            assignedDriverInfoService: assignedDriverInfoService,
          ),
        ),

        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException {
      return Response(
        400,

        body: jsonEncode({'error': 'Invalid JSON body.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideNotFoundException {
      return Response(
        404,

        body: jsonEncode({'error': 'Ride not found.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideDispatchConflictException {
      return Response(
        409,

        body: jsonEncode({'error': 'Reserved ride cannot be promoted.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Promote ride error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Ride promotion failed.'}),

        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  router.post('/rides/<rideId>/driver-arriving', (
    Request request,

    String rideId,
  ) async {
    try {
      final decodedBody = jsonDecode(await request.readAsString());

      if (decodedBody is! Map<String, dynamic>) {
        return Response(
          400,

          body: jsonEncode({'error': 'Request body must be a JSON object.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final driverId = decodedBody['driverId'];

      if (driverId is! String || driverId.trim().isEmpty) {
        return Response(
          400,

          body: jsonEncode({'error': 'driverId is required.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final updatedRide = await rideLifecycleService.markDriverArriving(
        rideId: rideId,

        driverId: driverId.trim(),
      );

      return Response.ok(
        jsonEncode(
          await rideRequestToJson(
            updatedRide,
            assignedDriverInfoService: assignedDriverInfoService,
          ),
        ),

        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException {
      return Response(
        400,

        body: jsonEncode({'error': 'Invalid JSON body.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleNotFoundException {
      return Response(
        404,

        body: jsonEncode({'error': 'Ride not found.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleConflictException {
      return Response(
        409,

        body: jsonEncode({'error': 'Ride cannot move to driverArriving.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Driver arriving error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to update ride.'}),

        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  router.post('/rides/<rideId>/start', (Request request, String rideId) async {
    try {
      final decodedBody = jsonDecode(await request.readAsString());

      if (decodedBody is! Map<String, dynamic>) {
        return Response(
          400,

          body: jsonEncode({'error': 'Request body must be a JSON object.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final driverId = decodedBody['driverId'];

      if (driverId is! String || driverId.trim().isEmpty) {
        return Response(
          400,

          body: jsonEncode({'error': 'driverId is required.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final updatedRide = await rideLifecycleService.startRide(
        rideId: rideId,

        driverId: driverId.trim(),
      );

      return Response.ok(
        jsonEncode(
          await rideRequestToJson(
            updatedRide,
            assignedDriverInfoService: assignedDriverInfoService,
          ),
        ),

        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException {
      return Response(
        400,

        body: jsonEncode({'error': 'Invalid JSON body.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleNotFoundException {
      return Response(
        404,

        body: jsonEncode({'error': 'Ride not found.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleConflictException {
      return Response(
        409,

        body: jsonEncode({'error': 'Ride cannot be started.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Start ride error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to start ride.'}),

        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  router.post('/rides/<rideId>/complete', (
    Request request,

    String rideId,
  ) async {
    try {
      final decodedBody = jsonDecode(await request.readAsString());

      if (decodedBody is! Map<String, dynamic>) {
        return Response(
          400,

          body: jsonEncode({'error': 'Request body must be a JSON object.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final driverId = decodedBody['driverId'];

      final meterFareMinor = decodedBody['meterFareMinor'];

      if (driverId is! String || driverId.trim().isEmpty) {
        return Response(
          400,

          body: jsonEncode({'error': 'driverId is required.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      if (meterFareMinor is! int || meterFareMinor <= 0) {
        return Response(
          400,

          body: jsonEncode({
            'error': 'meterFareMinor must be a positive integer.',
          }),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final completedRide = await rideLifecycleService.completeRide(
        rideId: rideId,

        driverId: driverId.trim(),

        meterFareMinor: meterFareMinor,
      );

      return Response.ok(
        jsonEncode(
          await rideRequestToJson(
            completedRide,
            assignedDriverInfoService: assignedDriverInfoService,
          ),
        ),

        headers: {'Content-Type': 'application/json'},
      );
    } on FormatException {
      return Response(
        400,

        body: jsonEncode({'error': 'Invalid JSON body.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleNotFoundException {
      return Response(
        404,

        body: jsonEncode({'error': 'Ride not found.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } on RideLifecycleConflictException {
      return Response(
        409,

        body: jsonEncode({'error': 'Ride cannot be completed.'}),

        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Complete ride error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Ride completion failed.'}),

        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  router.post('/route', (Request request) async {
    try {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;

      final pickup = body['pickup'] as String?;

      final destination = body['destination'] as String?;

      final pickupPlaceId = body['pickupPlaceId'] as String?;

      final destinationPlaceId = body['destinationPlaceId'] as String?;

      final pickupLatitude = (body['pickupLatitude'] as num?)?.toDouble();

      final pickupLongitude = (body['pickupLongitude'] as num?)?.toDouble();

      if (pickup == null ||
          pickup.trim().isEmpty ||
          destination == null ||
          destination.trim().isEmpty) {
        return Response(
          400,

          body: jsonEncode({'error': 'Pickup and destination are required.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final result = await calculateRoute(
        pickup,

        destination,

        apiKey,

        pickupPlaceId: pickupPlaceId,

        destinationPlaceId: destinationPlaceId,

        pickupLatitude: pickupLatitude,

        pickupLongitude: pickupLongitude,
      );

      return Response.ok(
        jsonEncode(result),

        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Route error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Route calculation failed.'}),

        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  router.post('/places/autocomplete', (Request request) async {
    try {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;

      final input = body['input'] as String?;

      final sessionToken = body['sessionToken'] as String?;

      if (input == null || input.trim().isEmpty) {
        return Response(
          400,

          body: jsonEncode({'error': 'Input is required.'}),

          headers: {'Content-Type': 'application/json'},
        );
      }

      final suggestions = await autocompletePlaces(
        input.trim(),

        apiKey,

        sessionToken: sessionToken,
      );

      return Response.ok(
        jsonEncode({'suggestions': suggestions}),

        headers: {'Content-Type': 'application/json'},
      );
    } catch (error) {
      print('Places autocomplete error: $error');

      return Response.internalServerError(
        body: jsonEncode({'error': 'Places autocomplete failed.'}),

        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware())
      .addHandler(router.call);

  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);

  print('Server listening on port ${server.port}');
}
