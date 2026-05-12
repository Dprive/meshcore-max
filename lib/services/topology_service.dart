import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/contact.dart';
import '../services/path_history_service.dart';
import '../connector/meshcore_protocol.dart';

class RoutePath {
  final List<int> pathHashes;
  final int hopCount;
  final double stabilityScore;

  RoutePath({
    required this.pathHashes,
    required this.hopCount,
    required this.stabilityScore,
  });
}

class Edge {
  final int from;
  final int to;
  int successCount;
  int totalAttempts;
  DateTime lastHeard;
  double? snr;

  Edge({
    required this.from,
    required this.to,
    this.successCount = 1,
    this.totalAttempts = 1,
    required this.lastHeard,
    this.snr,
  });

  double get reliability => (successCount + 1) / (totalAttempts + 2);
}

class TopologyNode {
  final int hash;
  final String name;
  final int type;
  final bool isMe;

  TopologyNode({
    required this.hash,
    required this.name,
    required this.type,
    this.isMe = false,
  });
}

class TopologyService extends ChangeNotifier {
  final PathHistoryService _pathHistoryService;
  final Map<int, Map<int, Edge>> _graph = {};
  final Map<int, TopologyNode> _nodes = {};

  TopologyService(this._pathHistoryService) {
    _pathHistoryService.addListener(_onPathHistoryUpdated);
  }

  @override
  void dispose() {
    _pathHistoryService.removeListener(_onPathHistoryUpdated);
    super.dispose();
  }

  void _onPathHistoryUpdated() {
    notifyListeners();
  }

  /// Builds the graph from the current PathHistoryService knowledge.
  void buildGraph(List<Contact> allContacts, String myPubKeyHex) {
    _graph.clear();
    _nodes.clear();

    // 1. Add "Me" node
    int myHash = 0;
    if (myPubKeyHex.isNotEmpty) {
      final myBytes = hex2Uint8List(myPubKeyHex);
      if (myBytes.isNotEmpty) {
        myHash = myBytes[0];
        _nodes[myHash] = TopologyNode(
          hash: myHash,
          name: "Me",
          type: advTypeChat,
          isMe: true,
        );
      }
    }

    // 2. Add all contacts as nodes
    for (var contact in allContacts) {
    final paths = _pathHistoryService.getRecentPaths(contact.publicKeyHex);
    if (paths.isEmpty) continue;

    final contactHash = contact.publicKey.isNotEmpty ? contact.publicKey.first : 0;

    for (var path in paths) {
      // RÈGLE : Ignorer les chemins incomplets (hopCount > 1 mais pas de pathBytes)
      if (path.hopCount > 1 && path.pathBytes.isEmpty) {
        continue; 
      }

      if (path.isOutbound) {
        // Me -> Relais -> Contact
        int prev = myHash;
        for (var relay in path.pathBytes) {
          _addEdge(prev, relay, path.successCount, path.failureCount, path.timestamp ?? DateTime.now());
          prev = relay;
        }
        _addEdge(prev, contactHash, path.successCount, path.failureCount, path.timestamp ?? DateTime.now());
      } else {
        // Contact -> Relais -> Me
        int prev = contactHash;
        for (var relay in path.pathBytes) {
          _addEdge(prev, relay, path.successCount, path.failureCount, path.timestamp ?? DateTime.now());
          prev = relay;
        }
        _addEdge(prev, myHash, path.successCount, path.failureCount, path.timestamp ?? DateTime.now());
      }
    }
  }
  notifyListeners();
}
  void clearGraph() {
    _graph.clear();
    _nodes.clear();
    notifyListeners();
  }

  void addGraphFromApi(Map<String, dynamic> apiData) {
    final nodeData = apiData['node'];
    if (nodeData == null) {
      notifyListeners();
      return;
    }

    final centralPubKey = nodeData['public_key'] as String;
    final centralHash = _getHashFromHex(centralPubKey);
    final centralName = nodeData['name'] as String? ?? "Central Node";
    
    _nodes[centralHash] = TopologyNode(
      hash: centralHash,
      name: centralName,
      type: advTypeRepeater, 
      isMe: false,
    );

    final recentAdverts = apiData['recentAdverts'] as List<dynamic>? ?? [];

    for (var advert in recentAdverts) {
      final observations = advert['observations'] as List<dynamic>? ?? [];
      for (var obs in observations) {
        final observerIdHex = obs['observer_id'] as String? ?? "";
        final observerName = obs['observer_name'] as String? ?? "Unknown Gateway";
        final observerHash = _getHashFromHex(observerIdHex);
        
        if (observerIdHex.isNotEmpty) {
           _nodes[observerHash] = TopologyNode(
             hash: observerHash,
             name: observerName,
             type: advTypeRepeater, 
             isMe: false,
           );
        }

        final pathJsonStr = obs['path_json'] as String? ?? "[]";
        List<dynamic> pathHashesStrs = [];
        try {
          pathHashesStrs = jsonDecode(pathJsonStr);
        } catch (_) {}

        final pathHashes = pathHashesStrs.map((s) => _getHashFromHex(s.toString())).toList();
        final snr = (obs['snr'] as num?)?.toDouble();
        final timestampStr = obs['timestamp'] as String?;
        final timestamp = timestampStr != null ? DateTime.tryParse(timestampStr) ?? DateTime.now() : DateTime.now();

        int prev = centralHash;
        for (var relayHash in pathHashes) {
           if (!_nodes.containsKey(relayHash)) {
              _nodes[relayHash] = TopologyNode(
                 hash: relayHash,
                 name: "Relay ${relayHash.toRadixString(16).padLeft(2, '0').toUpperCase()}",
                 type: advTypeRepeater,
              );
           }
           _addEdge(prev, relayHash, 1, 0, timestamp, snr: null);
           _addEdge(relayHash, prev, 1, 0, timestamp, snr: null);
           prev = relayHash;
        }

        if (observerHash != 0) {
           _addEdge(prev, observerHash, 1, 0, timestamp, snr: snr);
           _addEdge(observerHash, prev, 1, 0, timestamp, snr: snr);
        }
      }
    }
    notifyListeners();
  }

  int _getHashFromHex(String hexStr) {
    if (hexStr.isEmpty) return 0;
    final str = hexStr.length >= 2 ? hexStr.substring(0, 2) : hexStr;
    return int.tryParse(str, radix: 16) ?? 0;
  }

  void _addEdge(
      int from, int to, int successes, int failures, DateTime timestamp, {double? snr}) {
    if (from == to) return;

    _graph.putIfAbsent(from, () => {});

    if (_graph[from]!.containsKey(to)) {
      final edge = _graph[from]![to]!;
      edge.successCount += successes;
      edge.totalAttempts += (successes + failures);
      if (snr != null) edge.snr = snr;
      if (timestamp.isAfter(edge.lastHeard)) {
        edge.lastHeard = timestamp;
      }
    } else {
      _graph[from]![to] = Edge(
        from: from,
        to: to,
        successCount: max(1, successes),
        totalAttempts: max(1, successes + failures),
        lastHeard: timestamp,
        snr: snr,
      );
    }
  }

  void updateEdgeSnr(int from, int to, double snr) {
    _addEdge(from, to, 1, 0, DateTime.now(), snr: snr);
    notifyListeners();
  }

  void applyDecay() {
    final now = DateTime.now();
    bool changed = false;
    final toRemove = <int, List<int>>{};

    for (var fromEntry in _graph.entries) {
      final fromHash = fromEntry.key;
      for (var toEntry in fromEntry.value.entries) {
        final toHash = toEntry.key;
        final edge = toEntry.value;
        final age = now.difference(edge.lastHeard);

        if (age.inHours > 24) {
          // Decay by reducing success ratio
          edge.successCount = (edge.successCount * 0.7).round();
          changed = true;
        } else if (age.inHours > 6) {
          edge.successCount = (edge.successCount * 0.95).round();
          changed = true;
        }

        if (edge.reliability < 0.1 && age.inDays > 2) {
          toRemove.putIfAbsent(fromHash, () => []).add(toHash);
        }
      }
    }

    toRemove.forEach((from, tos) {
      for (var to in tos) {
        _graph[from]?.remove(to);
        changed = true;
      }
      if (_graph[from]?.isEmpty ?? false) _graph.remove(from);
    });

    if (changed) notifyListeners();
  }

  /// Returns all paths from `fromHash` to `toHash` up to `maxHops`, sorted by hop count.
  List<RoutePath> findPaths(int fromHash, int toHash,
      {int maxHops = 7, bool onlyRepeaters = true}) {
    List<RoutePath> results = [];
    List<int> currentPath = [fromHash];
    Set<int> visited = {fromHash};

    void dfs(int current, int depth) {
      if (current == toHash) {
        double stability = _calculateStabilityScore(currentPath);
        results.add(RoutePath(
          pathHashes: List.from(currentPath),
          hopCount: currentPath.length - 1,
          stabilityScore: stability,
        ));
        return;
      }

      if (depth >= maxHops) return;

      final neighbors = _graph[current]?.values.toList() ?? [];

      for (var edge in neighbors) {
        if (!visited.contains(edge.to)) {
          // If onlyRepeaters is true, intermediate nodes must be repeaters
          if (onlyRepeaters && edge.to != toHash) {
            final node = _nodes[edge.to];
            if (node != null) {
              final isRepeater =
                  node.type == advTypeRepeater || node.type == advTypeRoom;
              if (!isRepeater) continue;
            } else {
              continue;
            }
          }

          visited.add(edge.to);
          currentPath.add(edge.to);

          dfs(edge.to, depth + 1);

          currentPath.removeLast();
          visited.remove(edge.to);
        }
      }
    }

    dfs(fromHash, 0);

    // Sort by hop count ascending, then stability descending
    results.sort((a, b) {
      int hopDiff = a.hopCount.compareTo(b.hopCount);
      if (hopDiff != 0) return hopDiff;
      return b.stabilityScore.compareTo(a.stabilityScore);
    });

    // Limit to 3 paths maximum per hop count to avoid UI clutter
    final Map<int, int> hopCountFreq = {};
    final List<RoutePath> filteredResults = [];
    for (var path in results) {
      final count = hopCountFreq[path.hopCount] ?? 0;
      if (count < 3) {
        filteredResults.add(path);
        hopCountFreq[path.hopCount] = count + 1;
      }
    }

    return filteredResults;
  }

  double _calculateStabilityScore(List<int> path) {
    if (path.length < 2) return 1.0;

    double totalReliability = 1.0;
    double minFreshness = 1.0;

    for (int i = 0; i < path.length - 1; i++) {
      int from = path[i];
      int to = path[i + 1];

      Edge? edge = _graph[from]?[to];
      if (edge != null) {
        totalReliability *= edge.reliability;

        // Freshness: 1.0 if very recent, fades over days
        double freshness = 1.0 /
            (1.0 +
                (DateTime.now().difference(edge.lastHeard).inMinutes /
                    60.0 /
                    24.0));
        if (freshness < minFreshness) {
          minFreshness = freshness;
        }
      }
    }

    // stability is a function of overall reliability, shortest link freshness, and inverse of hop count.
    return (totalReliability * 0.5) +
        (minFreshness * 0.3) +
        ((1.0 / path.length) * 0.2);
  }

  // Expose graph and nodes for topology view map
  Map<int, Map<int, Edge>> get graph => _graph;
  Map<int, TopologyNode> get nodes => _nodes;
  
  List<Edge> getAllEdges() {
     List<Edge> edges = [];
     for (var fromNode in _graph.values) {
       edges.addAll(fromNode.values);
     }
     return edges;
  }
}
