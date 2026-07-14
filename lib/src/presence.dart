/// Presence + ephemeral plane (`#lzpresence`) — the Dart port.
///
/// See `lazily-spec/docs/presence.md` and the formal model
/// `lazily-formal/LazilyFormal/Presence.lean`. The CRDT plane is durable;
/// collaborative apps also need an **ephemeral** plane that does not persist
/// (live cursors, typing indicators, presence). Each primitive is a pure compute
/// **core** (a keyed map / single value + TTL over a logical clock) split from a
/// thin reactive **cell** projecting the live view onto a [Cell] so dependents
/// invalidate *only on a live-view change* (the backend-portability rule).
///
/// The ephemeral plane is distinct from the durable plane: the [Ephemeral]
/// marker tags values that MUST NOT be persisted, and a durable sink is generic
/// over [Durable]. Each ephemeral primitive also carries a runtime [plane] tag
/// (`Plane.ephemeral`) so a dynamically-typed durable sink can reject it.
library;

import 'core.dart';

/// Plane tags for the ephemeral / durable split.
enum Plane { ephemeral, durable }

/// Marker: a value on the **ephemeral** plane. MUST NOT be persisted.
mixin Ephemeral {}

/// Marker: a value that may be written to the durable outbox.
mixin Durable {}

/// A newtype witnessing the [Ephemeral] marker (used by ephemeral payloads and
/// mirroring the Rust `EphemeralValue<T>` compile-fail guard).
class EphemeralValue<T> with Ephemeral {
  const EphemeralValue(this.value);

  final T value;
}

// ---------------------------------------------------------------------------
// Ephemeral single value
// ---------------------------------------------------------------------------

/// Single-value auto-expiry compute core — "the last value seen in window N".
///
/// [set] stamps `expiry = now + ttl`; [tick] clears the value once
/// `now >= expiry`; a [set] before expiry overwrites the pending value.
class EphemeralCore<T> with Ephemeral {
  T? _value;
  int _expiry = 0;

  /// The ephemeral plane tag.
  Plane get plane => Plane.ephemeral;

  /// Set the value, expiring at `now + ttl`.
  void set(T value, int now, int ttl) {
    _value = value;
    _expiry = now + ttl;
  }

  /// Clear the value once `now >= expiry`.
  void tick(int now) {
    if (_value != null && now >= _expiry) _value = null;
  }

  /// The live value, or `null` for "no value".
  T? value() => _value;
}

/// Reactive single-value ephemeral cell: projects the live value onto a [Cell]
/// so `value` invalidates only when the live value actually changes.
class EphemeralCell<T> with Ephemeral {
  EphemeralCell(this.ctx)
      : core = EphemeralCore<T>(),
        valueCell = Cell<T?>(ctx, null);

  final Context ctx;
  final EphemeralCore<T> core;
  final Cell<T?> valueCell;

  /// The ephemeral plane tag.
  Plane get plane => Plane.ephemeral;

  void _refresh() => valueCell.value = core.value();

  /// Set the value, expiring at `now + ttl`.
  void set(T value, int now, int ttl) {
    core.set(value, now, ttl);
    _refresh();
  }

  /// Advance the clock; clears the value once `now >= expiry`.
  void tick(int now) {
    core.tick(now);
    _refresh();
  }

  /// The live value, or `null` for "no value".
  T? value() => valueCell.value;
}

// ---------------------------------------------------------------------------
// Keyed per-peer ephemeral map (shared by presence + awareness)
// ---------------------------------------------------------------------------

/// An immutable snapshot of the live `key -> value` view with **value
/// equality**.
///
/// A plain Dart [Map] uses identity for `==`, so projecting a fresh map into a
/// [Cell] on every refresh would always trip the `!=` guard and over-invalidate.
/// [PresenceView] overrides `==`/`hashCode` on its contents so the projected
/// cell invalidates only when the live view genuinely changes.
class PresenceView<K, V> {
  const PresenceView(this.entries);

  /// The live entries, keys sorted ascending by the producing core.
  final Map<K, V> entries;

  @override
  bool operator ==(Object other) {
    if (other is! PresenceView<K, V>) return false;
    final a = entries;
    final b = other.entries;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var h = 0;
    for (final entry in entries.entries) {
      // Order-independent combine so equal contents hash equally.
      h ^= entry.key.hashCode ^ entry.value.hashCode;
    }
    return h;
  }

  @override
  String toString() => 'PresenceView($entries)';
}

/// Per-key ephemeral map with TTL eviction — the shared core behind presence and
/// awareness. Each entry carries an expiry; [tick] evicts lapsed entries.
class EphemeralMapCore<K extends Comparable<Object?>, V> with Ephemeral {
  final Map<K, (V value, int expiry)> _entries = {};

  /// The ephemeral plane tag.
  Plane get plane => Plane.ephemeral;

  /// Set/refresh `key`'s value (last-writer wins), expiring at `now + ttl`.
  void set(K key, V value, int now, int ttl) {
    _entries[key] = (value, now + ttl);
  }

  /// Drop `key` immediately (membership `Dead`/`Left`).
  void evict(K key) {
    _entries.remove(key);
  }

  /// Evict entries whose TTL has lapsed (`now >= expiry`).
  void tick(int now) {
    _entries.removeWhere((_, entry) => now >= entry.$2);
  }

  /// The live value for `key` (respecting `now`), or `null`.
  V? get(K key, int now) {
    final entry = _entries[key];
    return (entry != null && now < entry.$2) ? entry.$1 : null;
  }

  /// The live `key -> value` map at `now`, keys sorted ascending.
  Map<K, V> present(int now) {
    final keys = _entries.keys.where((k) => now < _entries[k]!.$2).toList()
      ..sort();
    return {for (final k in keys) k: _entries[k]!.$1};
  }
}

/// Shared reactive wrapper for the keyed ephemeral map. Projects the live view
/// onto a [Cell] (via [PresenceView]) so `present` invalidates only on a
/// live-view change.
abstract class EphemeralMapCell<K extends Comparable<Object?>, V>
    with Ephemeral {
  EphemeralMapCell(this.ctx, this.ttl)
      : core = EphemeralMapCore<K, V>(),
        presentCell =
            Cell<PresenceView<K, V>>(ctx, PresenceView<K, V>(<K, V>{}));

  final Context ctx;
  final int ttl;
  final EphemeralMapCore<K, V> core;
  final Cell<PresenceView<K, V>> presentCell;

  /// The ephemeral plane tag.
  Plane get plane => Plane.ephemeral;

  void _refresh(int now) {
    presentCell.value = PresenceView<K, V>(core.present(now));
  }

  /// The live `peer -> value` map.
  Map<K, V> present() => presentCell.value.entries;

  /// The live value for `peer` (respecting `now`), or `null`.
  V? get(K peer, int now) => core.get(peer, now);
}

/// Reactive per-peer presence: heartbeat-kept, membership- and TTL-evicted.
class PresenceCell<K extends Comparable<Object?>, V>
    extends EphemeralMapCell<K, V> {
  PresenceCell(super.ctx, super.ttl);

  /// Heartbeat a peer's presence (expiring at `now + ttl`).
  void heartbeat(K peer, V value, int now) {
    core.set(peer, value, now, ttl);
    _refresh(now);
  }

  /// Evict a peer on membership loss.
  void evict(K peer, int now) {
    core.evict(peer);
    _refresh(now);
  }

  /// Advance the clock; evicts entries whose TTL has lapsed.
  void tick(int now) {
    core.tick(now);
    _refresh(now);
  }
}

/// Reactive typed ephemeral broadcast (cursors / selections): last-writer-per-peer
/// with a TTL. Values do NOT merge.
class AwarenessCell<K extends Comparable<Object?>, V>
    extends EphemeralMapCell<K, V> {
  AwarenessCell(super.ctx, super.ttl);

  /// Set a peer's awareness value (last-writer wins, no merge).
  void set(K peer, V value, int now) {
    core.set(peer, value, now, ttl);
    _refresh(now);
  }

  /// Advance the clock; evicts entries whose TTL has lapsed.
  void tick(int now) {
    core.tick(now);
    _refresh(now);
  }
}
