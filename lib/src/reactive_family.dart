/// The unified keyed reactive family ([ReactiveFamily]) and its materialization
/// mode (`#lzmatmode`).
///
/// `lazily-spec/cell-model.md` § "The `ReactiveFamily` vehicle" fixes a **keyed
/// reactive family** that maps keys `K` to per-entry reactive nodes and
/// abstracts over the entry's **handle kind** (`ReactiveFamily<K, V, H>`):
///
/// - **Cell entries** ([EntryKind.cell]) are **input** nodes. An input has no
///   derivation to defer, so it is **always materialized** regardless of mode.
///   The keyed cell collection ([cellFamily]) is this input-cell specialization.
/// - **Slot entries** ([EntryKind.slot]) are **derived** nodes. These are what
///   materialization mode governs: eager allocates up front, lazy defers each to
///   first read.
///
/// Materialization mode is **orthogonal** to entry kind and MUST NOT be
/// observable through any cell's value — it changes allocation timing and
/// memory, never results. [MaterializationMode.eager] is the required default;
/// [MaterializationMode.lazy] is an opt-in keyed overlay on the eager core (the
/// first read of key `k` builds the *same* node the eager build would have, then
/// caches it).
///
/// Rust reference: `lazily-rs/src/reactive_family.rs`. Formal proof:
/// `lazily-formal/LazilyFormal/Materialization.lean` (`observe_canonical`,
/// `eager_lazy_observationally_equivalent`,
/// `cell_entries_materialized_in_every_mode`, `slot_entries_deferred_under_lazy`,
/// `materialize_present_monotone`, `lazy_present_subset_eager`,
/// `materialize_preserves_observe`).
library;

import 'core.dart';

/// Which kind of reactive node a [ReactiveFamily] entry is — the handle-kind
/// axis the family abstracts over, kept orthogonal to [MaterializationMode].
///
/// Mirrors `EntryKind` in `lazily-formal`'s `Materialization` module.
enum EntryKind {
  /// An **input** cell — always materialized, any mode.
  cell,

  /// A **derived** slot — materialized eagerly, or lazily on first read.
  slot,
}

/// When a [ReactiveFamily]'s derived (slot) entries are allocated. Orthogonal to
/// [EntryKind]; never observable on the value axis.
///
/// Mirrors `Mode` in `lazily-formal`'s `Materialization` module. The default is
/// [eager] (`Mode.default = Mode.eager`).
enum MaterializationMode {
  /// Allocate every derived node up front at build time. The shared
  /// high-performance core and the required default.
  eager,

  /// Allocate a derived node on its first read, keyed rather than
  /// handle-addressed. An opt-in overlay on the eager core.
  lazy,
}

/// The default materialization mode (`Mode.default = Mode.eager`).
const MaterializationMode kDefaultMaterializationMode = MaterializationMode.eager;

/// Resolves an entry kind for [key] — either a fixed [EntryKind] or a per-key
/// resolver `EntryKind Function(K key)`.
typedef EntryKindResolver<K> = EntryKind Function(K key);

class _Entry<V> {
  _Entry(this.kind, this.node);

  final EntryKind kind;

  /// The reactive node: a [Cell] for [EntryKind.cell], a [Slot] for
  /// [EntryKind.slot].
  final Object node;
}

/// The unified keyed reactive family (`#lzmatmode`): keys `K` map to per-entry
/// reactive nodes ([EntryKind.cell] input cells or [EntryKind.slot] derived
/// slots), allocated per the family's [MaterializationMode].
///
/// Operations run against the owning [Context], like the rest of `lazily`.
class ReactiveFamily<K, V> {
  /// Construct a family in [mode] over [keys], with [factory] the canonical
  /// per-key value producer.
  ///
  /// [entryKind] fixes each entry's kind — pass an [EntryKind] for a uniform
  /// family, or an [EntryKindResolver] (`EntryKind Function(K)`) for a mixed
  /// one. Defaults to [EntryKind.slot] (a derived family).
  ReactiveFamily(
    this._ctx,
    this._mode,
    Iterable<K> keys,
    V Function(K key) factory, {
    Object entryKind = EntryKind.slot,
  })  : _factory = factory,
        _entryKind = entryKind {
    if (entryKind is! EntryKind && entryKind is! EntryKindResolver<K>) {
      throw ArgumentError(
          'entryKind must be an EntryKind or an EntryKind Function($K key)');
    }
    for (final key in keys) {
      // A cell entry is always materialized regardless of mode; a slot entry
      // only under eager. (buildEager materializes every node; buildLazy
      // materializes only input cells — `present := isInput`.)
      if (_resolveKind(key) == EntryKind.cell ||
          _mode == MaterializationMode.eager) {
        _materializeKey(key);
      }
    }
  }

  /// Build an **eager** family: every declared key's node is allocated now. This
  /// is the default mode ([MaterializationMode.eager]).
  static ReactiveFamily<K, V> eager<K, V>(
    Context ctx,
    Iterable<K> keys,
    V Function(K key) factory, {
    Object entryKind = EntryKind.slot,
  }) =>
      ReactiveFamily<K, V>(ctx, MaterializationMode.eager, keys, factory,
          entryKind: entryKind);

  /// Build a **lazy** family: derived (slot) entries are deferred to first read;
  /// input (cell) entries in [keys] are still materialized at build. Pass an
  /// empty [keys] for a purely on-demand slot family.
  static ReactiveFamily<K, V> lazy<K, V>(
    Context ctx,
    Iterable<K> keys,
    V Function(K key) factory, {
    Object entryKind = EntryKind.slot,
  }) =>
      ReactiveFamily<K, V>(ctx, MaterializationMode.lazy, keys, factory,
          entryKind: entryKind);

  /// Build a family in the **default** mode (eager). Alias for [eager].
  static ReactiveFamily<K, V> create<K, V>(
    Context ctx,
    Iterable<K> keys,
    V Function(K key) factory, {
    Object entryKind = EntryKind.slot,
  }) =>
      ReactiveFamily.eager<K, V>(ctx, keys, factory, entryKind: entryKind);

  final Context _ctx;
  final MaterializationMode _mode;
  final V Function(K key) _factory;
  final Object _entryKind;

  /// Present (materialized) entries — the growing "present set".
  final Map<K, _Entry<V>> _materialized = {};

  /// First-materialization order of the present set (stable snapshot).
  final List<K> _order = [];

  EntryKind _resolveKind(K key) {
    final ek = _entryKind;
    final kind = ek is EntryKind ? ek : (ek as EntryKindResolver<K>)(key);
    return kind;
  }

  _Entry<V> _materializeKey(K key) {
    final existing = _materialized[key];
    if (existing != null) return existing; // warm: already allocated.
    final kind = _resolveKind(key);
    // A cell entry sets its value directly (materialize-by-set); a slot entry
    // wraps the factory as its recomputation — the same node an eager build
    // would allocate.
    final Object node = kind == EntryKind.cell
        ? Cell<V>(_ctx, _factory(key))
        : Slot<V>(_ctx, (_) => _factory(key));
    final entry = _Entry<V>(kind, node);
    _materialized[key] = entry;
    _order.add(key);
    return entry;
  }

  /// Get the reactive node for [key] ([Cell] for a cell entry, [Slot] for a slot
  /// entry), materializing it on first access (the lazy pull) and caching it.
  /// Under eager mode an entry is already present.
  Object get(K key) => _materializeKey(key).node;

  /// Get [key]'s entry as a writable input [Cell]. Throws if [key] is a derived
  /// slot.
  Cell<V> cell(K key) {
    final entry = _materializeKey(key);
    if (entry.kind != EntryKind.cell) {
      throw StateError('key $key is a derived slot, not a writable input cell');
    }
    return entry.node as Cell<V>;
  }

  /// Get [key]'s entry as a derived [Slot]. Throws if [key] is an input cell.
  Slot<V> slot(K key) {
    final entry = _materializeKey(key);
    if (entry.kind != EntryKind.slot) {
      throw StateError('key $key is an input cell, not a derived slot');
    }
    return entry.node as Slot<V>;
  }

  /// Observe [key]'s value — the headline transparency law: the returned value
  /// is identical under either mode. Materializes the entry if absent.
  V observe(K key) {
    final entry = _materializeKey(key);
    return entry.kind == EntryKind.cell
        ? (entry.node as Cell<V>).get()
        : (entry.node as Slot<V>).call();
  }

  /// Set a cell entry's value (input entries only). Materializes it if absent.
  /// Throws if [key] is a derived slot.
  void setCell(K key, V value) {
    cell(key).set(value);
  }

  /// Whether [key] is currently materialized (present in the allocated set).
  /// Non-reactive.
  bool isPresent(K key) => _materialized.containsKey(key);

  /// The currently-materialized keys, in first-materialization order. The
  /// present set only grows (deferral, not de-allocation).
  List<K> presentKeys() => List<K>.of(_order);

  /// Number of currently-materialized entries.
  int presentCount() => _order.length;

  /// This family's entry kind for [key] ([EntryKind.cell] or [EntryKind.slot]).
  EntryKind entryKind(K key) => _resolveKind(key);

  /// This family's materialization mode.
  MaterializationMode get mode => _mode;
}

/// The input-cell specialization of [ReactiveFamily]: a keyed family whose
/// entries are all input cells ([EntryKind.cell] — always materialized).
/// Convenience factory that fixes `entryKind` to [EntryKind.cell].
ReactiveFamily<K, V> cellFamily<K, V>(
  Context ctx,
  Iterable<K> keys,
  V Function(K key) factory, {
  MaterializationMode mode = kDefaultMaterializationMode,
}) =>
    ReactiveFamily<K, V>(ctx, mode, keys, factory, entryKind: EntryKind.cell);
