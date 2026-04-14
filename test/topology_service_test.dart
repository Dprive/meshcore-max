import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/services/topology_service.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('TopologyService', () {
    late StorageService mockStorage;
    late PathHistoryService pathHistory;
    late TopologyService topology;

    setUp(() {
      mockStorage = StorageService();
      pathHistory = PathHistoryService(mockStorage);
      pathHistory.setTestMode(true);
      topology = TopologyService(pathHistory);
    });

    test('findPaths filters non-repeaters when onlyRepeaters is true', () async {
      final myPubKeyHex = "00112233";
      
      // Node Hashes: Me (0x00), R1 (0xBB, Repeater), C1 (0xCC, Companion), Dest (0xDD, Chat)
      final r1 = Contact(
        publicKey: Uint8List.fromList([0xBB]),
        name: 'Repeater 1',
        type: advTypeRepeater,
        path: Uint8List(0),
        pathLength: 0,
        lastSeen: DateTime.now(),
      );
      final c1 = Contact(
        publicKey: Uint8List.fromList([0xCC]),
        name: 'Companion 1',
        type: advTypeChat,
        path: Uint8List(0),
        pathLength: 0,
        lastSeen: DateTime.now(),
      );
      final dest = Contact(
        publicKey: Uint8List.fromList([0xDD]),
        name: 'Destination',
        type: advTypeChat,
        path: Uint8List(0),
        pathLength: 0,
        lastSeen: DateTime.now(),
      );

      // Path 1: Me <-> R1 <-> Dest
      pathHistory.recordFloodPathAttribution(
        contactPubKeyHex: r1.publicKeyHex,
        pathBytes: [],
        hopCount: 1,
      );
      pathHistory.recordFloodPathAttribution(
        contactPubKeyHex: dest.publicKeyHex,
        pathBytes: [0xBB],
        hopCount: 2,
      );
      
      // Path 2: Me <-> C1 <-> Dest
      pathHistory.recordFloodPathAttribution(
        contactPubKeyHex: c1.publicKeyHex,
        pathBytes: [],
        hopCount: 1,
      );
      pathHistory.recordFloodPathAttribution(
        contactPubKeyHex: dest.publicKeyHex,
        pathBytes: [0xCC],
        hopCount: 2,
      );

      // Wait for async history processing
      await Future.delayed(const Duration(milliseconds: 100));

      topology.buildGraph([r1, c1, dest], myPubKeyHex);

      // 1. With onlyRepeaters = true (default)
      final pathsFiltered = topology.findPaths(0x00, 0xDD);
      expect(pathsFiltered.length, 1);
      expect(pathsFiltered.first.pathHashes, [0x00, 0xBB, 0xDD]);

      // 2. With onlyRepeaters = false
      final pathsAll = topology.findPaths(0x00, 0xDD, onlyRepeaters: false);
      expect(pathsAll.length, 2);
    });

    // We can test _calculateStabilityScore logic via finding paths on a manually constructed graph if possible.
  });
}
