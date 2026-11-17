import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../database/horizon_db.dart';
import '../models/models.dart';
import '../services/map_api_service.dart';
import 'rides_history_screen.dart';

/// Tela principal no estilo Forza Horizon + KTM Ready to Race:
/// - Ruas inéditas no mapa dark em cinza escuro; estradas já percorridas acendem
///   em Laranja Neon (#FF6600) com brilho persistente no SQLite.
/// - Busca de endereços, comércios próximos e roteamento OSRM com "% de estrada inédita".
/// - Radares públicos do OpenStreetMap + radares customizados com alerta a < 350m.
/// - Gravador de rolês completo + Checkpoints fotográficos + Modo Demo indoor.
class MapHomeScreen extends StatefulWidget {
  const MapHomeScreen({super.key});

  @override
  State<MapHomeScreen> createState() => _MapHomeScreenState();
}

class _MapHomeScreenState extends State<MapHomeScreen> {
  static const _bhCenter = LatLng(-19.919125, -43.938641); // Praça Sete / BH

  final MapController _mapController = MapController();
  final TextEditingController _searchCtrl = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  // Posição atual e stream de GPS
  LatLng _currentPos = _bhCenter;
  double _currentSpeedKmh = 0;
  bool _followGps = true;
  bool _darkMap = true;
  bool _gpsReady = false;
  StreamSubscription<Position>? _posSub;

  // Dados persistidos de exploração e rolês
  Set<String> _exploredCells = {};
  List<List<LatLng>> _historicalTrails = [];
  List<RadarPoint> _osmRadars = [];
  List<RadarPoint> _customRadars = [];
  List<PhotoCheckpoint> _checkpoints = [];

  // Trajeto contínuo em modo livre (desbloqueia estradas mesmo sem apertar Gravar)
  final List<LatLng> _freeRoamTrail = [];

  // Gravação ativa de um rolê nomeado
  bool _isRecording = false;
  DateTime? _rideStartTime;
  Timer? _rideTimer;
  Timer? _demoTimer;
  int _rideDurationSec = 0;
  double _rideDistanceKm = 0;
  double _rideNewDiscoveryKm = 0;
  double _rideMaxSpeedKmh = 0;
  final List<LatLng> _activeRidePoints = [];

  // Busca de comércios, rota ativa e alerta de radar
  bool _isSearching = false;
  bool _loadingRadars = false;
  List<PlaceResult> _searchResults = [];
  RouteResult? _activeRoute;
  RadarPoint? _nearbyRadarAlert;
  double? _nearbyRadarDistM;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _initStateAsync();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _rideTimer?.cancel();
    _demoTimer?.cancel();
    _searchCtrl.dispose();
    _flushFreeRoamSync();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _initStateAsync() async {
    await _loadPersistedData();
    await _startGpsTracking();
  }

  Future<void> _loadPersistedData() async {
    final db = HorizonDatabase.instance;
    final cells = await db.loadExploredCells();
    final rides = await db.listRides(includePoints: true);
    final customRadars = await db.listCustomRadars();
    final checkpoints = await db.listCheckpoints();

    if (!mounted) return;
    setState(() {
      _exploredCells = cells;
      _historicalTrails =
          rides.where((r) => r.points.length >= 2).map((r) => r.points).toList();
      _customRadars = customRadars;
      _checkpoints = checkpoints;
    });
  }

  Future<void> _startGpsTracking() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showToast('GPS desligado. Ative a localização ou use o modo Demo.');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _showToast('Permissão de GPS negada. Você pode testar usando o modo Demo.');
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      _onNewPosition(
        LatLng(pos.latitude, pos.longitude),
        pos.speed * 3.6,
        isInitial: true,
      );
      _loadRadarsAround(LatLng(pos.latitude, pos.longitude), silent: true);

      _posSub?.cancel();
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 6,
        ),
      ).listen((p) {
        if (_demoTimer != null) return; // pausa GPS real durante simulação demo
        _onNewPosition(LatLng(p.latitude, p.longitude), p.speed * 3.6);
      });
    } catch (_) {
      // Caso esteja em ambiente sem fix de satélite indoor, mantém mapa em BH
      // e libera busca + modo Demo normalmente.
    }
  }

  /// Processa cada novo ponto GPS: atualiza velocímetro, acende estradas
  /// inéditas em laranja neon, calcula alertas de radar e alimenta o gravador.
  Future<void> _onNewPosition(
    LatLng newPt,
    double speedKmh, {
    bool isInitial = false,
  }) async {
    final safeSpeed = speedKmh.isFinite && speedKmh > 0.5 ? speedKmh : 0.0;
    final prevPt = _currentPos;

    if (!isInitial) {
      final stepMeters = GridCellHelper.haversineMeters(prevPt, newPt);
      if (stepMeters >= 4 && stepMeters < 1500) {
        final cells = GridCellHelper.interpolateSegmentCells(prevPt, newPt);
        final newlyUnlocked =
            await HorizonDatabase.instance.markCellsExplored(cells);
        final newKm = newlyUnlocked * GridCellHelper.kmPerCell;

        if (!mounted) return;
        setState(() {
          _exploredCells.addAll(cells);
          if (_isRecording) {
            if (_activeRidePoints.isEmpty) _activeRidePoints.add(prevPt);
            _activeRidePoints.add(newPt);
            _rideDistanceKm += stepMeters / 1000.0;
            _rideNewDiscoveryKm += newKm;
            if (safeSpeed > _rideMaxSpeedKmh) _rideMaxSpeedKmh = safeSpeed;
          } else {
            if (_freeRoamTrail.isEmpty) _freeRoamTrail.add(prevPt);
            _freeRoamTrail.add(newPt);
          }
        });
      }
    }

    if (!mounted) return;
    setState(() {
      _currentPos = newPt;
      _currentSpeedKmh = safeSpeed;
      _gpsReady = true;
    });

    if (_followGps) {
      _mapController.move(newPt, _mapController.camera.zoom);
    }

    _checkRadarProximity(newPt);
  }

  void _checkRadarProximity(LatLng pos) {
    final allRadars = [..._osmRadars, ..._customRadars];
    RadarPoint? closest;
    double bestDist = double.infinity;

    for (final r in allRadars) {
      final d = GridCellHelper.haversineMeters(pos, r.latLng);
      if (d <= 350.0 && d < bestDist) {
        bestDist = d;
        closest = r;
      }
    }

    if (!mounted) return;
    setState(() {
      _nearbyRadarAlert = closest;
      _nearbyRadarDistM = closest != null ? bestDist : null;
    });
  }

  Future<void> _flushFreeRoamSync() async {
    if (_freeRoamTrail.length < 3) return;
    double distKm = 0;
    for (int i = 1; i < _freeRoamTrail.length; i++) {
      distKm += GridCellHelper.haversineMeters(
              _freeRoamTrail[i - 1], _freeRoamTrail[i]) /
          1000.0;
    }
    if (distKm < 0.03) return;
    final pts = List<LatLng>.from(_freeRoamTrail);
    _freeRoamTrail.clear();
    await HorizonDatabase.instance.saveRide(
      RideRecord(
        title: 'Exploração Livre (Auto)',
        startTime: DateTime.now(),
        durationSeconds: 0,
        distanceKm: distKm,
        newDiscoveryKm: distKm,
        maxSpeedKmh: 0,
      ),
      pts,
    );
  }

  // =========================================================================
  // GRAVADOR DE ROLÊS
  // =========================================================================

  Future<void> _toggleRecording() async {
    if (!_isRecording) {
      await _flushFreeRoamSync();
      await _loadPersistedData();
      setState(() {
        _isRecording = true;
        _rideStartTime = DateTime.now();
        _rideDurationSec = 0;
        _rideDistanceKm = 0;
        _rideNewDiscoveryKm = 0;
        _rideMaxSpeedKmh = _currentSpeedKmh;
        _activeRidePoints
          ..clear()
          ..add(_currentPos);
      });
      _rideTimer?.cancel();
      _rideTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _rideDurationSec++);
      });
      _showToast('Gravando rolê! Acelere para desbloquear estradas inéditas.');
      return;
    }

    _rideTimer?.cancel();
    _demoTimer?.cancel();
    _demoTimer = null;

    if (_activeRidePoints.length < 2) {
      setState(() => _isRecording = false);
      _showToast('Trajeto muito curto para salvar no histórico.');
      return;
    }

    final titleCtrl = TextEditingController(
      text: 'Rolê Duke 390 • ${DateTime.now().day}/${DateTime.now().month}',
    );
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161922),
        title: const Text('Salvar Rolê no Diário'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Distância: ${_rideDistanceKm.toStringAsFixed(2)} km • '
              '+${_rideNewDiscoveryKm.toStringAsFixed(2)} km inéditos',
              style: const TextStyle(fontSize: 12, color: Color(0xFFFF6600)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Nome do rolê',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Descartar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF6600),
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final ride = RideRecord(
        title: titleCtrl.text.trim().isEmpty
            ? 'Rolê sem nome'
            : titleCtrl.text.trim(),
        startTime: _rideStartTime ?? DateTime.now(),
        durationSeconds: _rideDurationSec,
        distanceKm: _rideDistanceKm,
        newDiscoveryKm: _rideNewDiscoveryKm,
        maxSpeedKmh: _rideMaxSpeedKmh,
      );
      await HorizonDatabase.instance.saveRide(ride, _activeRidePoints);
      _showToast('Rolê salvo no banco SQLite!');
    }

    setState(() {
      _isRecording = false;
      _activeRidePoints.clear();
    });
    await _loadPersistedData();
  }

  // =========================================================================
  // BUSCA DE COMÉRCIOS, ROTAS (% INÉDITO) E RADARES
  // =========================================================================

  Future<void> _searchText() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _isSearching = true);
    try {
      final results = await MapApiService.searchPlaces(q, near: _currentPos);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
      if (results.isEmpty) {
        _showToast('Nenhum local encontrado para "$q".');
      } else {
        _showPlacesBottomSheet('Resultados para "$q"', results);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSearching = false);
      _showToast('Erro ao buscar: $e');
    }
  }

  Future<void> _searchCategory(String key, String label) async {
    setState(() => _isSearching = true);
    try {
      final results =
          await MapApiService.searchCategoryNearby(key, _currentPos);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
      if (results.isEmpty) {
        _showToast('Nenhum(a) $label encontrado(a) em 4,5 km.');
      } else {
        _showPlacesBottomSheet('$label próximos', results);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSearching = false);
      _showToast('Erro na consulta: $e');
    }
  }

  Future<void> _loadRadarsAround(LatLng center, {bool silent = false}) async {
    if (_loadingRadars) return;
    setState(() => _loadingRadars = true);
    try {
      final radars = await MapApiService.fetchRadarsNearby(center);
      if (!mounted) return;
      setState(() {
        _osmRadars = radars;
        _loadingRadars = false;
      });
      _checkRadarProximity(_currentPos);
      if (!silent) {
        _showToast(
          '${radars.length} radares carregados ao redor + ${_customRadars.length} seus.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingRadars = false);
      if (!silent) _showToast('Não foi possível consultar radares: $e');
    }
  }

  Future<void> _navigateToPlace(PlaceResult dest) async {
    setState(() => _isSearching = true);
    try {
      final route = await MapApiService.calculateRoute(
        _currentPos,
        dest,
        _exploredCells,
      );
      if (!mounted) return;
      setState(() {
        _activeRoute = route;
        _isSearching = false;
        _followGps = false;
      });
      _mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: [_currentPos, dest.latLng],
          padding: const EdgeInsets.fromLTRB(48, 170, 48, 140),
        ),
      );
      // Carrega radares perto do destino também.
      _loadRadarsAround(dest.latLng, silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSearching = false);
      _showToast('Erro ao traçar rota: $e');
    }
  }

  void _showPlacesBottomSheet(String title, List<PlaceResult> items) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141821),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.explore, color: Color(0xFF00E5FF)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: Colors.white10),
              itemBuilder: (_, i) {
                final place = items[i];
                final distKm = GridCellHelper.haversineMeters(
                        _currentPos, place.latLng) /
                    1000.0;
                return ListTile(
                  leading: const Icon(Icons.place, color: Color(0xFFFF6600)),
                  title: Text(
                    place.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    place.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                  trailing: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00E5FF),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _navigateToPlace(place);
                    },
                    child: Text('Ir (${distKm.toStringAsFixed(1)} km)',
                        style: const TextStyle(fontSize: 12)),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // ADICIONAR RADAR CUSTOMIZADO & CHECKPOINT COM FOTO
  // =========================================================================

  Future<void> _showAddRadarDialog({LatLng? atPoint}) async {
    final target = atPoint ?? _currentPos;
    int selectedSpeed = 60;
    final labelCtrl = TextEditingController(text: 'Radar Fixo / Blitz');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF161922),
          title: const Text('Marcar Radar / Alerta'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: labelCtrl,
                decoration: const InputDecoration(
                  labelText: 'Descrição (ex: Radar Av. Raja)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Limite da via (km/h):',
                  style: TextStyle(fontSize: 12, color: Colors.white70)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [40, 50, 60, 70, 80, 100, 110].map((spd) {
                  final active = selectedSpeed == spd;
                  return ChoiceChip(
                    label: Text('$spd'),
                    selected: active,
                    selectedColor: const Color(0xFFFF2A55),
                    onSelected: (_) =>
                        setDialogState(() => selectedSpeed = spd),
                  );
                }).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF2A55),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Salvar Radar'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;
    await HorizonDatabase.instance.insertCustomRadar(RadarPoint(
      lat: target.latitude,
      lng: target.longitude,
      speedLimit: selectedSpeed,
      label: labelCtrl.text.trim().isEmpty ? 'Radar' : labelCtrl.text.trim(),
      isCustom: true,
    ));
    await _loadPersistedData();
    _checkRadarProximity(_currentPos);
    _showToast('Radar de $selectedSpeed km/h salvo no mapa!');
  }

  Future<void> _capturePhotoCheckpoint() async {
    try {
      final XFile? pic = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 1920,
      );
      if (pic == null || !mounted) return;

      final titleCtrl = TextEditingController(text: 'Parada do Rolê');
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF161922),
          title: const Text('Salvar Checkpoint Fotográfico'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(File(pic.path), height: 140, fit: BoxFit.cover),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nome do ponto / mirante',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF6600),
                foregroundColor: Colors.black,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Fixar no Mapa'),
            ),
          ],
        ),
      );
      if (ok != true) return;

      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'checkpoints'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final destPath = p.join(
        dir.path,
        'cp_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await File(pic.path).copy(destPath);

      await HorizonDatabase.instance.insertCheckpoint(PhotoCheckpoint(
        title: titleCtrl.text.trim().isEmpty
            ? 'Checkpoint'
            : titleCtrl.text.trim(),
        photoPath: destPath,
        lat: _currentPos.latitude,
        lng: _currentPos.longitude,
        timestamp: DateTime.now(),
      ));
      await _loadPersistedData();
      _showToast('Checkpoint salvo e fixado no mapa!');
    } catch (e) {
      _showToast('Erro ao abrir câmera: $e');
    }
  }

  // =========================================================================
  // SIMULADOR DEMO INDOOR (PARA TESTAR FORZA DISCOVERY + RADAR DENTRO DE CASA)
  // =========================================================================

  Future<void> _startDemoRide() async {
    if (_demoTimer != null) {
      _demoTimer?.cancel();
      _demoTimer = null;
      _showToast('Simulação Demo encerrada.');
      return;
    }

    // Circuito Praça da Liberdade -> Av. Bias Fortes -> Av. Afonso Pena (BH)
    const waypoints = <LatLng>[
      LatLng(-19.93205, -43.93798),
      LatLng(-19.93060, -43.93830),
      LatLng(-19.92880, -43.93862),
      LatLng(-19.92720, -43.93895),
      LatLng(-19.92550, -43.93930),
      LatLng(-19.92420, -43.93770),
      LatLng(-19.92310, -43.93610),
      LatLng(-19.92215, -43.93440),
      LatLng(-19.92370, -43.93330),
      LatLng(-19.92540, -43.93450),
      LatLng(-19.92710, -43.93570),
      LatLng(-19.92920, -43.93670),
      LatLng(-19.93150, -43.93750),
    ];

    // Coloca um radar de demonstração no meio da rota caso ainda não haja.
    final demoRadar = const RadarPoint(
      lat: -19.92480,
      lng: -43.93850,
      speedLimit: 60,
      label: 'Radar Demo (60 km/h)',
      isCustom: false,
    );
    setState(() {
      if (!_osmRadars.any((r) => r.label == demoRadar.label)) {
        _osmRadars = [..._osmRadars, demoRadar];
      }
      _followGps = true;
      _currentPos = waypoints.first;
    });
    _mapController.move(waypoints.first, 15.8);

    if (!_isRecording) {
      await _toggleRecording();
    }

    int idx = 1;
    _demoTimer = Timer.periodic(const Duration(milliseconds: 900), (timer) {
      if (!mounted || idx >= waypoints.length) {
        timer.cancel();
        _demoTimer = null;
        _showToast('Circuito Demo concluído! Clique em FINALIZAR ROLÊ para salvar.');
        return;
      }
      final simulatedSpeed = 54.0 + (idx % 4) * 9.0;
      _onNewPosition(waypoints[idx], simulatedSpeed);
      idx++;
    });
  }

  void _onMapLongPress(TapPosition _, LatLng point) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161922),
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.navigation, color: Color(0xFF00E5FF)),
              title: const Text('Traçar rota até este ponto',
                  style: TextStyle(color: Colors.white)),
              subtitle: Text(
                '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _navigateToPlace(PlaceResult(
                  name: 'Ponto no Mapa',
                  subtitle:
                      '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
                  lat: point.latitude,
                  lng: point.longitude,
                  category: 'pin',
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.speed, color: Color(0xFFFF2A55)),
              title: const Text('Marcar radar / alerta aqui',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _showAddRadarDialog(atPoint: point);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: const Color(0xFF1D222E),
        behavior: SnackBarBehavior.floating,
      ));
  }

  String _formatTimer(int sec) {
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final discoveredKm = _exploredCells.length * GridCellHelper.kmPerCell;
    final allRadars = [..._osmRadars, ..._customRadars];

    final allOrangePolylines = <Polyline>[];
    for (final trail in [
      ..._historicalTrails,
      if (_freeRoamTrail.length >= 2) _freeRoamTrail,
      if (_activeRidePoints.length >= 2) _activeRidePoints,
    ]) {
      // Camada 1: Brilho externo translúcido Forza/KTM
      allOrangePolylines.add(Polyline(
        points: trail,
        strokeWidth: 9.0,
        color: const Color(0x55FF6600),
      ));
      // Camada 2: Núcleo Laranja Neon intenso
      allOrangePolylines.add(Polyline(
        points: trail,
        strokeWidth: 4.2,
        color: const Color(0xFFFF7A00),
      ));
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0D0F14),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // =================================================================
          // CAMADA DO MAPA ESTILO FORZA HORIZON
          // =================================================================
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentPos,
              initialZoom: 15.2,
              maxZoom: 19,
              minZoom: 4,
              onLongPress: _onMapLongPress,
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture && _followGps) {
                  setState(() => _followGps = false);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: _darkMap
                    ? 'https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png'
                    : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.pedro.known_roads',
              ),

              // 1. Estradas descobertas em Laranja Neon
              PolylineLayer(polylines: allOrangePolylines),

              // 2. Rota de navegação GPS ativa em Ciano Horizon
              if (_activeRoute != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _activeRoute!.points,
                      strokeWidth: 8.0,
                      color: const Color(0x4400E5FF),
                    ),
                    Polyline(
                      points: _activeRoute!.points,
                      strokeWidth: 4.5,
                      color: const Color(0xFF00E5FF),
                    ),
                  ],
                ),

              // 3. Marcadores (Radares, Checkpoints, Busca, Destino e Moto)
              MarkerLayer(
                markers: [
                  // Radares fixos OSM + customizados
                  ...allRadars.map((r) => Marker(
                        point: r.latLng,
                        width: 42,
                        height: 42,
                        child: GestureDetector(
                          onTap: () => _showToast(
                              '${r.label} • Limite: ${r.speedLimit} km/h'),
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF161922),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFFFF2A55),
                                width: 2.5,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                '${r.speedLimit}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                      )),

                  // Checkpoints fotográficos
                  ..._checkpoints.map((cp) => Marker(
                        point: cp.latLng,
                        width: 36,
                        height: 36,
                        child: GestureDetector(
                          onTap: () => _showToast('Checkpoint: ${cp.title}'),
                          child: const CircleAvatar(
                            backgroundColor: Color(0xFFFF6600),
                            child: Icon(Icons.camera_alt,
                                size: 18, color: Colors.black),
                          ),
                        ),
                      )),

                  // Pinos de busca de comércios
                  ..._searchResults.take(12).map((pl) => Marker(
                        point: pl.latLng,
                        width: 34,
                        height: 34,
                        child: GestureDetector(
                          onTap: () => _navigateToPlace(pl),
                          child: const Icon(Icons.location_on,
                              color: Color(0xFF00E5FF), size: 32),
                        ),
                      )),

                  // Bandeira do destino ativo
                  if (_activeRoute != null)
                    Marker(
                      point: _activeRoute!.destination.latLng,
                      width: 40,
                      height: 40,
                      child: const Icon(Icons.flag_circle,
                          color: Color(0xFF00E5FF), size: 38),
                    ),

                  // Posição atual da moto
                  Marker(
                    point: _currentPos,
                    width: 46,
                    height: 46,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF6600),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0xAAFF6600),
                            blurRadius: 14,
                            spreadRadius: 3,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.two_wheeler,
                        color: Colors.black,
                        size: 24,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          // =================================================================
          // PAINEL SUPERIOR: BUSCA, CATEGORIAS, DESCOBERTA E ALERTA DE RADAR
          // =================================================================
          SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Barra de busca + Botão Demo + Badge Forza de Descoberta
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xEE141821),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        const Icon(Icons.search, color: Color(0xFFFF6600)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _searchCtrl,
                            onSubmitted: (_) => _searchText(),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14),
                            decoration: const InputDecoration(
                              hintText: 'Buscar rua, comércio, posto...',
                              hintStyle: TextStyle(
                                  color: Colors.white54, fontSize: 13),
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                        if (_isSearching)
                          const Padding(
                            padding: EdgeInsets.all(10),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Color(0xFFFF6600)),
                            ),
                          )
                        else
                          IconButton(
                            tooltip: 'Buscar',
                            icon: const Icon(Icons.arrow_forward,
                                color: Color(0xFF00E5FF)),
                            onPressed: _searchText,
                          ),
                      ],
                    ),
                  ),
                ),

                // Chips rápidos de Comércios e Radares + Progresso Forza
                SizedBox(
                  height: 36,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      _forzaBadge(
                        '${discoveredKm.toStringAsFixed(2)} km descobertos (${_exploredCells.length})',
                      ),
                      const SizedBox(width: 6),
                      _quickChip(Icons.local_gas_station, 'Postos',
                          () => _searchCategory('fuel', 'Postos')),
                      const SizedBox(width: 6),
                      _quickChip(Icons.build, 'Oficinas',
                          () => _searchCategory('workshop', 'Oficinas')),
                      const SizedBox(width: 6),
                      _quickChip(Icons.fastfood, 'Cafés',
                          () => _searchCategory('food', 'Cafés e Lanches')),
                      const SizedBox(width: 6),
                      _quickChip(
                        Icons.speed,
                        _loadingRadars ? 'Buscando...' : 'Radares OSM',
                        () => _loadRadarsAround(_mapController.camera.center),
                      ),
                      const SizedBox(width: 6),
                      _quickChip(
                        Icons.bolt,
                        _demoTimer != null ? 'Parar Demo' : 'Simular Rolê BH',
                        _startDemoRide,
                        highlight: _demoTimer != null,
                      ),
                    ],
                  ),
                ),

                // Alerta Crítico de Proximidade de Radar (< 350m)
                if (_nearbyRadarAlert != null)
                  Container(
                    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xEEFF2A55),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: Colors.white, size: 28),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'RADAR A ${_nearbyRadarDistM?.round() ?? 0}m • LIMITE ${_nearbyRadarAlert!.speedLimit} km/h',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Banner da Rota Ativa (Ciano Forza + % Estrada Inédita)
                if (_activeRoute != null)
                  Container(
                    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xF0141821),
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: const Color(0xFF00E5FF), width: 1.5),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.turn_right,
                            color: Color(0xFF00E5FF), size: 26),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _activeRoute!.nextInstruction,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${_activeRoute!.distanceKm.toStringAsFixed(1)} km • '
                                '${_activeRoute!.durationMinutes.round()} min • '
                                '${_activeRoute!.unexploredPercent.toStringAsFixed(0)}% estrada inédita',
                                style: const TextStyle(
                                  color: Color(0xFFFF8800),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Cancelar rota',
                          icon: const Icon(Icons.close, color: Colors.white70),
                          onPressed: () => setState(() => _activeRoute = null),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // =================================================================
          // BOTÕES LATERAIS (CENTRALIZAR, MAPA DARK/DIA, +RADAR, +CHECKPOINT)
          // =================================================================
          Positioned(
            right: 12,
            bottom: 112,
            child: Column(
              children: [
                _sideFab(
                  tooltip: 'Centralizar na moto',
                  icon: _followGps ? Icons.gps_fixed : Icons.gps_not_fixed,
                  color: _followGps ? const Color(0xFFFF6600) : Colors.white,
                  onTap: () {
                    setState(() => _followGps = true);
                    _mapController.move(_currentPos, 16.0);
                    if (!_gpsReady) _startGpsTracking();
                  },
                ),
                const SizedBox(height: 8),
                _sideFab(
                  tooltip: 'Alternar mapa Escuro / Claro',
                  icon: _darkMap ? Icons.light_mode : Icons.dark_mode,
                  color: Colors.white,
                  onTap: () => setState(() => _darkMap = !_darkMap),
                ),
                const SizedBox(height: 8),
                _sideFab(
                  tooltip: 'Marcar Radar aqui',
                  icon: Icons.add_alert,
                  color: const Color(0xFFFF2A55),
                  onTap: () => _showAddRadarDialog(),
                ),
                const SizedBox(height: 8),
                _sideFab(
                  tooltip: 'Salvar Checkpoint com Foto',
                  icon: Icons.add_a_photo,
                  color: const Color(0xFF00E5FF),
                  onTap: _capturePhotoCheckpoint,
                ),
              ],
            ),
          ),

          // =================================================================
          // PAINEL INFERIOR KTM TFT (VELOCÍMETRO + GRAVADOR + HISTÓRICO)
          // =================================================================
          Positioned(
            left: 10,
            right: 10,
            bottom: 12,
            child: SafeArea(
              top: false,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xF2141821),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _isRecording
                        ? const Color(0xFFFF6600)
                        : Colors.white12,
                    width: _isRecording ? 1.8 : 1.0,
                  ),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 16),
                  ],
                ),
                child: Row(
                  children: [
                    // Velocímetro Digital TFT
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              _currentSpeedKmh.toStringAsFixed(0),
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFFFF6600),
                                height: 1,
                              ),
                            ),
                            const SizedBox(width: 3),
                            const Text(
                              'km/h',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.white60,
                              ),
                            ),
                          ],
                        ),
                        if (_isRecording)
                          Text(
                            '${_formatTimer(_rideDurationSec)} • ${_rideDistanceKm.toStringAsFixed(2)} km',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF00E5FF),
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        else
                          const Text(
                            'READY TO RACE',
                            style: TextStyle(
                              fontSize: 9,
                              letterSpacing: 1.0,
                              color: Colors.white38,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    // Botão Principal Iniciar / Finalizar Rolê
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: _isRecording
                              ? const Color(0xFFFF2A55)
                              : const Color(0xFFFF6600),
                          foregroundColor:
                              _isRecording ? Colors.white : Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _toggleRecording,
                        icon: Icon(
                          _isRecording ? Icons.stop : Icons.play_arrow,
                          size: 20,
                        ),
                        label: Text(
                          _isRecording ? 'FINALIZAR ROLÊ' : 'INICIAR ROLÊ',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Histórico de Rolês
                    IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xFF212634),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      tooltip: 'Histórico de Rolês e Checkpoints',
                      icon: const Icon(Icons.history),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => RidesHistoryScreen(
                              onDataChanged: _loadPersistedData,
                              onFocusRide: (ride) {
                                setState(() => _followGps = false);
                                _mapController.fitCamera(
                                  CameraFit.coordinates(
                                    coordinates: ride.points,
                                    padding: const EdgeInsets.all(56),
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _forzaBadge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xEE141821),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFFF6600)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: Color(0xFFFF8800),
        ),
      ),
    );
  }

  Widget _quickChip(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool highlight = false,
  }) {
    return ActionChip(
      backgroundColor:
          highlight ? const Color(0xFFFF6600) : const Color(0xEE141821),
      side: BorderSide(
        color: highlight ? Colors.white : Colors.white12,
      ),
      avatar: Icon(
        icon,
        size: 16,
        color: highlight ? Colors.black : const Color(0xFF00E5FF),
      ),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: highlight ? Colors.black : Colors.white,
        ),
      ),
      onPressed: onTap,
    );
  }

  Widget _sideFab({
    required String tooltip,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xEE141821),
      shape: const CircleBorder(side: BorderSide(color: Colors.white12)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, color: color, size: 22),
          ),
        ),
      ),
    );
  }
}
