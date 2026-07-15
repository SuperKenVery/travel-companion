//! Typed UniFFI contract implemented by platform and fake backends.
//!
//! CallKit and AVFAudio objects remain behind the foreign backend. Only domain
//! identifiers, values, and actual PCM payload bytes cross this boundary.

use std::sync::Arc;
use thiserror::Error;

#[derive(Debug, Error, uniffi::Error)]
pub enum CallSystemBackendError {
    #[error("backend rejected operation: {message}")]
    Backend { message: String },
    #[error("unexpected UniFFI callback failure: {message}")]
    Callback { message: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for CallSystemBackendError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Callback {
            message: error.to_string(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct CallSystemEventSink {
    handler: Arc<dyn Fn(crate::CallSystemEvent) + Send + Sync + 'static>,
}

impl CallSystemEventSink {
    /// Constructs the Rust-owned event sink. This constructor is
    /// intentionally not exported through UniFFI.
    #[must_use]
    pub fn new(handler: Arc<dyn Fn(crate::CallSystemEvent) + Send + Sync + 'static>) -> Arc<Self> {
        Arc::new(Self { handler })
    }
}

#[uniffi::export]
impl CallSystemEventSink {
    pub fn incoming_reported(&self, request_id: String, call_id: String) {
        (self.handler)(crate::CallSystemEvent::IncomingReported {
            request_id: model::RequestId::from_string(request_id),
            call_id: model::CallId::from_string(call_id),
        });
    }

    pub fn outgoing_reported(&self, request_id: String, call_id: String) {
        (self.handler)(crate::CallSystemEvent::OutgoingReported {
            request_id: model::RequestId::from_string(request_id),
            call_id: model::CallId::from_string(call_id),
        });
    }

    pub fn user_answered(&self, call_id: String) {
        (self.handler)(crate::CallSystemEvent::UserAnswered {
            call_id: model::CallId::from_string(call_id),
        });
    }

    pub fn user_rejected(&self, call_id: String) {
        (self.handler)(crate::CallSystemEvent::UserRejected {
            call_id: model::CallId::from_string(call_id),
        });
    }

    pub fn user_ended(&self, call_id: String) {
        (self.handler)(crate::CallSystemEvent::UserEnded {
            call_id: model::CallId::from_string(call_id),
        });
    }

    pub fn audio_activated(&self, call_id: String) {
        (self.handler)(crate::CallSystemEvent::AudioActivated {
            call_id: model::CallId::from_string(call_id),
        });
    }

    pub fn audio_deactivated(&self, call_id: String) {
        (self.handler)(crate::CallSystemEvent::AudioDeactivated {
            call_id: model::CallId::from_string(call_id),
        });
    }

    pub fn audio_interrupted(&self, call_id: String, should_resume: bool) {
        (self.handler)(crate::CallSystemEvent::AudioInterrupted {
            call_id: model::CallId::from_string(call_id),
            should_resume,
        });
    }

    pub fn route_changed(&self, route: crate::AudioRoute) {
        (self.handler)(crate::CallSystemEvent::RouteChanged { route });
    }

    #[allow(clippy::too_many_arguments)]
    pub fn audio_frame(
        &self,
        call_id: String,
        pcm16: Vec<u8>,
        sample_rate: u32,
        channel_count: u32,
        sequence: u64,
        timestamp_ms: i64,
    ) {
        (self.handler)(crate::CallSystemEvent::AudioFrame {
            call_id: model::CallId::from_string(call_id),
            pcm16,
            sample_rate,
            channel_count,
            sequence,
            timestamp_ms,
        });
    }

    pub fn muted_changed(&self, call_id: String, muted: bool) {
        (self.handler)(crate::CallSystemEvent::MutedChanged {
            call_id: model::CallId::from_string(call_id),
            muted,
        });
    }

    pub fn failed(&self, request_id: Option<String>, code: String, message: String) {
        (self.handler)(crate::CallSystemEvent::Failed {
            request_id: request_id.map(model::RequestId::from_string),
            code,
            message,
        });
    }
}

#[uniffi::export(foreign)]
pub trait CallSystemBackend: Send + Sync {
    fn capabilities(&self) -> Result<crate::CallSystemCapabilities, CallSystemBackendError>;

    fn attach_event_sink(
        &self,
        event_sink: Arc<CallSystemEventSink>,
    ) -> Result<(), CallSystemBackendError>;

    fn report_incoming(
        &self,
        request_id: String,
        call_id: String,
        peer_id: String,
        display_name: String,
    ) -> Result<(), CallSystemBackendError>;

    fn report_outgoing(
        &self,
        request_id: String,
        call_id: String,
        peer_id: String,
        display_name: String,
    ) -> Result<(), CallSystemBackendError>;

    fn activate_audio(
        &self,
        request_id: String,
        call_id: String,
    ) -> Result<(), CallSystemBackendError>;

    fn deactivate_audio(
        &self,
        request_id: String,
        call_id: String,
    ) -> Result<(), CallSystemBackendError>;

    fn set_muted(
        &self,
        request_id: String,
        call_id: String,
        muted: bool,
    ) -> Result<(), CallSystemBackendError>;

    fn set_route(
        &self,
        request_id: String,
        route: crate::AudioRoute,
    ) -> Result<(), CallSystemBackendError>;

    #[allow(clippy::too_many_arguments)]
    fn play_audio(
        &self,
        request_id: String,
        call_id: String,
        pcm16: Vec<u8>,
        sample_rate: u32,
        channel_count: u32,
        sequence: u64,
        timestamp_ms: i64,
    ) -> Result<(), CallSystemBackendError>;

    fn end(
        &self,
        request_id: String,
        call_id: String,
        reason: String,
    ) -> Result<(), CallSystemBackendError>;

    fn shutdown(&self) -> Result<(), CallSystemBackendError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn event_sink_constructs_typed_events() {
        let received = Arc::new(Mutex::new(Vec::new()));
        let received_by_handler = Arc::clone(&received);
        let sink = CallSystemEventSink::new(Arc::new(move |event| {
            received_by_handler.lock().unwrap().push(event);
        }));

        sink.audio_interrupted("call-one".to_owned(), true);

        assert_eq!(
            *received.lock().unwrap(),
            [crate::CallSystemEvent::AudioInterrupted {
                call_id: "call-one".into(),
                should_resume: true,
            }]
        );
    }
}
