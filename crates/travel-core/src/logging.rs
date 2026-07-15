use std::sync::Once;

#[cfg(target_vendor = "apple")]
pub(crate) fn initialize(storage_path: &str) {
    use std::{path::Path, sync::OnceLock};
    use tracing_appender::{non_blocking::WorkerGuard, rolling::Rotation};
    use tracing_subscriber::prelude::*;

    static INITIALIZE: Once = Once::new();
    static FILE_WRITER_GUARD: OnceLock<WorkerGuard> = OnceLock::new();
    INITIALIZE.call_once(|| {
        let oslog = tracing_oslog::OsLogger::new("com.ken.TravelCompanion", "RustCore");
        let log_directory = Path::new(storage_path)
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("Logs");
        let file_appender = tracing_appender::rolling::RollingFileAppender::builder()
            .rotation(Rotation::DAILY)
            .filename_prefix("travel-core.log")
            .max_log_files(7)
            .build(log_directory);

        match file_appender {
            Ok(file_appender) => {
                let (file_writer, guard) = tracing_appender::non_blocking(file_appender);
                let file_layer = tracing_subscriber::fmt::layer()
                    .with_ansi(false)
                    .with_file(true)
                    .with_line_number(true)
                    .with_target(true)
                    .with_writer(file_writer);
                let subscriber = tracing_subscriber::registry().with(oslog).with(file_layer);
                if tracing::subscriber::set_global_default(subscriber).is_ok() {
                    let _ = FILE_WRITER_GUARD.set(guard);
                }
            }
            Err(error) => {
                let subscriber = tracing_subscriber::registry().with(oslog);
                let _ = tracing::subscriber::set_global_default(subscriber);
                tracing::error!(%error, "failed to initialize rolling file logging");
            }
        }
    });
}

#[cfg(not(target_vendor = "apple"))]
pub(crate) fn initialize(_storage_path: &str) {
    static INITIALIZE: Once = Once::new();
    INITIALIZE.call_once(|| {});
}
