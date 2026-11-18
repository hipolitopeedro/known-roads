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

  static String _normalizeText(String s) {
    const withAccents = 'áàãâäéèêëíìîïóòõôöúùûüçñ';
    const cleanChars = 'aaaaaeeeeiiiiooooouuuucn';
    var res = s.toLowerCase().trim();
    for (int i = 0; i < withAccents.length; i++) {
      res = res.replaceAll(withAccents[i], cleanChars[i]);
    }
    return res;
  }

  static Future<List<PlaceResult>> _queryNominatim(
    Map<String, String> params,
  ) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', params);
    final res = await http
        .get(uri, headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/json',
        })
        .timeout(const Duration(seconds: 12));

    if (res.statusCode != 200) {
      throw Exception('Falha na busca de locais (${res.statusCode}).');
    }

    final list = jsonDecode(res.body) as List<dynamic>;
    return list.map((item) {
      final map = item as Map<String, dynamic>;
      final display = (map['display_name'] as String?) ?? '';
      final rawName = (map['name'] as String?)?.trim() ?? '';
      final name = rawName.isNotEmpty
          ? rawName
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

  /// Busca endereços, estabelecimentos, faculdades, shoppings e locais salvos
  /// pelo nome (sem exigir nome de rua).
  static Future<List<PlaceResult>> searchPlaces(
    String query, {
    LatLng? near,
    List<PlaceResult> savedPlaces = const [],
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final normQuery = _normalizeText(trimmed);
    final combined = <PlaceResult>[];

    // 1) Busca instantânea nos locais salvos (Faculdade, Trabalho, Casa...) e POIs de BH
    for (final p in [...savedPlaces, ...builtInBhPlaces]) {
      final hay = _normalizeText('${p.name} ${p.subtitle} ${p.category}');
      if (hay.contains(normQuery)) {
        combined.add(p);
      }
    }

    // 2) Busca local delimitada perto do usuário (prioriza comércios e locais de BH)
    List<PlaceResult> remote = [];
    try {
      if (near != null) {
        const delta = 0.25;
        remote = await _queryNominatim({
          'q': trimmed,
          'format': 'jsonv2',
          'limit': '15',
          'countrycodes': 'br',
          'accept-language': 'pt-BR',
          'viewbox':
              '${near.longitude - delta},${near.latitude + delta},'
              '${near.longitude + delta},${near.latitude - delta}',
          'bounded': '1',
        });
      }
      // Se achou poucos locais na região próxima, amplia para o Brasil todo
      if (remote.length < 3) {
        final wide = await _queryNominatim({
          'q': trimmed,
          'format': 'jsonv2',
          'limit': '12',
          'countrycodes': 'br',
          'accept-language': 'pt-BR',
          if (near != null)
            'viewbox':
                '${near.longitude - 0.35},${near.latitude + 0.35},'
                '${near.longitude + 0.35},${near.latitude - 0.35}',
        });
        remote = [...remote, ...wide];
      }
    } catch (_) {
      // Se estiver offline, ainda retorna favoritos/POIs locais encontrados acima
      if (combined.isEmpty) rethrow;
    }

    combined.addAll(remote);

    // 3) Deduplica segmentos repetidos da mesma rua/local próximos (< 200m)
    final deduped = <PlaceResult>[];
    for (final item in combined) {
      final alreadyExists = deduped.any((existing) =>
          _normalizeText(existing.name) == _normalizeText(item.name) &&
          GridCellHelper.haversineMeters(existing.latLng, item.latLng) < 200.0);
      if (!alreadyExists) {
        deduped.add(item);
      }
    }
    return deduped;
  }

  /// Busca comércios próximos usando Nominatim `bounded=1` (rápido e estável,
  /// sem sofrer bloqueio 406 do Overpass) em um raio de ~9 km do mapa.
  static Future<List<PlaceResult>> searchCategoryNearby(
    String categoryKey,
    LatLng center,
  ) async {
    const delta = 0.08; // ~9 km ao redor do centro
    final viewbox =
        '${center.longitude - delta},${center.latitude + delta},'
        '${center.longitude + delta},${center.latitude - delta}';

    Map<String, String> params(String q) => {
          'q': q,
          'format': 'jsonv2',
          'limit': '20',
          'countrycodes': 'br',
          'accept-language': 'pt-BR',
          'viewbox': viewbox,
          'bounded': '1',
        };

    final rawResults = <PlaceResult>[];
    if (categoryKey == 'fuel') {
      rawResults.addAll(await _queryNominatim(params('[amenity=fuel]')));
    } else if (categoryKey == 'workshop') {
      rawResults.addAll(await _queryNominatim(params('[shop=car_repair]')));
      if (rawResults.length < 6) {
        try {
          rawResults.addAll(await _queryNominatim(params('oficina')));
        } catch (_) {}
      }
    } else if (categoryKey == 'food') {
      rawResults.addAll(await _queryNominatim(params('[amenity=cafe]')));
      if (rawResults.length < 6) {
        try {
          rawResults.addAll(await _queryNominatim(params('[amenity=fast_food]')));
        } catch (_) {}
      }
    } else {
      try {
        rawResults.addAll(await _queryNominatim(params('[tourism=viewpoint]')));
      } catch (_) {}
      rawResults.addAll(builtInBhPlaces.where((p) =>
          p.category == 'mirante' || p.category == 'shopping'));
    }

    // Remove itens sem nome significativo ou duplicados próximos (< 120m)
    final cleaned = <PlaceResult>[];
    for (final r in rawResults) {
      final name = r.name.isNotEmpty
          ? r.name
          : categoryKey == 'fuel'
              ? 'Posto de Combustível'
              : categoryKey == 'workshop'
                  ? 'Oficina'
                  : 'Comércio';
      final dup = cleaned.any(
        (c) => GridCellHelper.haversineMeters(c.latLng, r.latLng) < 120.0,
      );
      if (!dup) {
        final distKm =
            GridCellHelper.haversineMeters(center, r.latLng) / 1000.0;
        cleaned.add(PlaceResult(
          name: name,
          subtitle: '${distKm.toStringAsFixed(2)} km • ${r.subtitle}',
          lat: r.lat,
          lng: r.lng,
          category: categoryKey,
        ));
      }
    }

    cleaned.sort((a, b) {
      final da = GridCellHelper.haversineMeters(center, a.latLng);
      final db = GridCellHelper.haversineMeters(center, b.latLng);
      return da.compareTo(db);
    });
    return cleaned;
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
