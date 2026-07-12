/// Reliable sync protocol (`#lzsync`, protocol.md § Reliable Sync).
///
/// Exposes the receiver-side `ResyncCoordinator` (`ResyncAction`), the
/// sender-side at-least-once `DurableOutbox` / `InMemoryOutbox`, the OR-set /
/// LWW liveness cells (`OrSet`, `WireLwwRegister`), the host-injected seams
/// (`Clock`, `SnapshotProvider`, `IpcSink`, `IpcSource`), and the full-duplex
/// `SyncDriver` (`Progress`, `DriverError`). The reverse-channel control frames
/// (`ResyncRequest` / `OutboxAck`) live in `package:lazily/ipc.dart`.
library lazily.reliable_sync;

export 'src/reliable_sync.dart';
