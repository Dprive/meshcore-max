import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:math' as math;
import '../models/contact.dart';
import '../services/topology_service.dart';
import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../storage/prefs_manager.dart';
import '../widgets/interactive_physics_graph.dart';
import '../utils/app_logger.dart';

class TopologyScreen extends StatefulWidget {
  const TopologyScreen({super.key});

  @override
  State<TopologyScreen> createState() => _TopologyScreenState();
}

class _TopologyScreenState extends State<TopologyScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  Contact? _selectedFrom;
  Contact? _selectedTo;
  List<RoutePath> _foundPaths = [];
  bool _isLoading = false;
  int? _testingPathIndex; 
  StreamSubscription<Uint8List>? _frameSubscription;
  Timer? _timeoutTimer;
  Uint8List _currentTag = Uint8List(4);
  RoutePath? _lastTestedPath;
  double _minReliability = 0.0;
  bool _showOnlyRepeaters = true;

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
            _handleTraceResponse(frame, _lastTestedPath);
          }
        }
      } catch (e) {
        appLogger.error("Error parsing frame in TopologyScreen: $e");
      }
    });
  }

  void _handleTraceResponse(Uint8List frame, RoutePath? lastPath) {
    if (lastPath == null) return;
    
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
        // Map SNR back to edges
        // lastPath.pathHashes includes [Me, R1, R2, ..., Destination]
        // If symmetric, lastPath.pathHashes remains the original forward path, 
        // but snrData contains extra hops.
        
        final forwardHops = lastPath.pathHashes;
        for (int i = 0; i < snrData.length; i++) {
          if (i < forwardHops.length - 1) {
            // Forward leg
            final from = forwardHops[i];
            final to = forwardHops[i+1];
            topologyService.updateEdgeSnr(from, to, snrData[i]);
          } else {
            // Return leg (if symmetric path was used)
            // snrData[forwardHops.length - 1] is Target -> Rn
            // i-th SNR corresponds to return leg index (i - (forwardHops.length - 1))
            final returnIndex = i - (forwardHops.length - 1);
            if (returnIndex < forwardHops.length - 1) {
               // forwardHops: [Me, R1, Dest] (len 3, offset 2)
               // snrData: [Me->R1, R1->Dest, Dest->R1, R1->Me] (len 4)
               // i=2 -> returnIndex=0 -> Dest->R1
               // i=3 -> returnIndex=1 -> R1->Me
               final from = forwardHops[forwardHops.length - 1 - returnIndex];
               final to = forwardHops[forwardHops.length - 2 - returnIndex];
               topologyService.updateEdgeSnr(from, to, snrData[i]);
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _testingPathIndex = null;
        });
        
        final avgSnr = snrData.isNotEmpty 
            ? snrData.reduce((a, b) => a + b) / snrData.length 
            : 0.0;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Test réussi ! SNR moyen: ${avgSnr.toStringAsFixed(1)} dB (${snrData.length} sauts)'),
            backgroundColor: Colors.blue.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      appLogger.error("Error handling trace response in TopologyScreen: $e");
      if (mounted) setState(() => _testingPathIndex = null);
    }
  }

  Uint8List _buildSymmetricPath(List<int> pathHashes, int targetType) {
    if (pathHashes.length < 2) return Uint8List.fromList(pathHashes);

    // pathHashes includes [Me, R1, ..., Target]
    // We want the trace to go [R1, ..., Target, ..., R1]
    final relays = List<int>.from(pathHashes);
    relays.removeAt(0); // Remove Me

    if (relays.isEmpty) return Uint8List(0);

    final target = relays.last;
    final intermediateRelays = relays.sublist(0, relays.length - 1);

    int totalLen;
    if (targetType == advTypeRepeater || targetType == advTypeRoom) {
      // Repeaters are usually the endpoint of the trace themselves
      // Path: [R1, ..., Rn, Target, Rn, ..., R1]
      totalLen = intermediateRelays.length * 2 + 1;
      final result = Uint8List(totalLen);
      for (int i = 0; i < intermediateRelays.length; i++) {
        result[i] = intermediateRelays[i];
        result[totalLen - 1 - i] = intermediateRelays[i];
      }
      result[intermediateRelays.length] = target;
      return result;
    } else {
      // Chat nodes: we trace to their last hop and back
      // Path: [R1, ..., Rn, Target, Rn, ..., R1] ??
      // Actually, if we want a full round trip to the target, it depends on if the target repeats.
      // Assuming symmetric behavior:
      totalLen = relays.length + intermediateRelays.length;
      final result = Uint8List(totalLen);
      for (int i = 0; i < relays.length; i++) {
        result[i] = relays[i];
      }
      for (int i = 0; i < intermediateRelays.length; i++) {
        result[totalLen - 1 - i] = intermediateRelays[i];
      }
      return result;
    }
  }

  void _loadTopology() {
    final connector = context.read<MeshCoreConnector>();
    final topologyService = context.read<TopologyService>();
    final myKey = connector.selfPublicKeyHex;
    topologyService.applyDecay(); // Background aging
    topologyService.buildGraph(connector.allContactsUnfiltered, myKey);
  }

  void _calculateRoutes() {
    if (_selectedFrom == null || _selectedTo == null) return;
    setState(() {
      _isLoading = true;
    });

    final topologyService = context.read<TopologyService>();
    final fromHash = _selectedFrom!.publicKey.first;
    final toHash = _selectedTo!.publicKey.first;

    final paths = topologyService.findPaths(fromHash, toHash,
        maxHops: 7, onlyRepeaters: _showOnlyRepeaters);

    setState(() {
      _foundPaths = paths;
      _isLoading = false;
    });
  }

  Future<void> _testRoute(int index, RoutePath path) async {
    setState(() {
      _testingPathIndex = index;
    });

    if (PrefsManager.isTestModeGlobal) {
      // Simulate a round-trip ping based on hop count
      final simulatedMs = path.hopCount * 60 + math.Random().nextInt(80);
      await Future.delayed(Duration(milliseconds: 400 + simulatedMs));
      if (!mounted) return;
      setState(() => _testingPathIndex = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.greenAccent),
              const SizedBox(width: 8),
              Text('Ping réussi en ${simulatedMs}ms via ${path.hopCount} saut(s)'),
            ],
          ),
          backgroundColor: Colors.green.shade800,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      // Real mode: send a trace request
      if (_frameSubscription == null) _setupFrameListener();

      final connector = context.read<MeshCoreConnector>();
      
      // Convert RoutePath to Uint8List path (excluding Me/Source if protocol expects only relays)
      // Actually buildTraceReq takes the full path from Me to Dest.
      // In path_trace_map.dart, they use buildTraceReq with a path.
      
      // We need to exclude the first hash (Me) from the path sent in the trace request 
      // because the mesh protocol usually expects the destination-bound relays.
      // Let's check how buildTraceReq is used.
      
      final tracePathValues = _buildSymmetricPath(path.pathHashes, _selectedTo?.type ?? 1);

      final tagInt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final tagBytes = Uint8List(4)..buffer.asByteData().setUint32(0, tagInt, Endian.little);
      _currentTag = tagBytes;

      final frame = buildTraceReq(
        tagInt,
        0, // auth
        0, // flag
        payload: tracePathValues,
      );
      
      connector.sendFrame(frame);
      _lastTestedPath = path;
      
      // The rest is handled by _frameSubscription
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
    final connector = context.read<MeshCoreConnector>();
    final List<Contact> contacts = List.from(connector.allContactsUnfiltered);
    
    // Add "Me" to contacts list if not present
    final myPk = connector.selfPublicKey;
    if (myPk != null && myPk.isNotEmpty) {
      final me = Contact(
        name: "Me (Moi)",
        publicKey: myPk,
        type: advTypeChat,
        pathLength: 0,
        path: Uint8List(0),
        lastSeen: DateTime.now(),
        latitude: connector.selfLatitude,
        longitude: connector.selfLongitude,
      );
      // Check if already in list (unlikely for My PK)
      if (!contacts.any((c) => listEquals(c.publicKey, myPk))) {
        contacts.insert(0, me);
      }
    }
    
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<Contact>(
                  hint: const Text("Source"),
                  value: _selectedFrom,
                  isExpanded: true,
                  items: contacts.map((c) => DropdownMenuItem(value: c, child: Text(c.name))).toList(),
                  onChanged: (c) {
                    setState(() => _selectedFrom = c);
                    _calculateRoutes();
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: DropdownButton<Contact>(
                  hint: const Text("Destination"),
                  value: _selectedTo,
                  isExpanded: true,
                  items: contacts.map((c) => DropdownMenuItem(value: c, child: Text(c.name))).toList(),
                  onChanged: (c) {
                    setState(() => _selectedTo = c);
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
                          onPressed: _testingPathIndex == null
                              ? () => _testRoute(index, path)
                              : null,
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
