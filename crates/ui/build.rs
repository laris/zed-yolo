#![allow(clippy::disallowed_methods, reason = "build scripts are exempt")]

fn main() {
    println!("cargo::rustc-check-cfg=cfg(macos_sdk_26_or_later)");
    println!("cargo:rerun-if-env-changed=SDKROOT");

    // `cfg!(target_os)` would describe the build host here. The SDK query has
    // to run whenever the *target* is macOS, including Linux cross-builds,
    // where `xcrun` is the SDKROOT-backed shim from .cnb/Dockerfile.zed-macos.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }

    let sdk_version = std::process::Command::new("xcrun")
        .args(["--sdk", "macosx", "--show-sdk-version"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok());

    let major_version: Option<u32> = sdk_version
        .as_deref()
        .and_then(|version| version.trim().split('.').next())
        .and_then(|major| major.parse().ok());

    if let Some(major) = major_version
        && major >= 26
    {
        println!("cargo:rustc-cfg=macos_sdk_26_or_later");
    }
}
