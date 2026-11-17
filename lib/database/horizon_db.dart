import 'package:latlong2/latlong.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/models.dart';

/// Persistência SQLite do Horizon Moto GPS:
/// - `rides` e `ride_points`: histórico de rolês e trajetos em laranja neon.
/// - `explored_cells`: malha espacial de setores descobertos (estilo Forza Horizon).
/// - `custom_radars`: radares/alertas cadastrados pelo motociclista.
/// - `checkpoints`: registros fotográficos georreferenciados durante os rolês.
class HorizonDatabase {
  HorizonDatabase._();
  static final HorizonDatabase instance = HorizonDatabase._();

  static const _dbName = 'horizon_moto_gps.db';
  static const _dbVersion = 1;

  Database? _db;

  Future<Database> get database async {
    _db ??= await _openDb();
    return _db!;
  }

  Future<Database> _openDb() async {
    final dbPath = join(await getDatabasesPath(), _dbName);
    return openDatabase(
      dbPath,
      version: _dbVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE rides (
            id                INTEGER PRIMARY KEY AUTOINCREMENT,
            title             TEXT    NOT NULL,
            start_time        TEXT    NOT NULL,
            duration_sec      INTEGER NOT NULL,
            distance_km       REAL    NOT NULL,
            new_discovery_km  REAL    NOT NULL,
            max_speed_kmh     REAL    NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE ride_points (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            ride_id   INTEGER NOT NULL,
            lat       REAL    NOT NULL,
            lng       REAL    NOT NULL,
            timestamp TEXT    NOT NULL,
            FOREIGN KEY (ride_id) REFERENCES rides (id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE explored_cells (
            cell_key      TEXT PRIMARY KEY,
            first_visited TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE custom_radars (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            lat         REAL    NOT NULL,
            lng         REAL    NOT NULL,
            speed_limit INTEGER NOT NULL,
            label       TEXT    NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE checkpoints (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            ride_id    INTEGER,
            title      TEXT    NOT NULL,
            photo_path TEXT    NOT NULL,
            lat        REAL    NOT NULL,
            lng        REAL    NOT NULL,
            timestamp  TEXT    NOT NULL,
            FOREIGN KEY (ride_id) REFERENCES rides (id) ON DELETE SET NULL
          )
        ''');
      },
    );
  }

  /// Carrega todas as células já descobertas no banco.
  Future<Set<String>> loadExploredCells() async {
    final db = await database;
    final rows = await db.query('explored_cells', columns: ['cell_key']);
    return rows.map((r) => r['cell_key'] as String).toSet();
  }

  /// Registra novas células exploradas em lote e retorna quantas eram inéditas.
  Future<int> markCellsExplored(List<String> keys) async {
    if (keys.isEmpty) return 0;
    final db = await database;
    final now = DateTime.now().toIso8601String();
    int newlyUnlocked = 0;

    await db.transaction((txn) async {
      for (final k in keys) {
        final inserted = await txn.insert(
          'explored_cells',
          {'cell_key': k, 'first_visited': now},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (inserted > 0) newlyUnlocked++;
      }
    });
    return newlyUnlocked;
  }

  /// Salva um rolê completo e todos os pontos do trajeto.
  Future<int> saveRide(RideRecord ride, List<LatLng> points) async {
    final db = await database;
    return db.transaction((txn) async {
      final map = ride.toMap()..remove('id');
      final rideId = await txn.insert('rides', map);
      final batch = txn.batch();
      final ts = ride.startTime.toIso8601String();
      for (final pt in points) {
        batch.insert('ride_points', {
          'ride_id': rideId,
          'lat': pt.latitude,
          'lng': pt.longitude,
          'timestamp': ts,
        });
      }
      await batch.commit(noResult: true);
      return rideId;
    });
  }

  /// Lista todos os rolês ordenados do mais recente ao mais antigo com suas rotas.
  Future<List<RideRecord>> listRides({bool includePoints = true}) async {
    final db = await database;
    final rideRows = await db.query('rides', orderBy: 'start_time DESC');
    final rides = <RideRecord>[];

    for (final row in rideRows) {
      final id = row['id'] as int;
      List<LatLng> pts = const [];
      if (includePoints) {
        final ptRows = await db.query(
          'ride_points',
          where: 'ride_id = ?',
          whereArgs: [id],
          orderBy: 'id ASC',
        );
        pts = ptRows
            .map((p) => LatLng(
                  (p['lat'] as num).toDouble(),
                  (p['lng'] as num).toDouble(),
                ))
            .toList();
      }
      rides.add(RideRecord.fromMap(row, pts: pts));
    }
    return rides;
  }

  /// Exclui um rolê (pontos vinculados são removidos via ON DELETE CASCADE).
  Future<void> deleteRide(int rideId) async {
    final db = await database;
    await db.delete('rides', where: 'id = ?', whereArgs: [rideId]);
  }

  /// Recalcula a tabela `explored_cells` (útil se o usuário resetar descobertas).
  Future<void> resetAllDiscoveries() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('ride_points');
      await txn.delete('rides');
      await txn.delete('explored_cells');
    });
  }

  /// Adiciona um radar/alerta customizado pelo usuário.
  Future<int> insertCustomRadar(RadarPoint radar) async {
    final db = await database;
    final map = radar.toMap()..remove('id');
    return db.insert('custom_radars', map);
  }

  Future<List<RadarPoint>> listCustomRadars() async {
    final db = await database;
    final rows = await db.query('custom_radars', orderBy: 'id DESC');
    return rows.map(RadarPoint.fromMap).toList();
  }

  Future<void> deleteCustomRadar(int id) async {
    final db = await database;
    await db.delete('custom_radars', where: 'id = ?', whereArgs: [id]);
  }

  /// Salva um checkpoint fotográfico tirado durante o rolê.
  Future<int> insertCheckpoint(PhotoCheckpoint checkpoint) async {
    final db = await database;
    final map = checkpoint.toMap()..remove('id');
    return db.insert('checkpoints', map);
  }

  Future<List<PhotoCheckpoint>> listCheckpoints() async {
    final db = await database;
    final rows = await db.query('checkpoints', orderBy: 'timestamp DESC');
    return rows.map(PhotoCheckpoint.fromMap).toList();
  }

  Future<void> deleteCheckpoint(int id) async {
    final db = await database;
    await db.delete('checkpoints', where: 'id = ?', whereArgs: [id]);
  }
}
