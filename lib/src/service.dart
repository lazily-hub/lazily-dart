/// Embedded-service plane (`#lzservice`) — the Dart port.
///
/// See `lazily-spec/docs/service.md` and the formal model
/// `lazily-formal/LazilyFormal/Service.lean`. The story for "an instance is also
/// a host of services": [HealthCell] / [ReadinessCell] / [DiscoveryCell] /
/// [ServiceRegistry], each a pure compute **core** (an aggregation / keyed map)
/// split from a thin reactive **cell** projecting the composed view onto a
/// [Context] cell so dependents invalidate *only when the projection actually
/// changes* (the backend-portability rule).
///
/// The map-valued projections ([DiscoveryCell], [ServiceRegistry]) go through
/// [EndpointMap], a value-equal `service -> endpoint` snapshot: an unchanged
/// registry projects an *equal* value so the cell's `!=` guard suppresses the
/// cascade, while a real add/remove/rebind projects an unequal value that
/// invalidates the reader.
library;

import 'core.dart';

// ---------------------------------------------------------------------------
// Value-equal endpoint projection
// ---------------------------------------------------------------------------

/// An immutable, canonically-ordered `service -> endpoint` snapshot with value
/// equality. Projecting this onto a [Cell] makes the cell's `!=` guard fire
/// exactly when the mapping changes — an equal projection (e.g. a `replay` that
/// rebuilds the same table) is suppressed.
class EndpointMap {
  EndpointMap(Map<String, String> entries)
      : entries = Map<String, String>.unmodifiable(_sorted(entries));

  /// The `service -> endpoint` map, key-sorted.
  final Map<String, String> entries;

  static Map<String, String> _sorted(Map<String, String> entries) {
    final keys = entries.keys.toList()..sort();
    return {for (final k in keys) k: entries[k] as String};
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! EndpointMap) return false;
    if (entries.length != other.entries.length) return false;
    for (final e in entries.entries) {
      if (other.entries[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var h = 0;
    for (final e in entries.entries) {
      h ^= Object.hash(e.key, e.value);
    }
    return h;
  }

  @override
  String toString() => 'EndpointMap($entries)';
}

// ---------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------

/// Composed health status (worst component dominates).
enum Health { healthy, degraded, unhealthy }

/// Composed liveness-probe core. Each probe reports `up` and whether it is
/// `critical`.
class HealthCore {
  final Map<String, ({bool up, bool critical})> _probes = {};

  /// Set/refresh a probe.
  void set(String name, bool up, bool critical) {
    _probes[name] = (up: up, critical: critical);
  }

  /// The aggregate: [Health.unhealthy] if any critical probe is down, else
  /// [Health.degraded] if any is down, else [Health.healthy].
  Health health() {
    var anyDown = false;
    for (final p in _probes.values) {
      if (!p.up && p.critical) return Health.unhealthy;
      if (!p.up) anyDown = true;
    }
    return anyDown ? Health.degraded : Health.healthy;
  }
}

/// Reactive health: projects the aggregate onto a cell for `/health`.
class HealthCell {
  HealthCell(this.ctx)
      : core = HealthCore(),
        healthCell = Source<Health>(ctx, Health.healthy);

  final Context ctx;
  final HealthCore core;
  final Source<Health> healthCell;

  void _refresh() => healthCell.value = core.health();

  void set(String name, bool up, bool critical) {
    core.set(name, up, critical);
    _refresh();
  }

  Health health() => core.health();
}

// ---------------------------------------------------------------------------
// Readiness
// ---------------------------------------------------------------------------

/// Composed readiness-probe core: ready iff every condition holds.
class ReadinessCore {
  final Map<String, bool> _conditions = {};

  void set(String name, bool ready) {
    _conditions[name] = ready;
  }

  bool ready() {
    for (final r in _conditions.values) {
      if (!r) return false;
    }
    return true;
  }
}

/// Reactive readiness: projects `ready` onto a cell for `/ready`.
class ReadinessCell {
  ReadinessCell(this.ctx)
      : core = ReadinessCore(),
        readyCell = Source<bool>(ctx, true);

  final Context ctx;
  final ReadinessCore core;
  final Source<bool> readyCell;

  void _refresh() => readyCell.value = core.ready();

  void set(String name, bool ready) {
    core.set(name, ready);
    _refresh();
  }

  bool ready() => core.ready();
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

/// Service-discovery core: `service -> (endpoint, peer)`. A peer's departure
/// ([evict]) removes its endpoints.
class DiscoveryCore<P> {
  final Map<String, ({String endpoint, P peer})> _entries = {};

  void register(String service, String endpoint, P peer) {
    _entries[service] = (endpoint: endpoint, peer: peer);
  }

  void deregister(String service) => _entries.remove(service);

  /// Remove all endpoints owned by [peer] (membership loss).
  void evict(P peer) => _entries.removeWhere((_, e) => e.peer == peer);

  String? resolve(String service) => _entries[service]?.endpoint;

  /// The live `service -> endpoint` map (key-sorted).
  Map<String, String> discovery() {
    final keys = _entries.keys.toList()..sort();
    return {for (final k in keys) k: _entries[k]!.endpoint};
  }
}

/// Reactive service discovery: projects the live map through an [EndpointMap]
/// so the reader invalidates only on an actual change.
class DiscoveryCell<P> {
  DiscoveryCell(this.ctx)
      : core = DiscoveryCore<P>(),
        discoveryCell = Source<EndpointMap>(ctx, EndpointMap(const {}));

  final Context ctx;
  final DiscoveryCore<P> core;
  final Source<EndpointMap> discoveryCell;

  void _refresh() => discoveryCell.value = EndpointMap(core.discovery());

  void register(String service, String endpoint, P peer) {
    core.register(service, endpoint, peer);
    _refresh();
  }

  void deregister(String service) {
    core.deregister(service);
    _refresh();
  }

  void evict(P peer) {
    core.evict(peer);
    _refresh();
  }

  String? resolve(String service) => core.resolve(service);

  Map<String, String> discovery() => discoveryCell.value.entries;
}

// ---------------------------------------------------------------------------
// Service registry (durable)
// ---------------------------------------------------------------------------

/// A durable registry op (the ordered log entry).
class RegistryOp {
  const RegistryOp.register(this.service, String this.endpoint)
      : isRegister = true;
  const RegistryOp.deregister(this.service)
      : endpoint = null,
        isRegister = false;

  final bool isRegister;
  final String service;
  final String? endpoint;
}

/// Durable service-registry core: an ordered log (the `DurableOutbox` pattern)
/// whose left-fold is the projection, so replay reconstructs it.
class ServiceRegistryCore {
  final List<RegistryOp> _log = [];
  Map<String, String> _projection = {};

  static void _apply(Map<String, String> projection, RegistryOp op) {
    if (op.isRegister) {
      projection[op.service] = op.endpoint!;
    } else {
      projection.remove(op.service);
    }
  }

  void register(String service, String endpoint) {
    final op = RegistryOp.register(service, endpoint);
    _apply(_projection, op);
    _log.add(op);
  }

  void deregister(String service) {
    final op = RegistryOp.deregister(service);
    _apply(_projection, op);
    _log.add(op);
  }

  /// Rebuild the projection from the durable log (restart / crash-replay).
  void replay() {
    final projection = <String, String>{};
    for (final op in _log) {
      _apply(projection, op);
    }
    _projection = projection;
  }

  /// The projection (key-sorted).
  Map<String, String> projection() {
    final keys = _projection.keys.toList()..sort();
    return {for (final k in keys) k: _projection[k]!};
  }

  List<RegistryOp> get log => List.unmodifiable(_log);
}

/// Reactive durable service registry.
class ServiceRegistry {
  ServiceRegistry(this.ctx)
      : core = ServiceRegistryCore(),
        projectionCell = Source<EndpointMap>(ctx, EndpointMap(const {}));

  final Context ctx;
  final ServiceRegistryCore core;
  final Source<EndpointMap> projectionCell;

  void _refresh() => projectionCell.value = EndpointMap(core.projection());

  void register(String service, String endpoint) {
    core.register(service, endpoint);
    _refresh();
  }

  void deregister(String service) {
    core.deregister(service);
    _refresh();
  }

  void replay() {
    core.replay();
    _refresh();
  }

  Map<String, String> projection() => projectionCell.value.entries;
}
