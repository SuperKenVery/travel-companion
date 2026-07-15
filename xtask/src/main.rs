//! Repository build orchestration. Run as `cargo run -p xtask -- <command>` from
//! the Nix dev shell.

use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

fn main() -> ExitCode {
    if env::var_os("TC_NIX_DEVSHELL").as_deref() != Some(std::ffi::OsStr::new("1")) {
        eprintln!("xtask must run inside this repository's `nix develop` devShell");
        return ExitCode::FAILURE;
    }
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("xtask lives below workspace root")
        .to_path_buf();
    let command = env::args().nth(1).unwrap_or_else(|| "help".into());
    let result = match command.as_str() {
        "fmt" => run(&root, "cargo", &["fmt", "--all", "--", "--check"]),
        "check" => run(&root, "cargo", &["check", "--workspace", "--all-targets"]),
        "test" => run(&root, "cargo", &["test", "--workspace"]),
        // iPhoneOS builds must use the host Xcode SDK/clang selected by the
        // repository wrapper; invoking cross-target Cargo directly would
        // inherit the devShell's macOS SDK and pkg-config paths.
        "ios" => run(&root, "./scripts/build-rust-ios.sh", &["Release"]),
        "all" => run(&root, "./scripts/check.sh", &[])
            .and_then(|()| run(&root, "./scripts/build-rust-ios.sh", &["Release"])),
        _ => {
            eprintln!(
                "usage: cargo run -p xtask -- <fmt|check|test|ios|all>\n\
                 all commands must run inside `nix develop`"
            );
            Ok(())
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("xtask failed: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(root: &Path, program: &str, arguments: &[&str]) -> Result<(), String> {
    let status = Command::new(program)
        .args(arguments)
        .current_dir(root)
        .status()
        .map_err(|error| format!("could not start {program}: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "{program} {} exited with {status}",
            arguments.join(" ")
        ))
    }
}
