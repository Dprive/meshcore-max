import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/topology_service.dart';
import '../connector/meshcore_protocol.dart';

class PhysicsNode {
  final int hash;
  final String name;
  final int type;
  final bool isMe;
  double x = 0;
  double y = 0;
  double vx = 0;
  double vy = 0;

  PhysicsNode({
    required this.hash,
    required this.name,
    required this.type,
    this.isMe = false,
  });
}

class PhysicsEdge {
  final PhysicsNode fromNode;
  final PhysicsNode toNode;
  final double reliability;
  final Edge originalEdge;

  PhysicsEdge({
    required this.fromNode,
    required this.toNode,
    required this.reliability,
    required this.originalEdge,
  });
}

class InteractivePhysicsGraph extends StatefulWidget {
  final List<Edge> edges;
  final Map<int, TopologyNode> nodes;
  final double minReliability;
  final bool showOnlyRepeaters;
  final Function(TopologyNode)? onNodeTap;
  final Function(Edge)? onEdgeTap;

  const InteractivePhysicsGraph({
    super.key,
    required this.edges,
    required this.nodes,
    this.minReliability = 0.0,
    this.showOnlyRepeaters = false,
    this.onNodeTap,
    this.onEdgeTap,
  });

  @override
  State<InteractivePhysicsGraph> createState() => _InteractivePhysicsGraphState();
}

class _InteractivePhysicsGraphState extends State<InteractivePhysicsGraph>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  final List<PhysicsNode> _nodes = [];
  final List<PhysicsEdge> _physicsEdges = [];
  final Map<int, PhysicsNode> _nodeMap = {};

  final math.Random _rand = math.Random();

  // Physics constraints
  static const double repulsionStrength = 85000.0;
  static const double baseSpringK = 0.02; 
  static const double gravity = 0.015;
  static const double damping = 0.65; 
  
  // Interaction
  PhysicsNode? _draggedNode;
  final TransformationController _transformationController = TransformationController();

  @override
  void initState() {
    super.initState();

    _initializeGraph();

    _ticker = createTicker(_tick);
    _ticker.start();
  }

  @override
  void didUpdateWidget(InteractivePhysicsGraph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.edges.length != oldWidget.edges.length || 
        widget.nodes.length != oldWidget.nodes.length ||
        widget.minReliability != oldWidget.minReliability ||
        widget.showOnlyRepeaters != oldWidget.showOnlyRepeaters) {
      _initializeGraph();
    }
  }

  void _initializeGraph() {
    // Preserve positions of existing nodes if possible
    final Map<int, Offset> oldPositions = {
      for (var node in _nodes) node.hash: Offset(node.x, node.y)
    };

    _nodes.clear();
    _physicsEdges.clear();
    _nodeMap.clear();

    PhysicsNode? getOrCreateNode(int hash) {
      if (!_nodeMap.containsKey(hash)) {
        final topologyNode = widget.nodes[hash];
        if (topologyNode == null) return null;

        // Apply node filter
        if (widget.showOnlyRepeaters && !topologyNode.isMe) {
          final isRepeater = topologyNode.type == advTypeRepeater || topologyNode.type == advTypeRoom;
          if (!isRepeater) return null;
        }

        final node = PhysicsNode(
          hash: hash,
          name: topologyNode.name,
          type: topologyNode.type,
          isMe: topologyNode.isMe,
        );
        
        if (node.isMe) {
          node.x = 0;
          node.y = 0;
        } else if (oldPositions.containsKey(hash)) {
          node.x = oldPositions[hash]!.dx;
          node.y = oldPositions[hash]!.dy;
        } else {
          // Random spawn location
          node.x = (_rand.nextDouble() - 0.5) * 600;
          node.y = (_rand.nextDouble() - 0.5) * 600;
        }
        _nodeMap[hash] = node;
        _nodes.add(node);
      }
      return _nodeMap[hash]!;
    }

    // Process nodes first if filtering is simple, but here edges define connections
    for (final hash in widget.nodes.keys) {
      getOrCreateNode(hash);
    }

    for (final e in widget.edges) {
      // Apply reliability filter
      if (e.reliability < widget.minReliability) continue;

      final from = getOrCreateNode(e.from);
      final to = getOrCreateNode(e.to);

      if (from != null && to != null) {
        _physicsEdges.add(
          PhysicsEdge(
            fromNode: from,
            toNode: to,
            reliability: e.reliability,
            originalEdge: e,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    if (!mounted) return;

    // 1. Repulsion (all nodes push each other)
    for (int i = 0; i < _nodes.length; i++) {
      for (int j = i + 1; j < _nodes.length; j++) {
        final n1 = _nodes[i];
        final n2 = _nodes[j];
        final dx = n1.x - n2.x;
        final dy = n1.y - n2.y;
        final distSq = dx * dx + dy * dy;

        if (distSq > 0.1 && distSq < 1000000) { // Optimize: skip extremely far nodes
          final dist = math.sqrt(distSq);
          final force = repulsionStrength / distSq;
          final fx = (dx / dist) * force;
          final fy = (dy / dist) * force;
          n1.vx += fx;
          n1.vy += fy;
          n2.vx -= fx;
          n2.vy -= fy;
        }
      }
    }

    // 2. Attraction (edges pull nodes together)
    for (final edge in _physicsEdges) {
      final dx = edge.toNode.x - edge.fromNode.x;
      final dy = edge.toNode.y - edge.fromNode.y;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist > 0.1) {
        // Stronger multiplier on Edge.reliability 
        final multiplier = math.max(0.1, edge.reliability * 2.5);
        final k = baseSpringK * multiplier;
        // High reliability -> ideal distance is shorter (~50px), low -> ~200px
        final idealDist = 200.0 - (edge.reliability * 150.0);
        
        final force = (dist - idealDist) * k;
        final fx = (dx / dist) * force;
        final fy = (dy / dist) * force;
        
        edge.fromNode.vx += fx;
        edge.fromNode.vy += fy;
        edge.toNode.vx -= fx;
        edge.toNode.vy -= fy;
      }
    }

    // 3. Center gravity and update pos/damping
    for (final node in _nodes) {
      if (node == _draggedNode || node.isMe) {
        node.vx = 0;
        node.vy = 0;
        if (node.isMe) {
          node.x = 0;
          node.y = 0;
        }
        continue;
      }

      node.vx -= node.x * gravity;
      node.vy -= node.y * gravity;
      
      // Cap the velocity to prevent wild explosion
      final speedSq = node.vx * node.vx + node.vy * node.vy;
      if (speedSq > 400) { // max speed of 20
        final speed = math.sqrt(speedSq);
        node.vx = (node.vx / speed) * 20;
        node.vy = (node.vy / speed) * 20;
      }
      
      node.x += node.vx;
      node.y += node.vy;
      // Kinetic friction
      node.vx *= damping;
      node.vy *= damping;
      
      // Stop completely if very slow (calm down)
      if (node.vx.abs() < 0.1) node.vx = 0;
      if (node.vy.abs() < 0.1) node.vy = 0;
    }

    // Trigger visual rebuild rapidly 
    setState(() {});
  }

  void _handleTap(Offset localPos, Matrix4 transform) {
    final Offset tapWorld = MatrixUtils.transformPoint(Matrix4.inverted(transform), localPos);

    for (int i = _nodes.length - 1; i >= 0; i--) {
      final node = _nodes[i];
      final nodePos = Offset(node.x, node.y);
      if ((tapWorld - nodePos).distance < 40) {
        final topologyNode = widget.nodes[node.hash];
        if (topologyNode != null && widget.onNodeTap != null) {
          widget.onNodeTap!(topologyNode);
        }
        return;
      }
    }

    for (final edge in _physicsEdges) {
      final p1 = Offset(edge.fromNode.x, edge.fromNode.y);
      final p2 = Offset(edge.toNode.x, edge.toNode.y);
      
      final double distance = _distanceToSegment(tapWorld, p1, p2);
      if (distance < 10) {
        if (widget.onEdgeTap != null) {
          widget.onEdgeTap!(edge.originalEdge);
        }
        return;
      }
    }
  }

  double _distanceToSegment(Offset p, Offset a, Offset b) {
    final double l2 = (a - b).distanceSquared;
    if (l2 == 0.0) return (p - a).distance;
    final double t = ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) / l2;
    if (t < 0.0) return (p - a).distance;
    if (t > 1.0) return (p - b).distance;
    final Offset projection = Offset(a.dx + t * (b.dx - a.dx), a.dy + t * (b.dy - a.dy));
    return (p - projection).distance;
  }

  @override
  Widget build(BuildContext context) {
    if (_nodes.isEmpty) {
      return const Center(child: Text("Empty Topology"));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final cw = constraints.maxWidth;
        final ch = constraints.maxHeight;
        final center = Offset(cw / 2, ch / 2);

        return Stack(
          children: [
            GestureDetector(
              onTapUp: (details) {
                final RenderBox box = context.findRenderObject() as RenderBox;
                final Offset localPos = box.globalToLocal(details.globalPosition);
                
                final transform = Matrix4.identity()
                  ..setTranslationRaw(cw / 2, ch / 2, 0)
                  ..multiply(_transformationController.value);
                  
                _handleTap(localPos, transform);
              },
              child: InteractiveViewer(
                transformationController: _transformationController,
                constrained: false,
                boundaryMargin: const EdgeInsets.all(2000),
                minScale: 0.1,
                maxScale: 5.0,
                child: SizedBox(
                  width: cw,
                  height: ch,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // Edges Layer
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _EdgePainter(
                            edges: _physicsEdges,
                            centerOffset: center,
                            primaryColor: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      // Nodes Layer
                      ..._nodes.map((n) {
                        return Positioned(
                          left: center.dx + n.x - 40,
                          top: center.dy + n.y - 40,
                          child: GestureDetector(
                            onPanStart: (details) {
                              _draggedNode = n;
                            },
                            onPanUpdate: (details) {
                              if (_draggedNode != null) {
                                setState(() {
                                  _draggedNode!.x += details.delta.dx / _transformationController.value.getMaxScaleOnAxis();
                                  _draggedNode!.y += details.delta.dy / _transformationController.value.getMaxScaleOnAxis();
                                });
                              }
                            },
                            onPanEnd: (_) => _draggedNode = null,
                            onPanCancel: () => _draggedNode = null,
                            child: _buildNodeWidget(context, n),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ),
            // Floating legend - always visible over the graph
            Positioned(
              bottom: 16,
              left: 16,
              child: _buildLegend(context),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLegend(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Légende', style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Nœuds', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 4),
          _legendRow(const Icon(Icons.router, size: 16, color: Colors.black87), 'Répéteur', context),
          _legendRow(const Icon(Icons.smartphone, size: 16, color: Colors.black87), 'Compagnon', context),
          const SizedBox(height: 8),
          Text('Liens SNR / Stabilité', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 4),
          _legendRow(_colorDot(Colors.greenAccent), 'Fiable  > 70%', context),
          _legendRow(_colorDot(Colors.orangeAccent), 'Moyen  35–70%', context),
          _legendRow(_colorDot(Colors.redAccent), 'Faible  < 35%', context),
          const SizedBox(height: 4),
          Text('Épaisseur = force du lien', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _legendRow(Widget icon, String label, BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  Widget _colorDot(Color color) {
    return Container(
      width: 16, height: 16,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _buildNodeWidget(BuildContext context, PhysicsNode node) {
    // Generate a pleasant color based on the hash, or a special one for "Me"
    Color nodeColor;
    if (node.isMe) {
      nodeColor = Theme.of(context).colorScheme.primaryContainer;
    } else {
      final hue = (node.hash * 137.5) % 360.0;
      nodeColor = HSLColor.fromAHSL(1.0, hue, 0.7, 0.8).toColor();
    }
    
    final isRepeater = node.type == advTypeRepeater || node.type == advTypeRoom;
    
    return Container(
      width: 80,
      height: 80,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: nodeColor,
        shape: BoxShape.circle,
        border: Border.all(
          color: node.isMe 
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
          width: node.isMe ? 3 : 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black26, 
            blurRadius: node.isMe ? 8 : 4, 
            offset: const Offset(2, 2)
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            node.isMe 
                ? Icons.person_pin 
                : (isRepeater ? Icons.router : Icons.smartphone), 
            size: 20, 
            color: Colors.black87
          ),
          const SizedBox(height: 2),
          Text(
             node.name, 
             style: TextStyle(
               fontSize: 9, 
               fontWeight: node.isMe ? FontWeight.w900 : FontWeight.bold, 
               color: Colors.black87
             ),
             textAlign: TextAlign.center,
             maxLines: 2,
             overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  final List<PhysicsEdge> edges;
  final Offset centerOffset;
  final Color primaryColor;

  _EdgePainter({
    required this.edges,
    required this.centerOffset,
    required this.primaryColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Group edges by node pairs to detect bidirectional links
    final Map<String, List<PhysicsEdge>> pairs = {};
    for (var e in edges) {
      final key = e.fromNode.hash < e.toNode.hash 
          ? "${e.fromNode.hash}-${e.toNode.hash}" 
          : "${e.toNode.hash}-${e.fromNode.hash}";
      pairs.putIfAbsent(key, () => []).add(e);
    }

    for (final edge in edges) {
      final p1 = Offset(centerOffset.dx + edge.fromNode.x, centerOffset.dy + edge.fromNode.y);
      final p2 = Offset(centerOffset.dx + edge.toNode.x, centerOffset.dy + edge.toNode.y);
      
      final key = edge.fromNode.hash < edge.toNode.hash 
          ? "${edge.fromNode.hash}-${edge.toNode.hash}" 
          : "${edge.toNode.hash}-${edge.fromNode.hash}";
      final isBidirectional = pairs[key]!.length > 1;

      // Base style from reliability or SNR
      double score = edge.reliability;
      if (edge.originalEdge.snr != null) {
        // Map SNR (-20 to 15) to 0..1 range roughly
        score = ((edge.originalEdge.snr! + 10) / 25).clamp(0.1, 1.0);
      }

      final opacity = math.max(0.3, score);
      final thickness = math.max(1.5, score * 5.5);
      
      Color edgeColor;
      if (score < 0.35) {
        edgeColor = Colors.redAccent;
      } else if (score < 0.7) {
        edgeColor = Colors.orangeAccent;
      } else {
        edgeColor = Colors.greenAccent;
      }
      
      final paint = Paint()
        ..color = edgeColor.withValues(alpha: opacity)
        ..strokeWidth = thickness
        ..style = PaintingStyle.stroke;

      if (isBidirectional) {
        // Draw curved line to avoid overlap
        final path = Path();
        path.moveTo(p1.dx, p1.dy);
        
        // Control point offset from the middle
        final mid = (p1 + p2) / 2;
        final v = p2 - p1;
        final unitNormal = Offset(-v.dy, v.dx) / v.distance;
        final curveOffset = unitNormal * 15; // Shift curve by 15px
        
        path.quadraticBezierTo(mid.dx + curveOffset.dx, mid.dy + curveOffset.dy, p2.dx, p2.dy);
        canvas.drawPath(path, paint);
        
        // Draw arrow at end of curve
        _drawArrowOnPath(canvas, p1, mid + curveOffset, p2, paint);
      } else {
        canvas.drawLine(p1, p2, paint);
        _drawArrow(canvas, p1, p2, paint);
      }
    }
  }

  void _drawArrow(Canvas canvas, Offset p1, Offset p2, Paint linePaint) {
    if ((p1 - p2).distance < 50) return; // Don't draw if too short

    final paint = Paint()
      ..color = linePaint.color
      ..style = PaintingStyle.fill;

    // Vector from p1 to p2
    final v = p2 - p1;
    final unitV = v / v.distance;
    
    // Position arrow some distance from dest node radius (Radius is ~40)
    final arrowPos = p2 - (unitV * 42); 
    
    _drawArrowHead(canvas, arrowPos, unitV, paint);
  }

  void _drawArrowOnPath(Canvas canvas, Offset start, Offset control, Offset end, Paint linePaint) {
    if ((start - end).distance < 50) return;

    final paint = Paint()
      ..color = linePaint.color
      ..style = PaintingStyle.fill;

    // Direction at end of quadratic bezier is tangent at T=1
    // Tangent = 2*(1-t)*(P1-P0) + 2*t*(P2-P1)
    // At t=1, Tangent = 2*(P2-P1) where P1 is control, P2 is end
    final v = end - control;
    final unitV = v / v.distance;
    final arrowPos = end - (unitV * 42);

    _drawArrowHead(canvas, arrowPos, unitV, paint);
  }

  void _drawArrowHead(Canvas canvas, Offset pos, Offset direction, Paint paint) {
    const double arrowSize = 10.0;
    final normal = Offset(-direction.dy, direction.dx);

    final path = Path();
    path.moveTo(pos.dx, pos.dy);
    path.lineTo(
      pos.dx - direction.dx * arrowSize + normal.dx * arrowSize * 0.6,
      pos.dy - direction.dy * arrowSize + normal.dy * arrowSize * 0.6,
    );
    path.lineTo(
      pos.dx - direction.dx * arrowSize - normal.dx * arrowSize * 0.6,
      pos.dy - direction.dy * arrowSize - normal.dy * arrowSize * 0.6,
    );
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) {
    return true; 
  }
}
