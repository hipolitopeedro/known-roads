import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database/horizon_db.dart';
import '../models/models.dart';

/// Tela de histórico de rolês, estatísticas totais de exploração,
/// checkpoints com foto e radares cadastrados manualmente.
class RidesHistoryScreen extends StatefulWidget {
  final VoidCallback onDataChanged;
  final void Function(RideRecord ride) onFocusRide;

  const RidesHistoryScreen({
    super.key,
    required this.onDataChanged,
    required this.onFocusRide,
  });

  @override
  State<RidesHistoryScreen> createState() => _RidesHistoryScreenState();
}

class _RidesHistoryScreenState extends State<RidesHistoryScreen> {
  static final _dateFmt = DateFormat('dd/MM/yyyy • HH:mm');

  List<RideRecord> _rides = [];
  List<RadarPoint> _radars = [];
  List<PhotoCheckpoint> _checkpoints = [];
  int _exploredCellsCount = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final db = HorizonDatabase.instance;
    final rides = await db.listRides(includePoints: true);
    final radars = await db.listCustomRadars();
    final checkpoints = await db.listCheckpoints();
    final cells = await db.loadExploredCells();

    if (!mounted) return;
    setState(() {
      _rides = rides;
      _radars = radars;
      _checkpoints = checkpoints;
      _exploredCellsCount = cells.length;
      _loading = false;
    });
  }

  String _formatDuration(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _confirmDeleteRide(RideRecord ride) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161922),
        title: const Text('Excluir rolê'),
        content: Text('Deseja apagar "${ride.title}" do seu histórico?'),
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
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (ok != true || ride.id == null) return;
    await HorizonDatabase.instance.deleteRide(ride.id!);
    widget.onDataChanged();
    _loadAll();
  }

  Future<void> _confirmResetAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161922),
        title: const Text('Zerar mapa descoberto?'),
        content: const Text(
          'Isso apaga todas as estradas desbloqueadas (laranja) e todos os rolês salvos. Radares salvos permanecem.',
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
            child: const Text('Zerar tudo'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await HorizonDatabase.instance.resetAllDiscoveries();
    widget.onDataChanged();
    _loadAll();
  }

  @override
  Widget build(BuildContext context) {
    final discoveredKm = _exploredCellsCount * GridCellHelper.kmPerCell;
    final totalRideKm = _rides.fold<double>(0, (s, r) => s + r.distanceKm);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0F14),
        appBar: AppBar(
          backgroundColor: const Color(0xFF141821),
          title: const Text(
            'KNOWN ROADS • DIÁRIO',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              letterSpacing: 0.8,
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'Zerar mapa descoberto',
              icon: const Icon(Icons.restart_alt, color: Color(0xFFFF6600)),
              onPressed: _confirmResetAll,
            ),
          ],
          bottom: const TabBar(
            indicatorColor: Color(0xFFFF6600),
            labelColor: Color(0xFFFF6600),
            unselectedLabelColor: Colors.white60,
            tabs: [
              Tab(text: 'ROLÊS', icon: Icon(Icons.route, size: 18)),
              Tab(text: 'CHECKPOINTS', icon: Icon(Icons.photo_camera, size: 18)),
              Tab(text: 'RADARES', icon: Icon(Icons.speed, size: 18)),
            ],
          ),
        ),
        body: _loading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFFFF6600)),
              )
            : Column(
                children: [
                  // Resumo Horizon / KTM TFT no topo
                  Container(
                    margin: const EdgeInsets.all(12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161922),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0x66FF6600)),
                    ),
                    child: Row(
                      children: [
                        _statBox(
                          'DESCOBERTO',
                          '${discoveredKm.toStringAsFixed(2)} km',
                          const Color(0xFFFF6600),
                        ),
                        _statBox(
                          'SETORES',
                          '$_exploredCellsCount',
                          const Color(0xFF00E5FF),
                        ),
                        _statBox(
                          'ODÔMETRO APP',
                          '${totalRideKm.toStringAsFixed(1)} km',
                          Colors.white,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildRidesTab(),
                        _buildCheckpointsTab(),
                        _buildRadarsTab(),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _statBox(String label, String value, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Colors.white54,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRidesTab() {
    if (_rides.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Nenhum rolê gravado ainda.\nToque em "INICIAR ROLÊ" ou rode o modo Demo no mapa!',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: _rides.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (ctx, i) {
        final r = _rides[i];
        return InkWell(
          onTap: r.points.isNotEmpty
              ? () {
                  widget.onFocusRide(r);
                  Navigator.pop(context);
                }
              : null,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF161922),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.two_wheeler,
                        color: Color(0xFFFF6600), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        r.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.white38, size: 20),
                      onPressed: () => _confirmDeleteRide(r),
                    ),
                  ],
                ),
                Text(
                  _dateFmt.format(r.startTime),
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _pill('${r.distanceKm.toStringAsFixed(2)} km',
                        const Color(0xFF00E5FF)),
                    _pill('+${r.newDiscoveryKm.toStringAsFixed(2)} km inéditos',
                        const Color(0xFFFF6600)),
                    _pill('Máx ${r.maxSpeedKmh.toStringAsFixed(0)} km/h',
                        Colors.white70),
                    _pill(_formatDuration(r.durationSeconds), Colors.white70),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0F14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _buildCheckpointsTab() {
    if (_checkpoints.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Nenhum checkpoint fotográfico salvo.\nUse o botão da câmera no mapa para registrar lugares novos!',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: _checkpoints.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (ctx, i) {
        final cp = _checkpoints[i];
        final file = File(cp.photoPath);
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF161922),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              SizedBox(
                width: 96,
                height: 96,
                child: file.existsSync()
                    ? Image.file(file, fit: BoxFit.cover)
                    : Container(
                        color: Colors.black38,
                        child: const Icon(Icons.photo, color: Colors.white38),
                      ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        cp.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _dateFmt.format(cp.timestamp),
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54),
                      ),
                      Text(
                        '${cp.lat.toStringAsFixed(5)}, ${cp.lng.toStringAsFixed(5)}',
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF00E5FF)),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.white38),
                onPressed: () async {
                  if (cp.id != null) {
                    await HorizonDatabase.instance.deleteCheckpoint(cp.id!);
                    if (await file.exists()) await file.delete();
                    widget.onDataChanged();
                    _loadAll();
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRadarsTab() {
    if (_radars.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Você ainda não marcou nenhum radar próprio.\nOs radares públicos do OpenStreetMap são carregados direto no mapa.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: _radars.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) {
        final rd = _radars[i];
        return ListTile(
          tileColor: const Color(0xFF161922),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Colors.white12),
          ),
          leading: CircleAvatar(
            backgroundColor: const Color(0xFFFF2A55),
            child: Text(
              '${rd.speedLimit}',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 13,
              ),
            ),
          ),
          title: Text(rd.label, style: const TextStyle(color: Colors.white)),
          subtitle: Text(
            '${rd.lat.toStringAsFixed(5)}, ${rd.lng.toStringAsFixed(5)}',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white54),
            onPressed: () async {
              if (rd.id != null) {
                await HorizonDatabase.instance.deleteCustomRadar(rd.id!);
                widget.onDataChanged();
                _loadAll();
              }
            },
          ),
        );
      },
    );
  }
}
