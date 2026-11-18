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

/// Radares pré-carregados nos principais corredores de Belo Horizonte (MG),
/// combinados em tempo real com os radares consultados via OpenStreetMap Overpass.
const List<RadarPoint> defaultBhRadars = [
  // Dados OSM verificados em BH
  RadarPoint(lat: -19.888914, lng: -43.967382, speedLimit: 60, label: 'Radar Av. Pres. Carlos Luz (60 km/h)', isCustom: false),
  RadarPoint(lat: -19.888753, lng: -43.929168, speedLimit: 60, label: 'Radar Av. Cristiano Machado (60 km/h)', isCustom: false),
  RadarPoint(lat: -19.863041, lng: -43.957837, speedLimit: 60, label: 'Radar Av. Antônio Carlos (60 km/h)', isCustom: false),
  RadarPoint(lat: -19.876079, lng: -44.033968, speedLimit: 60, label: 'Radar Via Expressa / Contagem (60 km/h)', isCustom: false),
  RadarPoint(lat: -19.840236, lng: -43.935917, speedLimit: 70, label: 'Radar Av. Cristiano Machado (70 km/h)', isCustom: false),
  RadarPoint(lat: -19.903546, lng: -43.899843, speedLimit: 60, label: 'Radar Leste / José Cândido (60 km/h)', isCustom: false),
  RadarPoint(lat: -19.892921, lng: -43.964620, speedLimit: 60, label: 'Radar Região Pampulha/Caiçara (60 km/h)', isCustom: false),
  RadarPoint(lat: -19.879272, lng: -43.976062, speedLimit: 60, label: 'Radar Av. Tancredo Neves (60 km/h)', isCustom: false),
  // Principais corredores Centro / Zona Sul / Oeste / Contorno
  RadarPoint(lat: -19.914800, lng: -43.943200, speedLimit: 60, label: 'Radar Av. do Contorno / Rodoviária', isCustom: false),
  RadarPoint(lat: -19.918200, lng: -43.947500, speedLimit: 60, label: 'Radar Av. Amazonas / Centro', isCustom: false),
  RadarPoint(lat: -19.922800, lng: -43.934500, speedLimit: 60, label: 'Radar Av. Afonso Pena / Parque Municipal', isCustom: false),
  RadarPoint(lat: -19.925500, lng: -43.942200, speedLimit: 60, label: 'Radar Av. Bias Fortes / Praça Raul Soares', isCustom: false),
  RadarPoint(lat: -19.932400, lng: -43.927800, speedLimit: 60, label: 'Radar Av. Afonso Pena / Savassi', isCustom: false),
  RadarPoint(lat: -19.936900, lng: -43.938400, speedLimit: 60, label: 'Radar Av. do Contorno / Lourdes', isCustom: false),
  RadarPoint(lat: -19.939500, lng: -43.952200, speedLimit: 60, label: 'Radar Av. Prudente de Morais', isCustom: false),
  RadarPoint(lat: -19.946200, lng: -43.934500, speedLimit: 60, label: 'Radar Av. N. Sra. do Carmo / São Pedro', isCustom: false),
  RadarPoint(lat: -19.956500, lng: -43.938800, speedLimit: 60, label: 'Radar Av. N. Sra. do Carmo / Sion', isCustom: false),
  RadarPoint(lat: -19.948800, lng: -43.956800, speedLimit: 60, label: 'Radar Av. Raja Gabaglia / Luxemburgo', isCustom: false),
  RadarPoint(lat: -19.961200, lng: -43.959500, speedLimit: 60, label: 'Radar Av. Raja Gabaglia / Estoril', isCustom: false),
  RadarPoint(lat: -19.969800, lng: -43.954200, speedLimit: 60, label: 'Radar Anel Rodoviário / BH Shopping', isCustom: false),
  RadarPoint(lat: -19.931800, lng: -43.963500, speedLimit: 60, label: 'Radar Av. Amazonas / Gutierrez', isCustom: false),
  RadarPoint(lat: -19.937200, lng: -43.975400, speedLimit: 60, label: 'Radar Av. Amazonas / Nova Suíça', isCustom: false),
  RadarPoint(lat: -19.921500, lng: -43.968200, speedLimit: 60, label: 'Radar Av. Tereza Cristina / Calafate', isCustom: false),
  RadarPoint(lat: -19.914500, lng: -43.961500, speedLimit: 60, label: 'Radar Av. Dom Pedro II / Carlos Prates', isCustom: false),
  RadarPoint(lat: -19.908200, lng: -43.952000, speedLimit: 60, label: 'Radar Av. Antônio Carlos / Lagoinha', isCustom: false),
  RadarPoint(lat: -19.919500, lng: -43.918500, speedLimit: 60, label: 'Radar Av. dos Andradas / Santa Efigênia', isCustom: false),
  RadarPoint(lat: -19.912500, lng: -43.924200, speedLimit: 60, label: 'Radar Av. do Contorno / Floresta', isCustom: false),
  RadarPoint(lat: -19.902200, lng: -43.938800, speedLimit: 60, label: 'Radar Av. Cristiano Machado / Silviano Brandão', isCustom: false),
  RadarPoint(lat: -19.927800, lng: -43.991200, speedLimit: 80, label: 'Radar Anel Rodoviário / Betânia (80 km/h)', isCustom: false),
  RadarPoint(lat: -19.906500, lng: -43.996800, speedLimit: 70, label: 'Radar Anel Rodoviário / Padre Eustáquio (70 km/h)', isCustom: false),
  RadarPoint(lat: -19.938800, lng: -43.998500, speedLimit: 60, label: 'Radar Via Expressa / Barreiro-Oeste', isCustom: false),
  RadarPoint(lat: -19.916200, lng: -43.936200, speedLimit: 50, label: 'Radar Av. dos Andradas / Parque', isCustom: false),
  RadarPoint(lat: -19.928900, lng: -43.949800, speedLimit: 60, label: 'Radar Av. Álvares Cabral / Santo Agostinho', isCustom: false),
  RadarPoint(lat: -19.924800, lng: -43.938500, speedLimit: 60, label: 'Radar Av. Bias Fortes / Centro', isCustom: false),
];

/// Pontos de interesse e referências conhecidas de BH/MG para pesquisa direta por nome
/// (faculdades, shoppings, praças, mirantes e serras para rolê de moto).
const List<PlaceResult> builtInBhPlaces = [
  PlaceResult(
    name: 'Faculdade Dom Helder Câmara (Escola Superior Dom Helder)',
    subtitle: 'Rua Álvares Maciel, 628 - Santa Efigênia, Belo Horizonte - MG',
    lat: -19.921650,
    lng: -43.921980,
    category: 'faculdade',
  ),
  PlaceResult(
    name: 'UFMG Campus Pampulha',
    subtitle: 'Av. Pres. Antônio Carlos, 6627 - Pampulha, Belo Horizonte - MG',
    lat: -19.869100,
    lng: -43.966400,
    category: 'faculdade',
  ),
  PlaceResult(
    name: 'PUC Minas Coração Eucarístico',
    subtitle: 'Av. Dom José Gaspar, 500 - Coração Eucarístico, Belo Horizonte - MG',
    lat: -19.922500,
    lng: -43.992600,
    category: 'faculdade',
  ),
  PlaceResult(
    name: 'CEFET-MG Campus I',
    subtitle: 'Av. Amazonas, 5253 - Nova Suíça, Belo Horizonte - MG',
    lat: -19.938600,
    lng: -43.977200,
    category: 'faculdade',
  ),
  PlaceResult(
    name: 'Praça da Liberdade',
    subtitle: 'Savassi / Funcionários, Belo Horizonte - MG',
    lat: -19.932050,
    lng: -43.937980,
    category: 'mirante',
  ),
  PlaceResult(
    name: 'Praça do Papa',
    subtitle: 'Mangabeiras, Belo Horizonte - MG (ponto clássico de rolê)',
    lat: -19.947850,
    lng: -43.914200,
    category: 'mirante',
  ),
  PlaceResult(
    name: 'Mirante do Mangabeiras',
    subtitle: 'Rua Pedro José Pardo, 1000 - Mangabeiras, Belo Horizonte - MG',
    lat: -19.954400,
    lng: -43.909200,
    category: 'mirante',
  ),
  PlaceResult(
    name: 'Topo do Mundo (Serra da Moeda)',
    subtitle: 'Estrada da Serra, Brumadinho / Nova Lima - MG (rolê serra)',
    lat: -20.119400,
    lng: -43.978100,
    category: 'mirante',
  ),
  PlaceResult(
    name: 'Macacos (São Sebastião das Águas Claras)',
    subtitle: 'Nova Lima - MG (estrada e bares para motociclistas)',
    lat: -20.044200,
    lng: -43.922800,
    category: 'mirante',
  ),
  PlaceResult(
    name: 'BH Shopping',
    subtitle: 'Rodovia BR-356, 3049 - Belvedere, Belo Horizonte - MG',
    lat: -19.974600,
    lng: -43.946100,
    category: 'shopping',
  ),
  PlaceResult(
    name: 'Pátio Savassi',
    subtitle: 'Av. do Contorno, 6061 - São Pedro / Savassi, Belo Horizonte - MG',
    lat: -19.940350,
    lng: -43.933850,
    category: 'shopping',
  ),
  PlaceResult(
    name: 'DiamondMall',
    subtitle: 'Av. Olegário Maciel, 1600 - Lourdes, Belo Horizonte - MG',
    lat: -19.927750,
    lng: -43.947250,
    category: 'shopping',
  ),
  PlaceResult(
    name: 'Shopping Del Rey',
    subtitle: 'Av. Presidente Carlos Luz, 3001 - Caiçaras, Belo Horizonte - MG',
    lat: -19.893500,
    lng: -43.968600,
    category: 'shopping',
  ),
  PlaceResult(
    name: 'Mercado Central de Belo Horizonte',
    subtitle: 'Av. Augusto de Lima, 744 - Centro, Belo Horizonte - MG',
    lat: -19.923100,
    lng: -43.943700,
    category: 'comercio',
  ),
  PlaceResult(
    name: 'Estádio Mineirão',
    subtitle: 'Av. Antônio Abrahão Caram, 1001 - Pampulha, Belo Horizonte - MG',
    lat: -19.865900,
    lng: -43.971100,
    category: 'ponto',
  ),
];
