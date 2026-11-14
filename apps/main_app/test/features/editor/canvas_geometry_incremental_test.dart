// Геометрия связей при перетаскивании.
//
// Раньше любой `copyWith(nodes: ...)` пересчитывал все рёбра квеста и
// пересоздавал объекты `ConnectionGeometry`. Две беды: на 1200 нодах и 3600
// рёбрах кадр перетаскивания стоил ~11 мс, а кеш пунктира в художнике
// (ключ — сам объект геометрии) промахивался каждый кадр, потому что
// геометрия каждый раз была новая.
//
// Теперь пересчитываются только рёбра, касающиеся сдвинутых нод, а смещения
// дорожек (они зависят от состава связей, а не от позиций) переезжают в
// следующее состояние без пересчёта.
//
// Негативный контроль: без инкрементального пересчёта тест «незатронутое
// ребро остаётся тем же объектом» падает, а «совпадает с полным пересчётом»
// остаётся зелёным — он ловит ошибку в самом инкременте.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:canvas_app/models/canvas_models.dart';
import 'package:canvas_app/features/editor/providers/canvas_provider.dart';

List<Node> makeNodes(int count) => [
  for (var i = 0; i < count; i++)
    Node(
      id: 'n$i',
      position: Offset(100 + (i % 10) * 220.0, 100 + (i ~/ 10) * 220.0),
      color: const Color(0xFF26C6DA),
      label: 'Нода $i',
      description: 'описание $i',
    ),
];

List<Connection> makeConnections(List<Node> nodes) => [
  for (var i = 0; i < nodes.length; i++)
    Connection(
      id: 'e$i',
      fromNode: nodes[i],
      toNode: nodes[(i * 3 + 1) % nodes.length],
      kind: ConnectionKind.values[i % ConnectionKind.values.length],
    ),
];

/// Связи, как их пересобирает перетаскивание: те же id, ссылки на новые ноды.
List<Connection> rewire(List<Connection> old, List<Node> nodes) {
  final byId = {for (final n in nodes) n.id: n};
  return [
    for (final c in old)
      Connection(
        id: c.id,
        fromNode: byId[c.fromNode.id]!,
        toNode: byId[c.toNode.id]!,
        kind: c.kind,
      ),
  ];
}

CanvasState initialState() {
  final nodes = makeNodes(60);
  final connections = makeConnections(nodes);
  final state = CanvasState(
    nodes: nodes,
    spatialHash: SpatialHash()..rebuild(nodes),
  );
  return state.copyWith(nodes: nodes, connections: connections);
}

/// Полный пересчёт: состояние без предыдущей геометрии.
Map<String, ConnectionGeometry> fullGeometry(
  List<Node> nodes,
  List<Connection> connections,
) {
  final fresh = CanvasState(
    nodes: nodes,
    spatialHash: SpatialHash()..rebuild(nodes),
  );
  return fresh
      .copyWith(nodes: nodes, connections: connections)
      .connectionGeometries;
}

List<Node> moveNode(List<Node> nodes, String id, Offset delta) => [
  for (final n in nodes)
    n.id == id ? n.copyWith(position: n.position + delta) : n,
];

void expectSameGeometry(
  Map<String, ConnectionGeometry> actual,
  Map<String, ConnectionGeometry> expected,
) {
  expect(actual.keys.toSet(), expected.keys.toSet());
  for (final id in expected.keys) {
    final a = actual[id]!;
    final e = expected[id]!;
    expect(a.start, e.start, reason: 'start $id');
    expect(a.end, e.end, reason: 'end $id');
    expect(a.cp1, e.cp1, reason: 'cp1 $id');
    expect(a.cp2, e.cp2, reason: 'cp2 $id');
    expect(a.bounds, e.bounds, reason: 'bounds $id');
    expect(a.lane, e.lane, reason: 'lane $id');
  }
}

void main() {
  group('инкрементальная геометрия', () {
    test('совпадает с полным пересчётом после сдвига', () {
      final start = initialState();
      final nodes = moveNode(start.nodes, 'n7', const Offset(37, -12));
      final connections = rewire(start.connections, nodes);
      final moved = start.copyWith(nodes: nodes, connections: connections);

      expectSameGeometry(
        moved.connectionGeometries,
        fullGeometry(nodes, connections),
      );
    });

    test('совпадает с полным пересчётом после серии сдвигов', () {
      var state = initialState();
      const moves = [Offset(10, 0), Offset(0, 14), Offset(-6, -9), Offset(3, 3)];
      for (final delta in moves) {
        final nodes = moveNode(state.nodes, 'n3', delta);
        state = state.copyWith(
          nodes: nodes,
          connections: rewire(state.connections, nodes),
        );
      }

      expectSameGeometry(
        state.connectionGeometries,
        fullGeometry(state.nodes, state.connections),
      );
    });

    test('незатронутые рёбра остаются теми же объектами', () {
      final start = initialState();
      final before = start.connectionGeometries;
      final n7 = start.nodes.firstWhere((n) => n.id == 'n7');
      final touched = {
        for (final c in start.connections)
          if (c.fromNode.id == n7.id || c.toNode.id == n7.id) c.id,
      };
      expect(touched, isNotEmpty);

      final nodes = moveNode(start.nodes, 'n7', const Offset(25, 25));
      final moved = start.copyWith(
        nodes: nodes,
        connections: rewire(start.connections, nodes),
      );

      final untouched = before.keys.where((id) => !touched.contains(id));
      expect(untouched, isNotEmpty);
      for (final id in untouched) {
        expect(
          identical(moved.connectionGeometries[id], before[id]),
          isTrue,
          reason: 'ребро $id не касается сдвинутой ноды — его геометрия '
              'должна переиспользоваться, иначе кеш пунктира промахивается',
        );
      }
    });

    test('добавленная связь считается полностью', () {
      final start = initialState();
      final extra = Connection(
        id: 'e-new',
        fromNode: start.nodes[5],
        toNode: start.nodes[9],
      );
      final withExtra = start.copyWith(
        connections: [...start.connections, extra],
      );

      expect(withExtra.connectionGeometries['e-new'], isNotNull);
      expectSameGeometry(
        withExtra.connectionGeometries,
        fullGeometry(start.nodes, withExtra.connections),
      );
    });

    test('удаление ноды выкидывает её рёбра из геометрии', () {
      final start = initialState();
      final nodes = [
        for (final n in start.nodes)
          if (n.id != 'n4') n,
      ];
      final byId = {for (final n in nodes) n.id: n};
      final connections = [
        for (final c in start.connections)
          if (byId.containsKey(c.fromNode.id) && byId.containsKey(c.toNode.id))
            Connection(
              id: c.id,
              fromNode: byId[c.fromNode.id]!,
              toNode: byId[c.toNode.id]!,
              kind: c.kind,
            ),
      ];
      final pruned = start.copyWith(nodes: nodes, connections: connections);

      expectSameGeometry(
        pruned.connectionGeometries,
        fullGeometry(nodes, connections),
      );
    });
  });

  group('пересборка рёбер при перетаскивании', () {
    test('обновляет только рёбра сдвинутой ноды', () {
      final nodes = makeNodes(10);
      final connections = makeConnections(nodes);
      final moved = moveNode(nodes, 'n4', const Offset(40, 0));
      final rewired = rewireConnections(connections, moved, {'n4'});

      expect(rewired, hasLength(connections.length));
      for (var i = 0; i < connections.length; i++) {
        final before = connections[i];
        final after = rewired[i];
        expect(after.id, before.id);
        final touched =
            before.fromNode.id == 'n4' || before.toNode.id == 'n4';
        expect(
          identical(after, before),
          !touched,
          reason: 'ребро ${before.id}: пересобираем только то, что двигалось',
        );
        if (touched) {
          expect(
            identical(after.fromNode, moved.firstWhere((n) => n.id == after.fromNode.id)),
            isTrue,
            reason: 'у пересобранного ребра должны быть свежие ссылки на ноды',
          );
        }
      }
    });

    test('висячее ребро уходит', () {
      final nodes = makeNodes(5);
      final connections = makeConnections(nodes);
      final pruned = nodes.where((n) => n.id != 'n2').toList();
      final rewired = rewireConnections(connections, pruned, {'n2'});

      expect(
        rewired.any((c) => c.fromNode.id == 'n2' || c.toNode.id == 'n2'),
        isFalse,
      );
    });
  });

  group('SpatialHash', () {
    test('запрос по прямоугольнику отдаёт только пересекающиеся ноды', () {
      final nodes = makeNodes(20);
      final hash = SpatialHash()..rebuild(nodes);

      final hit = hash.query(nodes[6].rect.inflate(4));
      expect(hit, contains(nodes[6]));
      expect(
        hit.length,
        1,
        reason: 'соседние ячейки не должны протаскивать чужие ноды',
      );
    });

    test('обзорный запрос накрывает всё', () {
      final nodes = makeNodes(20);
      final hash = SpatialHash()..rebuild(nodes);
      expect(hash.query(const Rect.fromLTRB(-1e4, -1e4, 1e4, 1e4)), hasLength(20));
    });

    test('точка находит ноду под ней', () {
      final nodes = makeNodes(9);
      final hash = SpatialHash()..rebuild(nodes);
      expect(hash.queryPoint(nodes[4].position), nodes[4]);
      expect(hash.queryPoint(const Offset(-5000, -5000)), isNull);
    });
  });
}