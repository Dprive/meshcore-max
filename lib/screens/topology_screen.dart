import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:math' as math;

import '../services/topology_service.dart';
import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../storage/prefs_manager.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../widgets/interactive_physics_graph.dart';
import '../utils/app_logger.dart';

class TopologyScreen extends StatefulWidget {
  const TopologyScreen({super.key});

  @override
  State<TopologyScreen> createState() => _TopologyScreenState();
}

class _TopologyScreenState extends State<TopologyScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  TopologyNode? _selectedFrom;
  TopologyNode? _selectedTo;
  List<RoutePath> _foundPaths = [];
  bool _isLoading = false;
  int? _testingPathIndex; 
  StreamSubscription<Uint8List>? _frameSubscription;
  Timer? _timeoutTimer;
  Uint8List _currentTag = Uint8List(4);
  List<int>? _lastTestedRoundTrip;
  double _minReliability = 0.0;
  bool _showOnlyRepeaters = true;
  bool _isPinging = false;
  Completer<List<double>?>? _pingCompleter;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTopology();
    });
  }
  
  @override
  void dispose() {
    _tabController.dispose();
    _frameSubscription?.cancel();
    _timeoutTimer?.cancel();
    super.dispose();
  }

  void _setupFrameListener() {
    final connector = context.read<MeshCoreConnector>();
    _frameSubscription = connector.receivedFrames.listen((frame) {
      if (frame.isEmpty) return;
      final reader = BufferReader(frame);
      try {
        final code = reader.readUInt8();
        
        if (code == respCodeSent) {
          reader.skipBytes(1); // reserved
          final tag = reader.readBytes(4);
          if (listEquals(tag, _currentTag)) {
             final timeout = reader.readUInt32LE();
             _timeoutTimer?.cancel();
             _timeoutTimer = Timer(Duration(milliseconds: timeout + 1000), () {
               if (mounted) {
                 setState(() {
                   _testingPathIndex = null;
                 });
                 ScaffoldMessenger.of(context).showSnackBar(
                   const SnackBar(content: Text("Test de route : Délai dépassé (Timeout)"))
                 );
               }
             });
          }
        }

        if (code == pushCodeTraceData) {
          reader.skipBytes(3); // reserved + path length + flag
          final tag = reader.readBytes(4);
          if (listEquals(tag, _currentTag)) {
            _timeoutTimer?.cancel();
            final snrData = _parseTraceResponse(frame, _lastTestedRoundTrip);
            if (_pingCompleter?.isCompleted == false) {
              _pingCompleter?.complete(snrData);
            }
          }
        }
      } catch (e) {
        appLogger.error("Error parsing frame in TopologyScreen: $e");
      }
    });
  }

  List<double>? _parseTraceResponse(Uint8List frame, List<int>? fullPathHashes) {
    if (fullPathHashes == null) return null;
    
    final buffer = BufferReader(frame);
    try {
      buffer.skipBytes(2); // Skip push code and reserved byte
      int pathLength = buffer.readUInt8();
      buffer.skipBytes(5); // Skip Flag byte and tag data
      buffer.skipBytes(4); // Skip auth code
      buffer.readBytes(pathLength); // Skip pathData
      List<double> snrData = buffer
          .readRemainingBytes()
          .map((snr) => snr.toSigned(8).toDouble() / 4)
          .toList();

      if (snrData.isNotEmpty) {
        final topologyService = context.read<TopologyService>();
        final hops = fullPathHashes;
        for (int i = 0; i < snrData.length && i < hops.length - 1; i++) {
          final from = hops[i];
          final to = hops[i+1];
          topologyService.updateEdgeSnr(from, to, snrData[i]);
        }
      }
      return snrData;
    } catch (e) {
      appLogger.error("Error parsing trace response in TopologyScreen: $e");
      return null;
    }
  }

  List<int> _calculateRoundTripHashes(List<int> forwardPathHashes, int targetType) {
    if (forwardPathHashes.length < 2) return List<int>.from(forwardPathHashes);

    final topologyService = context.read<TopologyService>();
    final targetHash = forwardPathHashes.last;
    final sourceHash = forwardPathHashes.first;

    final returnPaths = topologyService.findPaths(targetHash, sourceHash, maxHops: 7, onlyRepeaters: _showOnlyRepeaters);
    
    List<int> returnLeg = [];
    if (returnPaths.isNotEmpty) {
      returnLeg = List<int>.from(returnPaths.first.pathHashes);
      if (returnLeg.isNotEmpty) returnLeg.removeAt(0); 
    } else {
      returnLeg = List<int>.from(forwardPathHashes.reversed);
      if (returnLeg.isNotEmpty) returnLeg.removeAt(0); 
    }

    return List<int>.from(forwardPathHashes)..addAll(returnLeg);
  }

  Uint8List _buildTracePayload(List<int> fullPathHashes) {
    final relays = List<int>.from(fullPathHashes);
    if (_selectedFrom?.isMe == true) {
      if (relays.isNotEmpty) {
        final sourceHash = relays.first;
        relays.removeAt(0);
        if (relays.isNotEmpty && relays.last == sourceHash) relays.removeLast();
      }
    }
    return Uint8List.fromList(relays);
  }

  void _loadTopology() async {
    setState(() {
      _isLoading = true;
    });

    final topologyService = context.read<TopologyService>();
    final connector = context.read<MeshCoreConnector>();
    
    topologyService.clearGraph();

    final repeaterIds = <String>{};
    repeaterIds.add('3410914e5f1660bf08b015126574dbc8bed381615de8699d2b7861c474d18bdf'); // Saint Lazare

    for (final contact in connector.allContactsUnfiltered) {
      if (contact.type == advTypeRepeater) {
        repeaterIds.add(contact.publicKeyHex);
      }
    }

    try {
      await Future.wait(repeaterIds.map((id) async {
        try {
          final response = await http.get(Uri.parse('https://analyzer.meshcore.paris/api/nodes/$id'));
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            if (!mounted) return;
            topologyService.addGraphFromApi(data);
          }
        } catch (e) {
          appLogger.error("Failed to fetch topology for $id: $e");
        }
      }));
    } catch (e) {
      appLogger.error("Failed to fetch topology: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _calculateRoutes() {
    if (_selectedFrom == null || _selectedTo == null) return;
    setState(() {
      _isLoading = true;
    });

    final topologyService = context.read<TopologyService>();
    final fromHash = _selectedFrom!.hash;
    final toHash = _selectedTo!.hash;

    final paths = topologyService.findPaths(fromHash, toHash,
        maxHops: 7, onlyRepeaters: _showOnlyRepeaters);

    setState(() {
      _foundPaths = paths;
      _isLoading = false;
    });
  }

  Future<void> _testRoute(int index, RoutePath path) async {
    if (_isPinging) return;
    setState(() {
      _testingPathIndex = index;
      _isPinging = true;
    });

    if (PrefsManager.isTestModeGlobal) {
      final simulatedMs = path.hopCount * 60 + math.Random().nextInt(80);
      await Future.delayed(Duration(milliseconds: 400 + simulatedMs));
      if (!mounted) return;
      setState(() {
        _testingPathIndex = null;
        _isPinging = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.greenAccent),
              const SizedBox(width: 8),
              Text('Ping simulé réussi en ${simulatedMs}ms via ${path.hopCount} saut(s)'),
            ],
          ),
          backgroundColor: Colors.green.shade800,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      if (_frameSubscription == null) _setupFrameListener();

      final connector = context.read<MeshCoreConnector>();
      final fullRoundTripHashes = _calculateRoundTripHashes(path.pathHashes, _selectedTo?.type ?? 1);
      final tracePathValues = _buildTracePayload(fullRoundTripHashes);

      int successes = 0;
      List<double> allSnrs = [];

      for (int i = 0; i < 3; i++) {
        if (!mounted) break;

        final tagInt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final tagBytes = Uint8List(4)..buffer.asByteData().setUint32(0, tagInt, Endian.little);
        _currentTag = tagBytes;

        final frame = buildTraceReq(
          tagInt,
          0,
          0,
          payload: tracePathValues,
        );

        _pingCompleter = Completer<List<double>?>();
        _lastTestedRoundTrip = fullRoundTripHashes;

        connector.sendFrame(frame);

        _timeoutTimer?.cancel();
        _timeoutTimer = Timer(const Duration(seconds: 15), () {
          if (_pingCompleter?.isCompleted == false) {
             _pingCompleter?.complete(null);
          }
        });

        final snrData = await _pingCompleter!.future;
        if (snrData != null) {
           successes++;
           allSnrs.addAll(snrData);
        }

        if (i < 2 && mounted) {
           await Future.delayed(const Duration(seconds: 1));
        }
      }

      if (!mounted) return;
      setState(() {
        _testingPathIndex = null;
        _isPinging = false;
      });

      if (successes > 0) {
        final avgSnr = allSnrs.isNotEmpty 
            ? allSnrs.reduce((a, b) => a + b) / allSnrs.length 
            : 0.0;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Test de route : $successes/3 paquets reçus. SNR moyen: ${avgSnr.toStringAsFixed(1)} dB'),
            backgroundColor: Colors.blue.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Test de route échoué (Timeout 3/3)")),
        );
      }
    }
  }
  
  String _nodeNameFromHash(int hash) {
    if (hash == 0) return "Unknown";
    final connector = context.read<MeshCoreConnector>();
    // Check if it's me
    if (connector.selfPublicKeyHex.isNotEmpty) {
      // Decode hex to see if first byte matches... wait! Best is to iterate contacts
    }
    
    for (var c in connector.allContactsUnfiltered) {
      if (c.publicKey.isNotEmpty && c.publicKey.first == hash) {
        return c.name;
      }
    }
    return "Node ${hash.toRadixString(16).toUpperCase()}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Network Topology & Routing'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Topology'),
            Tab(text: 'Routing'),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_minReliability > 0 ? Icons.filter_list_alt : Icons.filter_list),
            onPressed: _showFilterMenu,
            tooltip: "Filtres de vue",
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
               _loadTopology();
               if (_tabController.index == 1) {
                 _calculateRoutes();
               }
            },
          )
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildTopologyTab(),
          _buildRoutingTab(),
        ],
      ),
    );
  }

  Widget _buildTopologyTab() {
    return Consumer<TopologyService>(
      builder: (context, topology, child) {
        final edges = topology.getAllEdges();
        if (edges.isEmpty) {
           return const Center(child: Text("No connections discovered yet."));
        }
        
        return InteractivePhysicsGraph(
           edges: edges, 
           nodes: topology.nodes,
           minReliability: _minReliability,
           showOnlyRepeaters: _showOnlyRepeaters,
           onNodeTap: _showNodeDetails,
           onEdgeTap: _showEdgeDetails,
        );
      },
    );
  }

  Widget _buildRoutingTab() {
    final topologyService = context.read<TopologyService>();
    final List<TopologyNode> nodes = topologyService.nodes.values.toList();
    
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<TopologyNode>(
                  hint: const Text("Source"),
                  value: _selectedFrom,
                  isExpanded: true,
                  items: nodes.map((n) => DropdownMenuItem(value: n, child: Text(n.name))).toList(),
                  onChanged: (n) {
                    setState(() => _selectedFrom = n);
                    _calculateRoutes();
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: DropdownButton<TopologyNode>(
                  hint: const Text("Destination"),
                  value: _selectedTo,
                  isExpanded: true,
                  items: nodes.map((n) => DropdownMenuItem(value: n, child: Text(n.name))).toList(),
                  onChanged: (n) {
                    setState(() => _selectedTo = n);
                    _calculateRoutes();
                  },
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        if (_isLoading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_selectedFrom == null || _selectedTo == null)
          const Expanded(child: Center(child: Text("Select source and destination nodes.")))
        else if (_foundPaths.isEmpty)
          const Expanded(child: Center(child: Text("No paths found.")))
        else
          Expanded(
            child: ListView.builder(
              itemCount: _foundPaths.length,
              itemBuilder: (context, index) {
                final path = _foundPaths[index];
                
                // Format path string
                final names = path.pathHashes.map((h) => _nodeNameFromHash(h)).join(' → ');
                
                return ListTile(
                  leading: CircleAvatar(child: Text('${path.hopCount}')),
                  title: Text(names),
                  subtitle: Text('Stability Score: ${(path.stabilityScore * 100).toStringAsFixed(1)}%'),
                  trailing: _testingPathIndex == index
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonalIcon(
                          onPressed: _isPinging
                              ? null
                              : () => _testRoute(index, path),
                          icon: const Icon(Icons.flash_on, size: 16),
                          label: const Text('Tester'),
                        ),
                );
              },
            ),
          )
      ],
    );
  }

  void _showFilterMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Filtres de topologie", style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 20),
                  SwitchListTile(
                    title: const Text("Squelette seul (Fiabilité > 30%)"),
                    subtitle: const Text("Masque les liens instables ou faibles"),
                    value: _minReliability >= 0.3,
                    onChanged: (val) {
                      setState(() => _minReliability = val ? 0.3 : 0.0);
                      setModalState(() {});
                    },
                  ),
                  SwitchListTile(
                    title: const Text("Répéteurs uniquement"),
                    subtitle: const Text("Masque les Smartphones / Compagnons"),
                    value: _showOnlyRepeaters,
                    onChanged: (val) {
                      setState(() => _showOnlyRepeaters = val);
                      setModalState(() {});
                    },
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            );
          }
        );
      },
    );
  }

  void _showNodeDetails(TopologyNode node) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    node.isMe ? Icons.person_pin : (node.type == advTypeRepeater ? Icons.router : Icons.smartphone),
                    color: Theme.of(context).colorScheme.primary,
                    size: 32,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(node.name, style: Theme.of(context).textTheme.titleLarge),
                        Text("Hash: 0x${node.hash.toRadixString(16).padLeft(2, '0').toUpperCase()}", 
                             style: Theme.of(context).textTheme.labelMedium),
                      ],
                    ),
                  ),
                ],
              ),
              const Divider(height: 32),
              _detailRow(Icons.info_outline, "Type", node.type == advTypeChat ? "Compagnon" : "Répéteur"),
              if (node.isMe) _detailRow(Icons.check_circle_outline, "Status", "Votre nœud (Ancré)"),
            ],
          ),
        );
      },
    );
  }

  void _showEdgeDetails(Edge edge) {
    final fromName = _nodeNameFromHash(edge.from);
    final toName = _nodeNameFromHash(edge.to);
    
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Détails du lien", style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              Text("$fromName ↔ $toName", style: Theme.of(context).textTheme.titleMedium),
              const Divider(height: 32),
              _detailRow(Icons.signal_wifi_4_bar, "Fiabilité", "${(edge.reliability * 100).toStringAsFixed(1)}%"),
              _detailRow(Icons.analytics_outlined, "Succès / Tentatives", "${edge.successCount} / ${edge.totalAttempts}"),
              _detailRow(Icons.access_time, "Dernière vue", _formatTimestamp(edge.lastHeard)),
            ],
          ),
        );
      },
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey[600]),
          const SizedBox(width: 12),
          Text("$label : ", style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(value),
        ],
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return "À l'instant";
    if (diff.inMinutes < 60) return "Il y a ${diff.inMinutes} min";
    if (diff.inHours < 24) return "Il y a ${diff.inHours} h";
    return "${dt.day}/${dt.month} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}";
  }
}
