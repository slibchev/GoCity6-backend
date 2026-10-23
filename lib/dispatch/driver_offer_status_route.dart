import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/driver_token_service.dart';
import 'driver_offer_status_service.dart';

void registerDriverOfferStatusRoute(
  Router router, {
  required DriverTokenService? tokenService,
  required DriverOfferStatusService? statusService,
}) {
  router.get('/driver/offers/<offerId>', (
    Request request,
    String offerId,
  ) async {
    const headers = {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
    };

    if (tokenService == null || statusService == null) {
      return Response(
        503,
        body: jsonEncode({'error': 'Driver offer status is unavailable.'}),
        headers: headers,
      );
    }

    final authorization = request.headers['authorization'];
    if (authorization == null || !authorization.startsWith('Bearer ')) {
      return Response(
        401,
        body: jsonEncode({'error': 'Authentication required.'}),
        headers: headers,
      );
    }

    final tokenPayload = tokenService.verifyToken(
      authorization.substring(7).trim(),
    );
    if (tokenPayload == null) {
      return Response(
        401,
        body: jsonEncode({'error': 'Invalid or expired token.'}),
        headers: headers,
      );
    }

    try {
      final status = await statusService.findForDriver(
        offerId: offerId,
        driverId: tokenPayload.driverId,
      );

      return Response.ok(
        jsonEncode({
          'offerId': status.offerId,
          'rideId': status.rideId,
          'status': status.status.name,
          'offeredAt': status.offeredAt.toIso8601String(),
          'expiresAt': status.expiresAt.toIso8601String(),
          'resolvedAt': status.resolvedAt?.toIso8601String(),
          'displayedAt': status.displayedAt?.toIso8601String(),
        }),
        headers: headers,
      );
    } on DriverOfferStatusNotFoundException {
      return Response(
        404,
        body: jsonEncode({'error': 'Offer not found.'}),
        headers: headers,
      );
    } catch (_) {
      return Response(
        500,
        body: jsonEncode({'error': 'Offer status lookup failed.'}),
        headers: headers,
      );
    }
  });
}
