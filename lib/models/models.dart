import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Utilitários espaciais para cálculo de distância e desbloqueio de estradas
/// no estilo Forza Horizon (grade de ~25 metros por célula).
class GridCellHelper {
  /// Passo de quantização em graus (~0.00025° ≈ 25m a 27m no Brasil).
  static const double step = 0.00025;

  /// Comprimento aproximado de uma célula única descoberta em km.
  static const double kmPerCell = 0.025;

  /// Converte coordenadas em chave única de setor explorado.
  static String cellKey(double lat, double lng) {
    final latIdx = (lat / step).floor();
    final lngIdx = (lng / step).floor();
    return '$latIdx:$lngIdx';
  }

  /// Gera todas as chaves de célula ao longo de um segmento (para evitar falhas
  /// em velocidades mais altas de moto onde dois pontos do GPS ficam distantes).
  static List<String> interpolateSegmentCells(LatLng a, LatLng b) {
    final distM = haversineMeters(a, b);
    final steps = math.max(1, (distM / 18.0).ceil());
    final keys = <String>{};
    for (int i = 0; i <= steps; i++) {
      final t = i / steps;
      final lat = a.latitude + (b.latitude - a.latitude) * t;
      final lng = a.longitude + (b.longitude - a.longitude) * t;
      keys.add(cellKey(lat, lng));
    }
    return keys.toList();
  }

  /// Calcula distância geodésica entre dois pontos em metros (fórmula de Haversine).
  static double haversineMeters(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = _degToRad(b.latitude - a.latitude);
    final dLon = _degToRad(b.longitude - a.longitude);
    final lat1 = _degToRad(a.latitude);
    final lat2 = _degToRad(b.latitude);

    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
    return r * c;
  }

  /// Calcula qual porcentagem dos pontos de uma rota passa por áreas ainda
  /// não exploradas pelo motociclista.
  static double computeUnexploredPercent(
    List<LatLng> routePoints,
    Set<String> exploredCells,
  ) {
    if (routePoints.isEmpty) return 0;
    int unexploredCount = 0;
    for (final pt in routePoints) {
      final key = cellKey(pt.latitude, pt.longitude);
      if (!exploredCells.contains(key)) {
        unexploredCount++;
      }
    }
    return (unexploredCount / routePoints.length) * 100.0;
  }

  static double _degToRad(double deg) => deg * (math.pi / 180.0);
}

/// Representa um rolê gravado via GPS.
class RideRecord {
  final int? id;
  final String title;
  final DateTime startTime;
  final int durationSeconds;
  final double distanceKm;
  final double newDiscoveryKm;
  final double maxSpeedKmh;
  final List<LatLng> points;

  const RideRecord({
    this.id,
    required this.title,
    required this.startTime,
    required this.durationSeconds,
    required this.distanceKm,
    required this.newDiscoveryKm,
    required this.maxSpeedKmh,
    this.points = const [],
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'start_time': startTime.toIso8601String(),
      'duration_sec': durationSeconds,
      'distance_km': distanceKm,
      'new_discovery_km': newDiscoveryKm,
      'max_speed_kmh': maxSpeedKmh,
    };
  }

  factory RideRecord.fromMap(Map<String, dynamic> map, {List<LatLng>? pts}) {
    return RideRecord(
      id: map['id'] as int?,
      title: map['title'] as String,
      startTime: DateTime.parse(map['start_time'] as String),
      durationSeconds: (map['duration_sec'] as num).toInt(),
      distanceKm: (map['distance_km'] as num).toDouble(),
      newDiscoveryKm: (map['new_discovery_km'] as num).toDouble(),
      maxSpeedKmh: (map['max_speed_kmh'] as num).toDouble(),
      points: pts ?? const [],
    );
  }
}

/// Representa um radar ou ponto de alerta no mapa.
class RadarPoint {
  final int? id;
  final double lat;
  final double lng;
  final int speedLimit;
  final String label;
  final bool isCustom;

  const RadarPoint({
    this.id,
    required this.lat,
    required this.lng,
    required this.speedLimit,
    required this.label,
    required this.isCustom,
  });

  LatLng get latLng => LatLng(lat, lng);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'lat': lat,
      'lng': lng,
      'speed_limit': speedLimit,
      'label': label,
    };
  }

  factory RadarPoint.fromMap(Map<String, dynamic> map) {
    return RadarPoint(
      id: map['id'] as int?,
      lat: (map['lat'] as num).toDouble(),
      lng: (map['lng'] as num).toDouble(),
      speedLimit: (map['speed_limit'] as num).toInt(),
      label: (map['label'] as String?) ?? 'Radar',
      isCustom: true,
    );
  }
}

/// Representa um local, comércio ou ponto de interesse retornado pela busca.
class PlaceResult {
  final String name;
  final String subtitle;
  final double lat;
  final double lng;
  final String category;

  const PlaceResult({
    required this.name,
    required this.subtitle,
    required this.lat,
    required this.lng,
    required this.category,
  });

  LatLng get latLng => LatLng(lat, lng);
}

/// Resultado de roteamento obtido via OSRM + métrica de estradas inéditas.
class RouteResult {
  final List<LatLng> points;
  final double distanceKm;
  final double durationMinutes;
  final String nextInstruction;
  final double unexploredPercent;
  final PlaceResult destination;

  const RouteResult({
    required this.points,
    required this.distanceKm,
    required this.durationMinutes,
    required this.nextInstruction,
    required this.unexploredPercent,
    required this.destination,
  });
}

/// Checkpoint fotográfico salvo durante um rolê.
class PhotoCheckpoint {
  final int? id;
  final int? rideId;
  final String title;
  final String photoPath;
  final double lat;
  final double lng;
  final DateTime timestamp;

  const PhotoCheckpoint({
    this.id,
    this.rideId,
    required this.title,
    required this.photoPath,
    required this.lat,
    required this.lng,
    required this.timestamp,
  });

  LatLng get latLng => LatLng(lat, lng);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'ride_id': rideId,
      'title': title,
      'photo_path': photoPath,
      'lat': lat,
      'lng': lng,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory PhotoCheckpoint.fromMap(Map<String, dynamic> map) {
    return PhotoCheckpoint(
      id: map['id'] as int?,
      rideId: map['ride_id'] as int?,
      title: map['title'] as String,
      photoPath: map['photo_path'] as String,
      lat: (map['lat'] as num).toDouble(),
      lng: (map['lng'] as num).toDouble(),
      timestamp: DateTime.parse(map['timestamp'] as String),
    );
  }
}
