import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const String acceptedCity6DistrictsSha256 =
    '46F4AF917A2657B5070E9A6BE6B69FCCEC6FA205FC2BBD7294A821E81BBD1A2D';
const int acceptedCity6DistrictCount = 328;

enum DistrictMatchResolution { interior, boundary, overlapTieBreak }

final class CityDistrict {
  const CityDistrict({required this.objectId, required this.name});

  final int objectId;
  final String name;
}

final class DistrictMatch {
  const DistrictMatch({
    required this.district,
    required this.resolution,
    required this.candidateObjectIds,
  });

  final CityDistrict district;
  final DistrictMatchResolution resolution;

  /// Sorted object IDs for every polygon covering this point. Multiple
  /// matches are resolved deterministically to the smallest object ID.
  final List<int> candidateObjectIds;
}

/// In-memory point lookup over the accepted City6 GeoJSON boundaries.
///
/// Coordinates are WGS84 (latitude/longitude); GeoJSON positions are read in
/// longitude/latitude order. Polygon boundaries are inclusive. If a point is
/// on a shared boundary or in a tiny overlap, the lowest object_id wins.
final class DistrictMatcher {
  DistrictMatcher._(this._districts)
    : _objectIds = Set.unmodifiable(
        _districts.map((geometry) => geometry.district.objectId),
      );

  static const String defaultGeoJsonPath =
      'data/geography/sofiaplan/districts_working.geojson';

  static const double _coordinateEpsilon = 1e-12;

  final List<_DistrictGeometry> _districts;
  final Set<int> _objectIds;

  int get districtCount => _districts.length;

  /// Whether [objectId] belongs to the currently loaded, validated map.
  bool containsObjectId(int objectId) => _objectIds.contains(objectId);

  /// Loads the approved source once. The hash guard prevents a stale or
  /// unreviewed map from silently becoming the runtime boundary source.
  static Future<DistrictMatcher> loadApproved({String? path}) async {
    final configuredPath =
        path ?? Platform.environment['CITY6_DISTRICTS_GEOJSON'];
    final filePath = configuredPath == null || configuredPath.trim().isEmpty
        ? defaultGeoJsonPath
        : configuredPath;
    final bytes = await File(filePath).readAsBytes();
    final actualHash = sha256.convert(bytes).toString().toUpperCase();
    if (actualHash != acceptedCity6DistrictsSha256) {
      throw StateError(
        'City6 district GeoJSON hash does not match the approved V2 source.',
      );
    }

    final matcher = DistrictMatcher.fromGeoJsonString(utf8.decode(bytes));
    if (matcher.districtCount != acceptedCity6DistrictCount) {
      throw StateError('Approved City6 district count is unexpected.');
    }
    return matcher;
  }

  /// Parses a GeoJSON string. This constructor is also useful for isolated
  /// geometry tests; production startup must use [loadApproved].
  factory DistrictMatcher.fromGeoJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded['type'] != 'FeatureCollection' ||
        decoded['features'] is! List<dynamic>) {
      throw const FormatException('Expected a GeoJSON FeatureCollection.');
    }

    final seenObjectIds = <int>{};
    final seenUuids = <String>{};
    final districts = <_DistrictGeometry>[];

    for (final featureValue in decoded['features'] as List<dynamic>) {
      if (featureValue is! Map<String, dynamic> ||
          featureValue['type'] != 'Feature' ||
          featureValue['properties'] is! Map<String, dynamic> ||
          featureValue['geometry'] is! Map<String, dynamic>) {
        throw const FormatException('Invalid City6 district feature.');
      }

      final properties = featureValue['properties'] as Map<String, dynamic>;
      final objectIdValue = properties['object_id'];
      final uuidValue = properties['id'];
      final nameValue = properties['kvname'];
      if (objectIdValue is! num ||
          !objectIdValue.isFinite ||
          objectIdValue.toInt() != objectIdValue ||
          uuidValue is! String ||
          uuidValue.trim().isEmpty ||
          nameValue is! String ||
          nameValue.trim().isEmpty) {
        throw const FormatException(
          'City6 district is missing a valid object_id, id, or kvname.',
        );
      }

      final objectId = objectIdValue.toInt();
      if (!seenObjectIds.add(objectId) || !seenUuids.add(uuidValue)) {
        throw const FormatException(
          'City6 district object IDs and UUIDs must be unique.',
        );
      }

      final geometry = featureValue['geometry'] as Map<String, dynamic>;
      final components = _parseGeometry(geometry);
      districts.add(
        _DistrictGeometry(
          district: CityDistrict(objectId: objectId, name: nameValue),
          components: components,
        ),
      );
    }

    if (districts.isEmpty) {
      throw const FormatException('City6 district GeoJSON is empty.');
    }
    districts.sort(
      (a, b) => a.district.objectId.compareTo(b.district.objectId),
    );
    return DistrictMatcher._(List.unmodifiable(districts));
  }

  DistrictMatch? match({required double latitude, required double longitude}) {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw ArgumentError('Coordinates must be a valid WGS84 pair.');
    }

    final matches = <({CityDistrict district, bool boundary})>[];
    for (final geometry in _districts) {
      var isInterior = false;
      var isBoundary = false;
      for (final component in geometry.components) {
        if (!component.bounds.contains(longitude, latitude)) {
          continue;
        }
        final relation = _classifyPolygon(longitude, latitude, component);
        if (relation == _PointRelation.inside) {
          isInterior = true;
          break;
        }
        if (relation == _PointRelation.boundary) {
          isBoundary = true;
        }
      }
      if (isInterior || isBoundary) {
        matches.add((district: geometry.district, boundary: !isInterior));
      }
    }

    if (matches.isEmpty) {
      return null;
    }

    matches.sort((a, b) => a.district.objectId.compareTo(b.district.objectId));
    final candidateObjectIds = List<int>.unmodifiable(
      matches.map((match) => match.district.objectId),
    );
    final resolution = matches.length > 1
        ? DistrictMatchResolution.overlapTieBreak
        : matches.single.boundary
        ? DistrictMatchResolution.boundary
        : DistrictMatchResolution.interior;

    return DistrictMatch(
      district: matches.first.district,
      resolution: resolution,
      candidateObjectIds: candidateObjectIds,
    );
  }

  static List<_PolygonComponent> _parseGeometry(Map<String, dynamic> geometry) {
    final type = geometry['type'];
    final coordinates = geometry['coordinates'];
    if (type == 'Polygon' && coordinates is List<dynamic>) {
      return [_parsePolygon(coordinates)];
    }
    if (type == 'MultiPolygon' && coordinates is List<dynamic>) {
      return coordinates
          .map((polygon) {
            if (polygon is! List<dynamic>) {
              throw const FormatException('Invalid MultiPolygon coordinates.');
            }
            return _parsePolygon(polygon);
          })
          .toList(growable: false);
    }
    throw const FormatException('Only Polygon and MultiPolygon are supported.');
  }

  static _PolygonComponent _parsePolygon(List<dynamic> ringsValue) {
    if (ringsValue.isEmpty ||
        ringsValue.any((ring) => ring is! List<dynamic>)) {
      throw const FormatException('Polygon must contain coordinate rings.');
    }
    final rings = ringsValue
        .map((ring) => _parseRing(ring as List<dynamic>))
        .toList(growable: false);
    return _PolygonComponent(outer: rings.first, holes: rings.skip(1).toList());
  }

  static _Ring _parseRing(List<dynamic> positions) {
    if (positions.length < 4) {
      throw const FormatException('A linear ring needs at least four points.');
    }
    final points = positions
        .map((position) {
          if (position is! List<dynamic> || position.length < 2) {
            throw const FormatException('Invalid GeoJSON coordinate position.');
          }
          final longitudeValue = position[0];
          final latitudeValue = position[1];
          if (longitudeValue is! num || latitudeValue is! num) {
            throw const FormatException('GeoJSON coordinates must be numeric.');
          }
          final longitude = longitudeValue.toDouble();
          final latitude = latitudeValue.toDouble();
          if (!longitude.isFinite ||
              !latitude.isFinite ||
              longitude < -180 ||
              longitude > 180 ||
              latitude < -90 ||
              latitude > 90) {
            throw const FormatException('GeoJSON coordinate is outside WGS84.');
          }
          return _GeoPoint(longitude, latitude);
        })
        .toList(growable: false);

    if (points.first.longitude != points.last.longitude ||
        points.first.latitude != points.last.latitude) {
      throw const FormatException('GeoJSON linear ring is not closed.');
    }
    return _Ring(points);
  }

  static _PointRelation _classifyPolygon(
    double longitude,
    double latitude,
    _PolygonComponent polygon,
  ) {
    final outerRelation = _classifyRing(longitude, latitude, polygon.outer);
    if (outerRelation == _PointRelation.outside) {
      return _PointRelation.outside;
    }

    var isBoundary = outerRelation == _PointRelation.boundary;
    for (final hole in polygon.holes) {
      final holeRelation = _classifyRing(longitude, latitude, hole);
      if (holeRelation == _PointRelation.inside) {
        return _PointRelation.outside;
      }
      if (holeRelation == _PointRelation.boundary) {
        isBoundary = true;
      }
    }
    return isBoundary ? _PointRelation.boundary : _PointRelation.inside;
  }

  static _PointRelation _classifyRing(
    double longitude,
    double latitude,
    _Ring ring,
  ) {
    var inside = false;
    final points = ring.points;
    for (
      var i = 0, previous = points.length - 1;
      i < points.length;
      previous = i++
    ) {
      final currentPoint = points[i];
      final previousPoint = points[previous];
      if (_isOnSegment(longitude, latitude, currentPoint, previousPoint)) {
        return _PointRelation.boundary;
      }

      final crossesLatitude =
          (currentPoint.latitude > latitude) !=
          (previousPoint.latitude > latitude);
      if (crossesLatitude) {
        final crossingLongitude =
            (previousPoint.longitude - currentPoint.longitude) *
                (latitude - currentPoint.latitude) /
                (previousPoint.latitude - currentPoint.latitude) +
            currentPoint.longitude;
        if (longitude < crossingLongitude) {
          inside = !inside;
        }
      }
    }
    return inside ? _PointRelation.inside : _PointRelation.outside;
  }

  static bool _isOnSegment(
    double longitude,
    double latitude,
    _GeoPoint first,
    _GeoPoint second,
  ) {
    final deltaLongitude = second.longitude - first.longitude;
    final deltaLatitude = second.latitude - first.latitude;
    final cross =
        (longitude - first.longitude) * deltaLatitude -
        (latitude - first.latitude) * deltaLongitude;
    final crossTolerance =
        _coordinateEpsilon *
        (deltaLongitude.abs() + deltaLatitude.abs()).clamp(1e-15, 360);
    if (cross.abs() > crossTolerance) {
      return false;
    }
    return longitude >=
            (first.longitude < second.longitude
                    ? first.longitude
                    : second.longitude) -
                _coordinateEpsilon &&
        longitude <=
            (first.longitude > second.longitude
                    ? first.longitude
                    : second.longitude) +
                _coordinateEpsilon &&
        latitude >=
            (first.latitude < second.latitude
                    ? first.latitude
                    : second.latitude) -
                _coordinateEpsilon &&
        latitude <=
            (first.latitude > second.latitude
                    ? first.latitude
                    : second.latitude) +
                _coordinateEpsilon;
  }
}

enum _PointRelation { outside, inside, boundary }

final class _GeoPoint {
  const _GeoPoint(this.longitude, this.latitude);

  final double longitude;
  final double latitude;
}

final class _Ring {
  _Ring(List<_GeoPoint> points) : points = List.unmodifiable(points) {
    var minLongitude = double.infinity;
    var minLatitude = double.infinity;
    var maxLongitude = double.negativeInfinity;
    var maxLatitude = double.negativeInfinity;
    for (final point in points) {
      if (point.longitude < minLongitude) minLongitude = point.longitude;
      if (point.longitude > maxLongitude) maxLongitude = point.longitude;
      if (point.latitude < minLatitude) minLatitude = point.latitude;
      if (point.latitude > maxLatitude) maxLatitude = point.latitude;
    }
    bounds = _GeoBounds(minLongitude, minLatitude, maxLongitude, maxLatitude);
  }

  final List<_GeoPoint> points;
  late final _GeoBounds bounds;
}

final class _PolygonComponent {
  _PolygonComponent({required this.outer, required List<_Ring> holes})
    : holes = List.unmodifiable(holes),
      bounds = outer.bounds;

  final _Ring outer;
  final List<_Ring> holes;
  final _GeoBounds bounds;
}

final class _GeoBounds {
  const _GeoBounds(
    this.minLongitude,
    this.minLatitude,
    this.maxLongitude,
    this.maxLatitude,
  );

  final double minLongitude;
  final double minLatitude;
  final double maxLongitude;
  final double maxLatitude;

  bool contains(double longitude, double latitude) =>
      longitude >= minLongitude - DistrictMatcher._coordinateEpsilon &&
      longitude <= maxLongitude + DistrictMatcher._coordinateEpsilon &&
      latitude >= minLatitude - DistrictMatcher._coordinateEpsilon &&
      latitude <= maxLatitude + DistrictMatcher._coordinateEpsilon;
}

final class _DistrictGeometry {
  const _DistrictGeometry({required this.district, required this.components});

  final CityDistrict district;
  final List<_PolygonComponent> components;
}
