import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/models.dart';

/// Integra APIs abertas de mapeamento e navegação (sem necessidade de chave paga):
/// - OpenStreetMap Nominatim: busca de endereços e comércios por texto.
/// - Overpass API: radares fixos (`highway=speed_camera`) e categorias próximas.
/// - OSRM: cálculo de rotas rua a rua + instruções de manobra.
class MapApiService {
  static const _userAgent =
      'KnownRoads/1.0 (https://github.com/hipolitopeedro/known-roads)';

  /// Busca endereços, bairros, cidades ou comércios via Nominatim (OSM).
  static Future<List<PlaceResult>> searchPlaces(
    String query, {
    LatLng? near,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final params = <String, String>{
      'q': trimmed,
      'format': 'jsonv2',
      'limit': '10',
      'addressdetails': '1',
      'accept-language': 'pt-BR',
    };

    // Prioriza resultados perto da localização atual do motociclista.
    if (near != null) {
      final deltaLon = 0.45;
      final deltaLat = 0.45;
      params['viewbox'] =
          '${near.longitude - deltaLon},${near.latitude + deltaLat},'
          '${near.longitude + deltaLon},${near.latitude - deltaLat}';
    }

    final uri = Uri.https('nominatim.openstreetmap.org', '/search', params);
    final res = await http
        .get(uri, headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 12));

    if (res.statusCode != 200) {
      throw Exception('Falha na busca de locais (${res.statusCode}).');
    }

    final list = jsonDecode(res.body) as List<dynamic>;
    return list.map((item) {
      final map = item as Map<String, dynamic>;
      final display = (map['display_name'] as String?) ?? '';
      final name = (map['name'] as String?)?.isNotEmpty == true
          ? map['name'] as String
          : display.split(',').first.trim();
      final cat = (map['type'] as String?) ?? 'local';
      return PlaceResult(
        name: name,
        subtitle: display,
        lat: double.parse(map['lat'].toString()),
        lng: double.parse(map['lon'].toString()),
        category: cat,
      );
    }).toList();
  }

  /// Busca comércios próximos por categoria via Overpass API em um raio de 4 km:
  /// `fuel` (postos), `workshop` (oficinas), `food` (lanches/cafés), `viewpoint` (mirantes).
  static Future<List<PlaceResult>> searchCategoryNearby(
    String categoryKey,
    LatLng center,
  ) async {
    final String filter;
    final String labelFallback;
    switch (categoryKey) {
      case 'fuel':
        filter = '["amenity"="fuel"]';
        labelFallback = 'Posto de Combustível';
        break;
      case 'workshop':
        filter = '["shop"~"motorcycle|motorcycle_repair|car_repair"]';
        labelFallback = 'Oficina / Moto Peças';
        break;
      case 'food':
        filter = '["amenity"~"cafe|fast_food|restaurant"]';
        labelFallback = 'Café / Lanchonete';
        break;
      case 'viewpoint':
      default:
        filter = '["tourism"~"viewpoint|attraction"]';
        labelFallback = 'Mirante / Ponto Turístico';
        break;
    }

    final overpassQl = '''
[out:json][timeout:12];
(
  node$filter(around:4500,${center.latitude},${center.longitude});
  way$filter(around:4500,${center.latitude},${center.longitude});
);
out center 18;
''';

    final uri = Uri.https('lz4.overpass-api.de', '/api/interpreter');
    final res = await http
        .post(
          uri,
          headers: {
            'User-Agent': _userAgent,
            'Accept': 'application/json',
          },
          body: {'data': overpassQl},
        )
        .timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) {
      throw Exception('Overpass indisponível no momento (${res.statusCode}).');
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final elements = (json['elements'] as List<dynamic>? ?? []);
    final results = <PlaceResult>[];

    for (final raw in elements) {
      final el = raw as Map<String, dynamic>;
      final tags = (el['tags'] as Map<String, dynamic>?) ?? {};
      final double? lat = (el['lat'] as num?)?.toDouble() ??
          ((el['center'] as Map<String, dynamic>?)?['lat'] as num?)?.toDouble();
      final double? lon = (el['lon'] as num?)?.toDouble() ??
          ((el['center'] as Map<String, dynamic>?)?['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;

      final name = (tags['name'] as String?) ??
          (tags['brand'] as String?) ??
          labelFallback;
      final street = tags['addr:street'] as String?;
      final distM = GridCellHelper.haversineMeters(center, LatLng(lat, lon));
      final subtitle = [
        if (street != null && street.isNotEmpty) street,
        '${(distM / 1000).toStringAsFixed(2)} km de distância',
      ].join(' • ');

      results.add(PlaceResult(
        name: name,
        subtitle: subtitle,
        lat: lat,
        lng: lon,
        category: categoryKey,
      ));
    }

    results.sort((a, b) {
      final da = GridCellHelper.haversineMeters(center, a.latLng);
      final db = GridCellHelper.haversineMeters(center, b.latLng);
      return da.compareTo(db);
    });
    return results;
  }

  /// Envia consulta Overpass tentando primeiro o mirror rápido `lz4` e, em caso
  /// de falha, usando o endpoint principal como fallback.
  static Future<Map<String, dynamic>> _postOverpass(String overpassQl) async {
    const hosts = ['lz4.overpass-api.de', 'overpass-api.de'];
    Exception? lastError;

    for (final host in hosts) {
      try {
        final uri = Uri.https(host, '/api/interpreter');
        final res = await http
            .post(
              uri,
              headers: {
                'User-Agent': _userAgent,
                'Accept': 'application/json',
              },
              body: {'data': overpassQl},
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          return jsonDecode(res.body) as Map<String, dynamic>;
        }
        lastError = Exception('Overpass $host retornou ${res.statusCode}');
      } catch (e) {
        lastError = Exception(e.toString());
      }
    }
    throw lastError ?? Exception('Servidores Overpass indisponíveis.');
  }

  /// Busca radares de velocidade (`highway=speed_camera` e `enforcement=maxspeed`)
  /// no OpenStreetMap em um raio de 12 km ao redor da posição informada.
  static Future<List<RadarPoint>> fetchRadarsNearby(LatLng center) async {
    final overpassQl = '''
[out:json][timeout:15];
(
  node["highway"="speed_camera"](around:12000,${center.latitude},${center.longitude});
  relation["enforcement"="maxspeed"](around:12000,${center.latitude},${center.longitude});
);
out center 120;
''';
    final json = await _postOverpass(overpassQl);
    final elements = (json['elements'] as List<dynamic>? ?? []);
    final radars = <RadarPoint>[];

    for (final raw in elements) {
      final el = raw as Map<String, dynamic>;
      final double? lat = (el['lat'] as num?)?.toDouble() ??
          ((el['center'] as Map<String, dynamic>?)?['lat'] as num?)?.toDouble();
      final double? lon = (el['lon'] as num?)?.toDouble() ??
          ((el['center'] as Map<String, dynamic>?)?['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;

      final tags = (el['tags'] as Map<String, dynamic>?) ?? {};
      final rawSpeed = (tags['maxspeed'] as String?) ?? '';
      final speed = int.tryParse(rawSpeed.replaceAll(RegExp(r'[^0-9]'), '')) ?? 60;
      radars.add(RadarPoint(
        lat: lat,
        lng: lon,
        speedLimit: speed,
        label: (tags['name'] as String?) ?? 'Radar Fixo OSM ($speed km/h)',
        isCustom: false,
      ));
    }
    return radars;
  }

  /// Calcula rota rua-a-rua via OSRM e avalia % de estradas ainda inéditas.
  static Future<RouteResult> calculateRoute(
    LatLng from,
    PlaceResult destination,
    Set<String> exploredCells,
  ) async {
    final path =
        '/route/v1/driving/${from.longitude},${from.latitude};${destination.lng},${destination.lat}';
    final uri = Uri.https('router.project-osrm.org', path, {
      'overview': 'full',
      'geometries': 'geojson',
      'steps': 'true',
    });

    final res = await http
        .get(uri, headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) {
      throw Exception('Falha ao traçar rota (${res.statusCode}).');
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final routes = json['routes'] as List<dynamic>? ?? [];
    if (routes.isEmpty) {
      throw Exception('Nenhuma rota rodoviária encontrada até este ponto.');
    }

    final first = routes.first as Map<String, dynamic>;
    final distKm = ((first['distance'] as num).toDouble()) / 1000.0;
    final durMin = ((first['duration'] as num).toDouble()) / 60.0;

    final geom = first['geometry'] as Map<String, dynamic>;
    final coords = geom['coordinates'] as List<dynamic>;
    final routePoints = coords.map((c) {
      final pair = c as List<dynamic>;
      return LatLng((pair[1] as num).toDouble(), (pair[0] as num).toDouble());
    }).toList();

    // Extrai a primeira instrução de manobra legível em português.
    String nextStep = 'Siga pela via indicada';
    final legs = first['legs'] as List<dynamic>? ?? [];
    if (legs.isNotEmpty) {
      final steps =
          (legs.first as Map<String, dynamic>)['steps'] as List<dynamic>? ?? [];
      final targetStep = steps.length > 1 ? steps[1] : (steps.isNotEmpty ? steps[0] : null);
      if (targetStep != null) {
        final stepMap = targetStep as Map<String, dynamic>;
        final maneuver = stepMap['maneuver'] as Map<String, dynamic>? ?? {};
        final type = (maneuver['type'] as String?) ?? '';
        final mod = (maneuver['modifier'] as String?) ?? '';
        final street = (stepMap['name'] as String?) ?? '';
        final stepDistM = ((stepMap['distance'] as num?)?.toDouble() ?? 0).round();
        nextStep = _formatManeuverPt(type, mod, street, stepDistM);
      }
    }

    final unexploredPct = GridCellHelper.computeUnexploredPercent(
      routePoints,
      exploredCells,
    );

    return RouteResult(
      points: routePoints,
      distanceKm: distKm,
      durationMinutes: durMin,
      nextInstruction: nextStep,
      unexploredPercent: unexploredPct,
      destination: destination,
    );
  }

  static String _formatManeuverPt(
    String type,
    String modifier,
    String street,
    int distM,
  ) {
    final turn = switch (modifier) {
      'left' => 'Vire à esquerda',
      'sharp left' => 'Vire fechado à esquerda',
      'slight left' => 'Mantenha-se à esquerda',
      'right' => 'Vire à direita',
      'sharp right' => 'Vire fechado à direita',
      'slight right' => 'Mantenha-se à direita',
      'uturn' => 'Faça o retorno',
      _ => type == 'arrive' ? 'Você chegou ao destino' : 'Siga em frente',
    };
    final via = street.isNotEmpty ? ' em $street' : '';
    final d = distM > 0 ? ' (em ${distM}m)' : '';
    return '$turn$via$d';
  }
}
