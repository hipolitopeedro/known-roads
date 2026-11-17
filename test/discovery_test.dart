import 'package:flutter_test/flutter_test.dart';
import 'package:horizon_moto_gps/models/models.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('GridCellHelper & Discovery Engine', () {
    test('calcula porcentagem de estradas inéditas na rota', () {
      const p1 = LatLng(-19.9191, -43.9386);
      const p2 = LatLng(-19.9210, -43.9400);
      const p3 = LatLng(-19.9320, -43.9380);
      const p4 = LatLng(-19.9400, -43.9350);

      final explored = <String>{
        GridCellHelper.cellKey(p1.latitude, p1.longitude),
        GridCellHelper.cellKey(p2.latitude, p2.longitude),
      };

      final pct = GridCellHelper.computeUnexploredPercent(
        [p1, p2, p3, p4],
        explored,
      );

      expect(pct, closeTo(50.0, 0.1));
    });

    test('interpola células ao longo de segmento contínuo sem falhas', () {
      const a = LatLng(-19.9300, -43.9380);
      const b = LatLng(-19.9310, -43.9380); // ~111 metros
      final cells = GridCellHelper.interpolateSegmentCells(a, b);
      expect(cells.length, greaterThanOrEqualTo(3));
    });

    test('calcula distância geodésica Haversine aproximada em metros', () {
      const a = LatLng(-19.919125, -43.938641);
      const b = LatLng(-19.920025, -43.938641); // ~100 metros ao sul
      final dist = GridCellHelper.haversineMeters(a, b);
      expect(dist, inInclusiveRange(95.0, 105.0));
    });
  });

  group('Modelos SQLite', () {
    test('RideRecord serializa e desserializa corretamente', () {
      final original = RideRecord(
        id: 1,
        title: 'Rolê Serra do Curral',
        startTime: DateTime(2026, 11, 17, 19, 30),
        durationSeconds: 1840,
        distanceKm: 24.8,
        newDiscoveryKm: 11.4,
        maxSpeedKmh: 94.0,
      );
      final copia = RideRecord.fromMap(original.toMap());
      expect(copia.title, original.title);
      expect(copia.distanceKm, original.distanceKm);
      expect(copia.newDiscoveryKm, original.newDiscoveryKm);
      expect(copia.maxSpeedKmh, original.maxSpeedKmh);
    });
  });
}
