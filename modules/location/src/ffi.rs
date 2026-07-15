//! Typed UniFFI contract implemented by platform and fake backends.
//!
//! Platform framework objects remain behind the foreign backend and never
//! cross this boundary.

use std::sync::Arc;
use thiserror::Error;

#[derive(Debug, Error, uniffi::Error)]
pub enum LocationBackendError {
    #[error("backend rejected operation: {message}")]
    Backend { message: String },
    #[error("unexpected UniFFI callback failure: {message}")]
    Callback { message: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for LocationBackendError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Callback {
            message: error.to_string(),
        }
    }
}

/// FFI-safe projection of the platform-neutral location sample.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct LocationSampleRecord {
    pub latitude: f64,
    pub longitude: f64,
    pub altitude_m: Option<f64>,
    pub horizontal_accuracy_m: f64,
    pub speed_mps: Option<f64>,
    pub course_degrees: Option<f64>,
    pub sampled_at_ms: i64,
}

impl From<LocationSampleRecord> for model::LocationSample {
    fn from(sample: LocationSampleRecord) -> Self {
        Self {
            latitude: sample.latitude,
            longitude: sample.longitude,
            altitude_m: sample.altitude_m,
            horizontal_accuracy_m: sample.horizontal_accuracy_m,
            speed_mps: sample.speed_mps,
            course_degrees: sample.course_degrees,
            sampled_at_ms: sample.sampled_at_ms,
        }
    }
}

impl From<model::LocationSample> for LocationSampleRecord {
    fn from(sample: model::LocationSample) -> Self {
        Self {
            latitude: sample.latitude,
            longitude: sample.longitude,
            altitude_m: sample.altitude_m,
            horizontal_accuracy_m: sample.horizontal_accuracy_m,
            speed_mps: sample.speed_mps,
            course_degrees: sample.course_degrees,
            sampled_at_ms: sample.sampled_at_ms,
        }
    }
}

#[derive(uniffi::Object)]
pub struct LocationEventSink {
    handler: Arc<dyn Fn(crate::LocationEvent) + Send + Sync + 'static>,
}

impl LocationEventSink {
    /// Constructs the Rust-owned event sink. This constructor is
    /// intentionally not exported through UniFFI.
    #[must_use]
    pub fn new(handler: Arc<dyn Fn(crate::LocationEvent) + Send + Sync + 'static>) -> Arc<Self> {
        Arc::new(Self { handler })
    }

    pub(crate) fn emit(&self, event: crate::LocationEvent) {
        (self.handler)(event);
    }
}

#[uniffi::export]
impl LocationEventSink {
    pub fn started(&self, request_id: String) {
        self.emit(crate::LocationEvent::Started {
            request_id: model::RequestId::from_string(request_id),
        });
    }

    pub fn stopped(&self, request_id: String) {
        self.emit(crate::LocationEvent::Stopped {
            request_id: model::RequestId::from_string(request_id),
        });
    }

    pub fn authorization_changed(&self, status: crate::LocationAuthorization) {
        self.emit(crate::LocationEvent::AuthorizationChanged { status });
    }

    pub fn sample(
        &self,
        request_id: Option<String>,
        sample: LocationSampleRecord,
        from_cache: bool,
    ) {
        self.emit(crate::LocationEvent::Sample {
            request_id: request_id.map(model::RequestId::from_string),
            sample: sample.into(),
            from_cache,
        });
    }

    pub fn timed_out(&self, request_id: String, stale_sample: Option<LocationSampleRecord>) {
        self.emit(crate::LocationEvent::TimedOut {
            request_id: model::RequestId::from_string(request_id),
            stale_sample: stale_sample.map(Into::into),
        });
    }

    pub fn failed(
        &self,
        request_id: Option<String>,
        code: String,
        message: String,
        retryable: bool,
    ) {
        self.emit(crate::LocationEvent::Failed {
            request_id: request_id.map(model::RequestId::from_string),
            code,
            message,
            retryable,
        });
    }
}

#[uniffi::export(foreign)]
pub trait LocationBackend: Send + Sync {
    fn capabilities(&self) -> Result<crate::LocationCapabilities, LocationBackendError>;

    fn attach_event_sink(
        &self,
        event_sink: Arc<LocationEventSink>,
    ) -> Result<(), LocationBackendError>;

    fn start_travel_updates(
        &self,
        request_id: String,
        background: bool,
    ) -> Result<(), LocationBackendError>;

    fn stop_travel_updates(&self, request_id: String) -> Result<(), LocationBackendError>;

    fn request_sample(
        &self,
        request_id: String,
        desired_freshness_ms: i64,
        deadline_ms: i64,
    ) -> Result<(), LocationBackendError>;

    fn shutdown(&self) -> Result<(), LocationBackendError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn event_sink_constructs_typed_events() {
        let received = Arc::new(Mutex::new(Vec::new()));
        let received_by_handler = Arc::clone(&received);
        let sink = LocationEventSink::new(Arc::new(move |event| {
            received_by_handler.lock().unwrap().push(event);
        }));

        sink.authorization_changed(crate::LocationAuthorization::Always);

        assert_eq!(
            *received.lock().unwrap(),
            [crate::LocationEvent::AuthorizationChanged {
                status: crate::LocationAuthorization::Always,
            }]
        );
    }
}
