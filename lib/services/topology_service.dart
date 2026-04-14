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
      if (contact.publicKey.isEmpty) continue;
      final hash = contact.publicKey[0];
      
      // If we already have a node (e.g. Me), don't overwrite if it's Me
      if (_nodes.containsKey(hash) && _nodes[hash]!.isMe) continue;

      _nodes[hash] = TopologyNode(
        hash: hash,
        name: contact.name,
        type: contact.type,
      );
    }

    // 3. Build edges from path history
    for (var contact in allContacts) {
      final paths = _pathHistoryService.getRecentPaths(contact.publicKeyHex);
      if (paths.isEmpty) continue;

      final contactHash = contact.publicKey.isNotEmpty ? contact.publicKey.first : 0;

      for (var path in paths) {
        if (path.pathBytes.isEmpty) {
          // Direct connection to Me (if path is empty, it's 1 hop to Me)
          _addEdge(contactHash, myHash, path.successCount, path.failureCount,
              path.timestamp ?? DateTime.now());
          _addEdge(myHash, contactHash, path.successCount, path.failureCount,
              path.timestamp ?? DateTime.now());
          continue;
        }

        // The structure is Contact -> Relay1 -> Relay2 -> Me.
        int prevHash = contactHash;
        for (int i = 0; i < path.pathBytes.length; i++) {
          int currentHash = path.pathBytes[i];
          _addEdge(prevHash, currentHash, path.successCount, path.failureCount,
              path.timestamp ?? DateTime.now());
          _addEdge(currentHash, prevHash, path.successCount, path.failureCount,
              path.timestamp ?? DateTime.now()); // Bidirectional
          prevHash = currentHash;
        }
        // Link last relay to Me
        _addEdge(prevHash, myHash, path.successCount, path.failureCount,
            path.timestamp ?? DateTime.now());
        _addEdge(myHash, prevHash, path.successCount, path.failureCount,
            path.timestamp ?? DateTime.now()); // Bidirectional
      }
    }
    notifyListeners();
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

    return results;
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
