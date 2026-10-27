import 'dart:convert';

import 'package:gocity6_backend/geography/district_matcher.dart';
import 'package:test/test.dart';

void main() {
  test('matches Polygon interiors and excludes interior holes', () {
    final matcher = DistrictMatcher.fromGeoJsonString(
      jsonEncode(
        _collection([
          _feature(
            objectId: 12,
            name: 'AREA WITH HOLE',
            geometry: {
              'type': 'Polygon',
              'coordinates': [_ring(0, 0, 4, 4), _ring(1, 1, 3, 3)],
            },
          ),
        ]),
      ),
    );

    expect(matcher.match(latitude: 0.5, longitude: 0.5)?.district.objectId, 12);
    expect(matcher.match(latitude: 2, longitude: 2), isNull);
  });

  test('matches any component of a MultiPolygon', () {
    final matcher = DistrictMatcher.fromGeoJsonString(
      jsonEncode(
        _collection([
          _feature(
            objectId: 31,
            name: 'MULTI',
            geometry: {
              'type': 'MultiPolygon',
              'coordinates': [
                [_ring(0, 0, 1, 1)],
                [_ring(5, 5, 6, 6)],
              ],
            },
          ),
        ]),
      ),
    );

    expect(matcher.match(latitude: 5.5, longitude: 5.5)?.district.objectId, 31);
  });

  test('uses the lowest object_id for a shared boundary', () {
    final matcher = DistrictMatcher.fromGeoJsonString(
      jsonEncode(
        _collection([
          _feature(
            objectId: 20,
            name: 'RIGHT',
            geometry: {
              'type': 'Polygon',
              'coordinates': [_ring(1, 0, 2, 1)],
            },
          ),
          _feature(
            objectId: 10,
            name: 'LEFT',
            geometry: {
              'type': 'Polygon',
              'coordinates': [_ring(0, 0, 1, 1)],
            },
          ),
        ]),
      ),
    );

    final match = matcher.match(latitude: 0.5, longitude: 1)!;
    expect(match.district.objectId, 10);
    expect(match.resolution, DistrictMatchResolution.overlapTieBreak);
    expect(match.candidateObjectIds, [10, 20]);
  });

  test(
    'returns no district outside all polygons and rejects invalid WGS84',
    () {
      final matcher = DistrictMatcher.fromGeoJsonString(
        jsonEncode(
          _collection([
            _feature(
              objectId: 1,
              name: 'ONE',
              geometry: {
                'type': 'Polygon',
                'coordinates': [_ring(0, 0, 1, 1)],
              },
            ),
          ]),
        ),
      );

      expect(matcher.match(latitude: 2, longitude: 2), isNull);
      expect(
        () => matcher.match(latitude: 91, longitude: 2),
        throwsArgumentError,
      );
    },
  );
}

Map<String, Object?> _collection(List<Map<String, Object?>> features) => {
  'type': 'FeatureCollection',
  'features': features,
};

Map<String, Object?> _feature({
  required int objectId,
  required String name,
  required Map<String, Object?> geometry,
}) => {
  'type': 'Feature',
  'properties': {'object_id': objectId, 'id': 'uuid-$objectId', 'kvname': name},
  'geometry': geometry,
};

List<List<double>> _ring(
  double minLongitude,
  double minLatitude,
  double maxLongitude,
  double maxLatitude,
) => [
  [minLongitude, minLatitude],
  [maxLongitude, minLatitude],
  [maxLongitude, maxLatitude],
  [minLongitude, maxLatitude],
  [minLongitude, minLatitude],
];
