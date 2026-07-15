//! UniFFI object and platform-backend driver.
//!
//! Domain mutations happen under `inner`; foreign backend calls and UI
//! notifications happen only after that lock has been released. This is
//! essential because a backend is allowed to emit an event immediately.

use super::{
    adapt_command, adapt_snapshot, apply_effect, ffi_error, panic_message, unix_now_ms,
    BindingCore, CoreConfig, GuiCommand, TravelCore,
};
use bluetooth::{BluetoothBackend, BluetoothCommand, BluetoothEvent, BluetoothRuntime};
use call_system::{CallSystemBackend, CallSystemCommand, CallSystemEvent, CallSystemEventSink};
use location::{LocationBackend, LocationCommand, LocationEvent, LocationEventSink};
use notifications::{
    NotificationCommand, NotificationEvent, NotificationsBackend, NotificationsEventSink,
};
use peer_transport::{
    PeerTransportBackend, PeerTransportRuntime, TransportCommand, TransportEvent,
};
use ranging::{RangingBackend, RangingCommand, RangingEvent, RangingEventSink};
use secure_storage::{
    SecureStorageBackend, SecureStorageCommand, SecureStorageEvent, SecureStorageEventSink,
};
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{json, Value};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use thiserror::Error;
use travel_core::{ModuleCommandEnvelope, ModuleEventEnvelope};

#[derive(Debug, Error, uniffi::Error)]
pub enum TravelCoreBindingError {
    #[error("TravelCore binding failed: {message}")]
    Failed { message: String },
    #[error("unexpected UniFFI callback failure: {message}")]
    Callback { message: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for TravelCoreBindingError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Callback {
            message: error.to_string(),
        }
    }
}

#[uniffi::export(foreign)]
pub trait CoreEventListener: Send + Sync {
    fn on_update(&self, reply_json: String) -> Result<(), TravelCoreBindingError>;
}

struct PlatformBackends {
    bluetooth: Arc<BluetoothRuntime>,
    peer_transport: Arc<PeerTransportRuntime>,
    location: Arc<dyn LocationBackend>,
    ranging: Arc<dyn RangingBackend>,
    notifications: Arc<dyn NotificationsBackend>,
    call_system: Arc<dyn CallSystemBackend>,
    secure_storage: Arc<dyn SecureStorageBackend>,
}

impl PlatformBackends {
    fn dispatch(&self, envelope: ModuleCommandEnvelope) -> Result<(), TravelCoreBindingError> {
        match envelope.module.as_str() {
            "bluetooth" => dispatch_bluetooth(
                self.bluetooth.as_ref(),
                decode_command("bluetooth", envelope.command)?,
                unix_now_ms(),
            ),
            "peerTransport" => dispatch_peer_transport(
                self.peer_transport.as_ref(),
                decode_command("peerTransport", envelope.command)?,
            ),
            "location" => dispatch_location(
                self.location.as_ref(),
                decode_command("location", envelope.command)?,
            ),
            "ranging" => dispatch_ranging(
                self.ranging.as_ref(),
                decode_command("ranging", envelope.command)?,
            ),
            "notifications" => dispatch_notifications(
                self.notifications.as_ref(),
                decode_command("notifications", envelope.command)?,
            ),
            "callSystem" => dispatch_call_system(
                self.call_system.as_ref(),
                decode_command("callSystem", envelope.command)?,
            ),
            "secureStorage" => dispatch_secure_storage(
                self.secure_storage.as_ref(),
                decode_command("secureStorage", envelope.command)?,
            ),
            other => Err(TravelCoreBindingError::Failed {
                message: format!("unknown platform capability module {other}"),
            }),
        }
    }

    fn shutdown(&self) -> Result<(), TravelCoreBindingError> {
        let results = [
            self.bluetooth.shutdown().map_err(binding_error),
            self.peer_transport.shutdown().map_err(binding_error),
            self.location.shutdown().map_err(binding_error),
            self.ranging.shutdown().map_err(binding_error),
            self.notifications.shutdown().map_err(binding_error),
            self.call_system.shutdown().map_err(binding_error),
            self.secure_storage.shutdown().map_err(binding_error),
        ];
        results
            .into_iter()
            .find_map(Result::err)
            .map_or(Ok(()), Err)
    }
}

fn decode_command<T: DeserializeOwned>(
    module: &str,
    command: Value,
) -> Result<T, TravelCoreBindingError> {
    serde_json::from_value(command).map_err(|error| TravelCoreBindingError::Failed {
        message: format!("invalid internal {module} command: {error}"),
    })
}

fn dispatch_bluetooth(
    runtime: &BluetoothRuntime,
    command: BluetoothCommand,
    now_ms: i64,
) -> Result<(), TravelCoreBindingError> {
    runtime.dispatch(command, now_ms).map_err(binding_error)
}

fn dispatch_peer_transport(
    runtime: &PeerTransportRuntime,
    command: TransportCommand,
) -> Result<(), TravelCoreBindingError> {
    runtime.dispatch(command).map_err(binding_error)
}

fn dispatch_location(
    backend: &dyn LocationBackend,
    command: LocationCommand,
) -> Result<(), TravelCoreBindingError> {
    let result = match command {
        LocationCommand::StartTravelUpdates {
            request_id,
            background,
        } => backend.start_travel_updates(request_id.to_string(), background),
        LocationCommand::StopTravelUpdates { request_id } => {
            backend.stop_travel_updates(request_id.to_string())
        }
        LocationCommand::RequestSample {
            request_id,
            desired_freshness_ms,
            deadline_ms,
        } => backend.request_sample(request_id.to_string(), desired_freshness_ms, deadline_ms),
    };
    result.map_err(binding_error)
}

fn dispatch_ranging(
    backend: &dyn RangingBackend,
    command: RangingCommand,
) -> Result<(), TravelCoreBindingError> {
    let result = match command {
        RangingCommand::CreateDiscoveryToken {
            request_id,
            peer_id,
        } => backend.create_discovery_token(request_id.to_string(), peer_id.to_string()),
        RangingCommand::Start {
            request_id,
            peer_id,
            remote_discovery_token,
        } => backend.start(
            request_id.to_string(),
            peer_id.to_string(),
            remote_discovery_token,
        ),
        RangingCommand::Cancel {
            request_id,
            peer_id,
            reason,
        } => backend.cancel(request_id.to_string(), peer_id.to_string(), reason),
    };
    result.map_err(binding_error)
}

fn dispatch_notifications(
    backend: &dyn NotificationsBackend,
    command: NotificationCommand,
) -> Result<(), TravelCoreBindingError> {
    let result = match command {
        NotificationCommand::RequestAuthorization { request_id } => {
            backend.request_authorization(request_id.to_string())
        }
        NotificationCommand::Schedule {
            request_id,
            identifier,
            title,
            body,
            deep_link,
            merge_key,
            time_sensitive,
        } => backend.schedule(
            request_id.to_string(),
            identifier,
            title,
            body,
            deep_link,
            merge_key,
            time_sensitive,
        ),
        NotificationCommand::Cancel {
            request_id,
            identifier,
        } => backend.cancel(request_id.to_string(), identifier),
    };
    result.map_err(binding_error)
}

fn dispatch_call_system(
    backend: &dyn CallSystemBackend,
    command: CallSystemCommand,
) -> Result<(), TravelCoreBindingError> {
    let result = match command {
        CallSystemCommand::ReportIncoming {
            request_id,
            call_id,
            peer_id,
            display_name,
        } => backend.report_incoming(
            request_id.to_string(),
            call_id.to_string(),
            peer_id.to_string(),
            display_name,
        ),
        CallSystemCommand::ReportOutgoing {
            request_id,
            call_id,
            peer_id,
            display_name,
        } => backend.report_outgoing(
            request_id.to_string(),
            call_id.to_string(),
            peer_id.to_string(),
            display_name,
        ),
        CallSystemCommand::ActivateAudio {
            request_id,
            call_id,
        } => backend.activate_audio(request_id.to_string(), call_id.to_string()),
        CallSystemCommand::DeactivateAudio {
            request_id,
            call_id,
        } => backend.deactivate_audio(request_id.to_string(), call_id.to_string()),
        CallSystemCommand::SetMuted {
            request_id,
            call_id,
            muted,
        } => backend.set_muted(request_id.to_string(), call_id.to_string(), muted),
        CallSystemCommand::SetRoute { request_id, route } => {
            backend.set_route(request_id.to_string(), route)
        }
        CallSystemCommand::PlayAudio {
            request_id,
            call_id,
            pcm16,
            sample_rate,
            channel_count,
            sequence,
            timestamp_ms,
        } => backend.play_audio(
            request_id.to_string(),
            call_id.to_string(),
            pcm16,
            sample_rate,
            channel_count,
            sequence,
            timestamp_ms,
        ),
        CallSystemCommand::End {
            request_id,
            call_id,
            reason,
        } => backend.end(request_id.to_string(), call_id.to_string(), reason),
    };
    result.map_err(binding_error)
}

fn dispatch_secure_storage(
    backend: &dyn SecureStorageBackend,
    command: SecureStorageCommand,
) -> Result<(), TravelCoreBindingError> {
    let result = match command {
        SecureStorageCommand::Put {
            request_id,
            key,
            mut value,
        } => backend.put(request_id.to_string(), key, std::mem::take(&mut value.0)),
        SecureStorageCommand::Get { request_id, key } => backend.get(request_id.to_string(), key),
        SecureStorageCommand::Delete { request_id, key } => {
            backend.delete(request_id.to_string(), key)
        }
    };
    result.map_err(binding_error)
}

#[derive(uniffi::Object)]
pub struct TravelCoreBinding {
    inner: Mutex<BindingCore>,
    backends: PlatformBackends,
    listener: Arc<dyn CoreEventListener>,
    closed: AtomicBool,
}

#[uniffi::export]
impl TravelCoreBinding {
    #[uniffi::constructor]
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        config_json: String,
        bluetooth: Arc<dyn BluetoothBackend>,
        peer_transport: Arc<dyn PeerTransportBackend>,
        location: Arc<dyn LocationBackend>,
        ranging: Arc<dyn RangingBackend>,
        notifications: Arc<dyn NotificationsBackend>,
        call_system: Arc<dyn CallSystemBackend>,
        secure_storage: Arc<dyn SecureStorageBackend>,
        listener: Arc<dyn CoreEventListener>,
    ) -> Result<Arc<Self>, TravelCoreBindingError> {
        let config: CoreConfig = serde_json::from_str(&config_json).map_err(binding_error)?;
        let core = TravelCore::new(config).map_err(binding_error)?;
        let binding = Arc::new(Self {
            inner: Mutex::new(BindingCore {
                core,
                revision: 0,
                resources: Default::default(),
            }),
            backends: PlatformBackends {
                bluetooth: BluetoothRuntime::new(bluetooth),
                peer_transport: PeerTransportRuntime::new(peer_transport),
                location,
                ranging,
                notifications,
                call_system,
                secure_storage,
            },
            listener,
            closed: AtomicBool::new(false),
        });
        binding.attach_event_sinks()?;
        binding.flush_pending_commands()?;
        Ok(binding)
    }

    /// Dispatches the stable GUI JSON vocabulary and returns a GUI reply JSON.
    pub fn dispatch_json(&self, command_json: String) -> String {
        if self.closed.load(Ordering::Acquire) {
            return encode_error("coreClosed", "TravelCore has been shut down");
        }
        let operation = catch_unwind(AssertUnwindSafe(|| self.dispatch_locked(&command_json)));
        match operation {
            Ok(Ok((reply, commands))) => match self.dispatch_commands(commands) {
                Ok(()) => encode_value(&reply),
                Err(error) => encode_error("backendDispatchFailed", error.to_string()),
            },
            Ok(Err(error)) => encode_value(&json!({"ok": false, "error": error})),
            Err(panic) => encode_error("panic", panic_message(panic)),
        }
    }

    /// Returns the current stable GUI snapshot JSON.
    pub fn snapshot_json(&self) -> String {
        if self.closed.load(Ordering::Acquire) {
            return encode_error("coreClosed", "TravelCore has been shut down");
        }
        let operation = catch_unwind(AssertUnwindSafe(|| self.snapshot_locked()));
        match operation {
            Ok(Ok(snapshot)) => encode_value(&snapshot),
            Ok(Err(error)) => encode_value(&json!({"ok": false, "error": error})),
            Err(panic) => encode_error("panic", panic_message(panic)),
        }
    }

    /// Closes event ingress before asking every platform backend to tear down.
    pub fn shutdown(&self) -> Result<(), TravelCoreBindingError> {
        if self.closed.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        self.backends.shutdown()
    }
}

impl TravelCoreBinding {
    fn attach_event_sinks(self: &Arc<Self>) -> Result<(), TravelCoreBindingError> {
        let weak = Arc::downgrade(self);
        self.backends
            .bluetooth
            .attach_event_handler(event_handler::<BluetoothEvent>(weak.clone(), "bluetooth"))
            .map_err(binding_error)?;
        self.backends
            .peer_transport
            .attach_event_handler(event_handler::<TransportEvent>(
                weak.clone(),
                "peerTransport",
            ))
            .map_err(binding_error)?;
        self.backends
            .location
            .attach_event_sink(LocationEventSink::new(event_handler::<LocationEvent>(
                weak.clone(),
                "location",
            )))
            .map_err(binding_error)?;
        self.backends
            .ranging
            .attach_event_sink(RangingEventSink::new(event_handler::<RangingEvent>(
                weak.clone(),
                "ranging",
            )))
            .map_err(binding_error)?;
        self.backends
            .notifications
            .attach_event_sink(NotificationsEventSink::new(event_handler::<
                NotificationEvent,
            >(
                weak.clone(), "notifications"
            )))
            .map_err(binding_error)?;
        self.backends
            .call_system
            .attach_event_sink(CallSystemEventSink::new(event_handler::<CallSystemEvent>(
                weak.clone(),
                "callSystem",
            )))
            .map_err(binding_error)?;
        self.backends
            .secure_storage
            .attach_event_sink(SecureStorageEventSink::new(event_handler::<
                SecureStorageEvent,
            >(
                weak, "secureStorage"
            )))
            .map_err(binding_error)
    }

    fn dispatch_locked(
        &self,
        command_json: &str,
    ) -> Result<(Value, Vec<ModuleCommandEnvelope>), Value> {
        let command: GuiCommand = serde_json::from_str(command_json).map_err(|error| {
            ffi_error(
                "invalidCommand",
                format!("command JSON is invalid: {error}"),
            )
        })?;
        let mut binding = self
            .inner
            .lock()
            .map_err(|_| ffi_error("lockPoisoned", "core lock was poisoned"))?;
        let context = binding
            .core
            .snapshot()
            .and_then(|snapshot| serde_json::to_value(snapshot).map_err(Into::into))
            .map_err(|error| ffi_error(error.code(), error.to_string()))?;
        let (command, effect) = adapt_command(command, &context, unix_now_ms())?;
        let snapshot = binding
            .core
            .dispatch(command)
            .map_err(|error| ffi_error(error.code(), error.to_string()))?;
        apply_effect(&mut binding.resources, effect);
        binding.revision = binding.revision.saturating_add(1);
        let snapshot = adapt_snapshot(
            snapshot,
            binding.revision,
            &binding.resources,
            unix_now_ms(),
        )?;
        let commands = binding.core.drain_module_commands();
        Ok((json!({"ok": true, "snapshot": snapshot}), commands))
    }

    fn snapshot_locked(&self) -> Result<Value, Value> {
        let binding = self
            .inner
            .lock()
            .map_err(|_| ffi_error("lockPoisoned", "core lock was poisoned"))?;
        let snapshot = binding
            .core
            .snapshot()
            .map_err(|error| ffi_error(error.code(), error.to_string()))?;
        serde_json::to_value(adapt_snapshot(
            snapshot,
            binding.revision,
            &binding.resources,
            unix_now_ms(),
        )?)
        .map_err(|error| ffi_error("serializationFailed", error.to_string()))
    }

    fn ingest_event(&self, module: &'static str, event: Value) {
        if self.closed.load(Ordering::Acquire) {
            return;
        }
        let operation = catch_unwind(AssertUnwindSafe(|| {
            let mut binding = self
                .inner
                .lock()
                .map_err(|_| ffi_error("lockPoisoned", "core lock was poisoned"))?;
            let snapshot = binding
                .core
                .ingest_module_event_at(
                    ModuleEventEnvelope {
                        module: module.into(),
                        event,
                    },
                    unix_now_ms(),
                )
                .map_err(|error| ffi_error(error.code(), error.to_string()))?;
            binding.revision = binding.revision.saturating_add(1);
            let snapshot = adapt_snapshot(
                snapshot,
                binding.revision,
                &binding.resources,
                unix_now_ms(),
            )?;
            let commands = binding.core.drain_module_commands();
            Ok::<_, Value>((json!({"ok": true, "snapshot": snapshot}), commands))
        }));

        let (reply, commands) = match operation {
            Ok(Ok(result)) => result,
            Ok(Err(error)) => {
                self.notify(json!({"ok": false, "error": error}));
                return;
            }
            Err(panic) => {
                self.notify(json!({
                    "ok": false,
                    "error": ffi_error("panic", panic_message(panic)),
                }));
                return;
            }
        };
        // Shutdown can race an event that already passed the entry check.
        // Do not enqueue new native work once teardown has started; the Swift
        // adapters independently close their command queues as a second guard.
        if self.closed.load(Ordering::Acquire) {
            return;
        }
        if let Err(error) = self.dispatch_commands(commands) {
            self.notify(json!({
                "ok": false,
                "error": ffi_error("backendDispatchFailed", error.to_string()),
            }));
            return;
        }
        self.notify(reply);
    }

    fn flush_pending_commands(&self) -> Result<(), TravelCoreBindingError> {
        let commands = self
            .inner
            .lock()
            .map_err(|_| TravelCoreBindingError::Failed {
                message: "core lock was poisoned".into(),
            })?
            .core
            .drain_module_commands();
        self.dispatch_commands(commands)
    }

    fn dispatch_commands(
        &self,
        commands: Vec<ModuleCommandEnvelope>,
    ) -> Result<(), TravelCoreBindingError> {
        // No core lock is held here. A synchronous/reentrant backend event is
        // therefore safe and covered by the binding tests.
        for command in commands {
            self.backends.dispatch(command)?;
        }
        Ok(())
    }

    fn notify(&self, reply: Value) {
        let _ = self.listener.on_update(encode_value(&reply));
    }
}

impl Drop for TravelCoreBinding {
    fn drop(&mut self) {
        if !self.closed.swap(true, Ordering::AcqRel) {
            let _ = self.backends.shutdown();
        }
    }
}

fn event_handler<E>(
    core: Weak<TravelCoreBinding>,
    module: &'static str,
) -> Arc<dyn Fn(E) + Send + Sync + 'static>
where
    E: Serialize + Send + 'static,
{
    Arc::new(move |event| {
        if let Some(core) = core.upgrade() {
            match serde_json::to_value(event) {
                Ok(event) => core.ingest_event(module, event),
                Err(error) => core.notify(json!({
                    "ok": false,
                    "error": ffi_error(
                        "invalidModuleEvent",
                        format!("failed to materialize typed {module} event: {error}"),
                    ),
                })),
            }
        }
    })
}

fn binding_error(error: impl std::fmt::Display) -> TravelCoreBindingError {
    TravelCoreBindingError::Failed {
        message: error.to_string(),
    }
}

fn encode_error(code: &str, message: impl Into<String>) -> String {
    encode_value(&json!({
        "ok": false,
        "error": ffi_error(code, message.into()),
    }))
}

fn encode_value(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| {
        r#"{"ok":false,"error":{"code":"serializationFailed","message":"failed to encode reply"}}"#
            .into()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use bluetooth::{BluetoothBackendError, BluetoothCapabilities, BluetoothEventSink};
    use call_system::{CallSystemBackendError, CallSystemCapabilities};
    use location::{LocationBackendError, LocationCapabilities};
    use notifications::{NotificationCapabilities, NotificationsBackendError};
    use peer_transport::{
        PeerTransportBackendError, PeerTransportEventSink, TransportCapabilities,
    };
    use ranging::{RangingBackendError, RangingCapabilities};
    use secure_storage::{SecureStorageBackendError, SecureStorageCapabilities};
    use std::sync::atomic::AtomicUsize;
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;
    use tempfile::TempDir;

    struct BackendProbe {
        name: &'static str,
        order: Arc<Mutex<Vec<String>>>,
        operation_count: AtomicUsize,
        shutdown_count: AtomicUsize,
        fail_shutdown: AtomicBool,
    }

    impl BackendProbe {
        fn new(name: &'static str, order: Arc<Mutex<Vec<String>>>) -> Self {
            Self {
                name,
                order,
                operation_count: AtomicUsize::new(0),
                shutdown_count: AtomicUsize::new(0),
                fail_shutdown: AtomicBool::new(false),
            }
        }

        fn attach(&self) {
            self.record("attach");
        }

        fn operation(&self) {
            self.operation_count.fetch_add(1, Ordering::Relaxed);
            self.record("operation");
        }

        fn shutdown(&self) {
            self.shutdown_count.fetch_add(1, Ordering::Relaxed);
            self.record("shutdown");
        }

        fn record(&self, operation: &str) {
            self.order
                .lock()
                .unwrap()
                .push(format!("{}.{}", self.name, operation));
        }
    }

    macro_rules! probe_backend {
        (
            $backend:ident,
            $trait:path,
            $capabilities:ty,
            $sink:path,
            $error:ident,
            $name:literal,
            { $($operation:item)* }
        ) => {
            struct $backend {
                probe: Arc<BackendProbe>,
            }

            impl $backend {
                fn new(order: Arc<Mutex<Vec<String>>>) -> Arc<Self> {
                    Arc::new(Self {
                        probe: Arc::new(BackendProbe::new($name, order)),
                    })
                }
            }

            impl $trait for $backend {
                fn capabilities(&self) -> Result<$capabilities, $error> {
                    Ok(<$capabilities>::default())
                }

                fn attach_event_sink(&self, _event_sink: Arc<$sink>) -> Result<(), $error> {
                    self.probe.attach();
                    Ok(())
                }

                $($operation)*

                fn shutdown(&self) -> Result<(), $error> {
                    self.probe.shutdown();
                    if self.probe.fail_shutdown.load(Ordering::Relaxed) {
                        Err($error::Backend {
                            message: format!("{} shutdown failed", self.probe.name),
                        })
                    } else {
                        Ok(())
                    }
                }
            }
        };
    }

    probe_backend!(
        FakeBluetoothBackend,
        BluetoothBackend,
        BluetoothCapabilities,
        BluetoothEventSink,
        BluetoothBackendError,
        "bluetooth",
        {
            fn start(&self, _request_id: String) -> Result<(), BluetoothBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn stop(&self, _request_id: String) -> Result<(), BluetoothBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn connect(
                &self,
                _request_id: String,
                _handle: u64,
            ) -> Result<(), BluetoothBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn disconnect(
                &self,
                _request_id: String,
                _handle: u64,
            ) -> Result<(), BluetoothBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn send_packet(
                &self,
                _request_id: String,
                _handle: u64,
                _packet: Vec<u8>,
            ) -> Result<(), BluetoothBackendError> {
                self.probe.operation();
                Ok(())
            }
        }
    );
    probe_backend!(
        FakePeerTransportBackend,
        PeerTransportBackend,
        TransportCapabilities,
        PeerTransportEventSink,
        PeerTransportBackendError,
        "peerTransport",
        {
            #[allow(clippy::too_many_arguments)]
            fn start_discovery(
                &self,
                _request_id: String,
                _local_peer_id: String,
                _discovery_scope: String,
                _display_name: String,
                _protocol_version: u16,
                _certificate_der: Vec<u8>,
                _private_key_pkcs8: Vec<u8>,
            ) -> Result<(), PeerTransportBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn stop_discovery(&self, _request_id: String) -> Result<(), PeerTransportBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn connect(
                &self,
                _request_id: String,
                _peer_id: String,
            ) -> Result<(), PeerTransportBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn disconnect(
                &self,
                _request_id: String,
                _connection: u64,
            ) -> Result<(), PeerTransportBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn send_frame(
                &self,
                _request_id: String,
                _connection: u64,
                _channel: peer_transport::TransportChannel,
                _bytes: Vec<u8>,
            ) -> Result<(), PeerTransportBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn set_realtime(
                &self,
                _request_id: String,
                _realtime: bool,
            ) -> Result<(), PeerTransportBackendError> {
                self.probe.operation();
                Ok(())
            }
        }
    );
    probe_backend!(
        FakeLocationBackend,
        LocationBackend,
        LocationCapabilities,
        LocationEventSink,
        LocationBackendError,
        "location",
        {
            fn start_travel_updates(
                &self,
                _request_id: String,
                _background: bool,
            ) -> Result<(), LocationBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn stop_travel_updates(&self, _request_id: String) -> Result<(), LocationBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn request_sample(
                &self,
                _request_id: String,
                _desired_freshness_ms: i64,
                _deadline_ms: i64,
            ) -> Result<(), LocationBackendError> {
                self.probe.operation();
                Ok(())
            }
        }
    );
    probe_backend!(
        FakeRangingBackend,
        RangingBackend,
        RangingCapabilities,
        RangingEventSink,
        RangingBackendError,
        "ranging",
        {
            fn create_discovery_token(
                &self,
                _request_id: String,
                _peer_id: String,
            ) -> Result<(), RangingBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn start(
                &self,
                _request_id: String,
                _peer_id: String,
                _remote_discovery_token: Vec<u8>,
            ) -> Result<(), RangingBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn cancel(
                &self,
                _request_id: String,
                _peer_id: String,
                _reason: String,
            ) -> Result<(), RangingBackendError> {
                self.probe.operation();
                Ok(())
            }
        }
    );
    probe_backend!(
        FakeNotificationsBackend,
        NotificationsBackend,
        NotificationCapabilities,
        NotificationsEventSink,
        NotificationsBackendError,
        "notifications",
        {
            fn request_authorization(
                &self,
                _request_id: String,
            ) -> Result<(), NotificationsBackendError> {
                self.probe.operation();
                Ok(())
            }
            #[allow(clippy::too_many_arguments)]
            fn schedule(
                &self,
                _request_id: String,
                _identifier: String,
                _title: String,
                _body: String,
                _deep_link: Option<String>,
                _merge_key: Option<String>,
                _time_sensitive: bool,
            ) -> Result<(), NotificationsBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn cancel(
                &self,
                _request_id: String,
                _identifier: String,
            ) -> Result<(), NotificationsBackendError> {
                self.probe.operation();
                Ok(())
            }
        }
    );
    probe_backend!(
        FakeCallSystemBackend,
        CallSystemBackend,
        CallSystemCapabilities,
        CallSystemEventSink,
        CallSystemBackendError,
        "callSystem",
        {
            #[allow(clippy::too_many_arguments)]
            fn report_incoming(
                &self,
                _request_id: String,
                _call_id: String,
                _peer_id: String,
                _display_name: String,
            ) -> Result<(), CallSystemBackendError> {
                self.probe.operation();
                Ok(())
            }
            #[allow(clippy::too_many_arguments)]
            fn report_outgoing(
                &self,
                _request_id: String,
                _call_id: String,
                _peer_id: String,
                _display_name: String,
            ) -> Result<(), CallSystemBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn activate_audio(
                &self,
                _request_id: String,
                _call_id: String,
            ) -> Result<(), CallSystemBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn deactivate_audio(
                &self,
                _request_id: String,
                _call_id: String,
            ) -> Result<(), CallSystemBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn set_muted(
                &self,
                _request_id: String,
                _call_id: String,
                _muted: bool,
            ) -> Result<(), CallSystemBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn set_route(
                &self,
                _request_id: String,
                _route: call_system::AudioRoute,
            ) -> Result<(), CallSystemBackendError> {
                self.probe.operation();
                Ok(())
            }
            #[allow(clippy::too_many_arguments)]
            fn play_audio(
                &self,
                _request_id: String,
                _call_id: String,
                _pcm16: Vec<u8>,
                _sample_rate: u32,
                _channel_count: u32,
                _sequence: u64,
                _timestamp_ms: i64,
            ) -> Result<(), CallSystemBackendError> {
                self.probe.operation();
                Ok(())
            }
            fn end(
                &self,
                _request_id: String,
                _call_id: String,
                _reason: String,
            ) -> Result<(), CallSystemBackendError> {
                self.probe.operation();
                Ok(())
            }
        }
    );

    struct FakeSecureStorageBackend {
        probe: Arc<BackendProbe>,
        sink: Mutex<Option<Arc<SecureStorageEventSink>>>,
        emit_synchronously: bool,
        emitted: AtomicBool,
    }

    impl FakeSecureStorageBackend {
        fn new(order: Arc<Mutex<Vec<String>>>, emit_synchronously: bool) -> Arc<Self> {
            Arc::new(Self {
                probe: Arc::new(BackendProbe::new("secureStorage", order)),
                sink: Mutex::new(None),
                emit_synchronously,
                emitted: AtomicBool::new(false),
            })
        }
    }

    impl SecureStorageBackend for FakeSecureStorageBackend {
        fn capabilities(&self) -> Result<SecureStorageCapabilities, SecureStorageBackendError> {
            Ok(SecureStorageCapabilities::default())
        }

        fn attach_event_sink(
            &self,
            event_sink: Arc<SecureStorageEventSink>,
        ) -> Result<(), SecureStorageBackendError> {
            self.probe.attach();
            *self.sink.lock().unwrap() = Some(event_sink);
            Ok(())
        }

        fn put(
            &self,
            request_id: String,
            key: String,
            _value: Vec<u8>,
        ) -> Result<(), SecureStorageBackendError> {
            self.probe.operation();
            if self.emit_synchronously && !self.emitted.swap(true, Ordering::AcqRel) {
                let sink = self.sink.lock().unwrap().clone().unwrap();
                sink.stored(request_id, key);
            }
            Ok(())
        }

        fn get(&self, _request_id: String, _key: String) -> Result<(), SecureStorageBackendError> {
            self.probe.operation();
            Ok(())
        }

        fn delete(
            &self,
            _request_id: String,
            _key: String,
        ) -> Result<(), SecureStorageBackendError> {
            self.probe.operation();
            Ok(())
        }

        fn shutdown(&self) -> Result<(), SecureStorageBackendError> {
            self.probe.shutdown();
            Ok(())
        }
    }

    #[derive(Default)]
    struct RecordingListener {
        updates: Mutex<Vec<String>>,
    }

    impl CoreEventListener for RecordingListener {
        fn on_update(&self, reply_json: String) -> Result<(), TravelCoreBindingError> {
            self.updates.lock().unwrap().push(reply_json);
            Ok(())
        }
    }

    struct Fixture {
        order: Arc<Mutex<Vec<String>>>,
        bluetooth: Arc<FakeBluetoothBackend>,
        peer_transport: Arc<FakePeerTransportBackend>,
        location: Arc<FakeLocationBackend>,
        ranging: Arc<FakeRangingBackend>,
        notifications: Arc<FakeNotificationsBackend>,
        call_system: Arc<FakeCallSystemBackend>,
        secure_storage: Arc<FakeSecureStorageBackend>,
        listener: Arc<RecordingListener>,
    }

    impl Fixture {
        fn new(emit_synchronously: bool) -> Self {
            let order = Arc::new(Mutex::new(Vec::new()));
            Self {
                bluetooth: FakeBluetoothBackend::new(Arc::clone(&order)),
                peer_transport: FakePeerTransportBackend::new(Arc::clone(&order)),
                location: FakeLocationBackend::new(Arc::clone(&order)),
                ranging: FakeRangingBackend::new(Arc::clone(&order)),
                notifications: FakeNotificationsBackend::new(Arc::clone(&order)),
                call_system: FakeCallSystemBackend::new(Arc::clone(&order)),
                secure_storage: FakeSecureStorageBackend::new(
                    Arc::clone(&order),
                    emit_synchronously,
                ),
                listener: Arc::new(RecordingListener::default()),
                order,
            }
        }

        fn construct(
            &self,
            config_json: String,
        ) -> Result<Arc<TravelCoreBinding>, TravelCoreBindingError> {
            TravelCoreBinding::new(
                config_json,
                self.bluetooth.clone(),
                self.peer_transport.clone(),
                self.location.clone(),
                self.ranging.clone(),
                self.notifications.clone(),
                self.call_system.clone(),
                self.secure_storage.clone(),
                self.listener.clone(),
            )
        }

        fn probes(&self) -> [&BackendProbe; 7] {
            [
                &self.bluetooth.probe,
                &self.peer_transport.probe,
                &self.location.probe,
                &self.ranging.probe,
                &self.notifications.probe,
                &self.call_system.probe,
                &self.secure_storage.probe,
            ]
        }
    }

    fn test_config() -> (TempDir, String) {
        let directory = tempfile::tempdir().unwrap();
        let config = json!({
            "storagePath": directory.path().join("core.sqlite3"),
            "resourcesPath": directory.path().join("resources"),
            "displayName": "Alice",
        })
        .to_string();
        (directory, config)
    }

    #[test]
    fn constructor_attaches_every_sink_before_initial_secure_storage_operation() {
        let (_directory, config) = test_config();
        let fixture = Fixture::new(false);
        let binding = fixture.construct(config).unwrap();
        let order = fixture.order.lock().unwrap().clone();
        let first_operation = order
            .iter()
            .position(|entry| entry.ends_with(".operation"))
            .unwrap();

        assert_eq!(
            order[..first_operation]
                .iter()
                .filter(|entry| entry.ends_with(".attach"))
                .count(),
            7
        );
        assert!(
            order
                .iter()
                .position(|entry| entry == "secureStorage.attach")
                .unwrap()
                < first_operation
        );
        assert_eq!(order[first_operation], "secureStorage.operation");

        binding.shutdown().unwrap();
    }

    #[test]
    fn synchronous_operation_event_is_reentrant_and_notifies_listener() {
        let (_directory, config) = test_config();
        let fixture = Arc::new(Fixture::new(true));
        let fixture_for_thread = Arc::clone(&fixture);
        let (sender, receiver) = mpsc::sync_channel(1);
        thread::spawn(move || {
            let result = fixture_for_thread.construct(config);
            let _ = sender.send(result);
        });

        let binding = receiver
            .recv_timeout(Duration::from_secs(5))
            .expect("constructor deadlocked during synchronous backend event")
            .unwrap();
        let updates = fixture.listener.updates.lock().unwrap();
        assert_eq!(updates.len(), 1);
        let reply: Value = serde_json::from_str(&updates[0]).unwrap();
        assert_eq!(reply["ok"], true);
        drop(updates);

        binding.shutdown().unwrap();
    }

    #[test]
    fn public_commands_return_the_stable_gui_schema() {
        let (_directory, config) = test_config();
        let fixture = Fixture::new(false);
        let binding = fixture.construct(config).unwrap();

        let reply: Value = serde_json::from_str(
            &binding.dispatch_json(r#"{"type":"createGroup","name":"Trip"}"#.into()),
        )
        .unwrap();
        assert_eq!(reply["ok"], true, "{reply:#}");
        let snapshot = &reply["snapshot"];
        assert_eq!(snapshot["protocolVersion"], crate::PROTOCOL_VERSION);
        assert_eq!(snapshot["revision"], 1);
        assert_eq!(snapshot["identity"]["displayName"], "Alice");
        assert!(snapshot["identity"].get("peerID").is_some());
        assert_eq!(snapshot["group"]["name"], "Trip");
        assert!(snapshot["group"].get("invitePIN").is_some());
        assert!(snapshot["group"].get("invitePin").is_none());
        assert_eq!(snapshot["conversations"][0]["id"], "group");
        assert!(snapshot.get("pendingPrecisionRequests").is_some());
        assert!(snapshot["lifecycle"].get("sharingPaused").is_none());
        assert!(snapshot["identity"].get("keyReady").is_none());

        let reply: Value = serde_json::from_str(
            &binding.dispatch_json(r#"{"type":"setLocationSharing","enabled":false}"#.into()),
        )
        .unwrap();
        assert_eq!(
            reply["snapshot"]["lifecycle"]["locationSharingEnabled"],
            false
        );
        binding.shutdown().unwrap();
    }

    #[test]
    fn legacy_internal_command_schema_is_not_public() {
        let (_directory, config) = test_config();
        let fixture = Fixture::new(false);
        let binding = fixture.construct(config).unwrap();

        let reply: Value = serde_json::from_str(
            &binding.dispatch_json(r#"{"kind":"createGroup","name":"Trip","nowMs":1}"#.into()),
        )
        .unwrap();
        assert_eq!(reply["ok"], false);
        assert_eq!(reply["error"]["code"], "invalidCommand");
        binding.shutdown().unwrap();
    }

    #[test]
    fn shutdown_is_idempotent_and_reaches_every_backend_once() {
        let (_directory, config) = test_config();
        let fixture = Fixture::new(false);
        let binding = fixture.construct(config).unwrap();

        binding.shutdown().unwrap();
        binding.shutdown().unwrap();
        drop(binding);

        for probe in fixture.probes() {
            assert_eq!(
                probe.shutdown_count.load(Ordering::Relaxed),
                1,
                "{}",
                probe.name
            );
        }
    }

    #[test]
    fn shutdown_continues_after_a_backend_error() {
        let (_directory, config) = test_config();
        let fixture = Fixture::new(false);
        let binding = fixture.construct(config).unwrap();
        fixture
            .bluetooth
            .probe
            .fail_shutdown
            .store(true, Ordering::Relaxed);

        assert!(binding.shutdown().is_err());
        for probe in fixture.probes() {
            assert_eq!(
                probe.shutdown_count.load(Ordering::Relaxed),
                1,
                "{}",
                probe.name
            );
        }
    }
}
