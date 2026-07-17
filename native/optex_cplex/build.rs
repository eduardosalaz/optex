//! Locate and link the installed CPLEX Callable Library. The install root
//! comes from the CPLEX_STUDIO_DIR* env var the installer sets (versioned,
//! e.g. CPLEX_STUDIO_DIR2211); the static library name embeds the version
//! (cplex2211.lib), so it is discovered by scanning. This crate is only
//! compiled when the Elixir side detects such a variable.

use std::{env, fs, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=CPLEX_STUDIO_DIR2211");

    let root = env::vars()
        .find(|(k, _)| k.starts_with("CPLEX_STUDIO_DIR"))
        .map(|(_, v)| v)
        .expect("a CPLEX_STUDIO_DIR* env var must be set to build optex_cplex");

    // stat_mda: static library built against the DLL multithreaded runtime,
    // which is what Rust's MSVC target uses (/MD)
    let lib_dir = if cfg!(windows) {
        PathBuf::from(&root)
            .join("cplex")
            .join("lib")
            .join("x64_windows_msvc14")
            .join("stat_mda")
    } else {
        PathBuf::from(&root)
            .join("cplex")
            .join("lib")
            .join("x86-64_linux")
            .join("static_pic")
    };

    let mut libname = None;

    for entry in fs::read_dir(&lib_dir).expect("cannot read the CPLEX lib dir") {
        let name = entry.unwrap().file_name().into_string().unwrap_or_default();

        let version = if cfg!(windows) {
            name.strip_prefix("cplex").and_then(|s| s.strip_suffix(".lib"))
        } else {
            name.strip_prefix("libcplex").and_then(|s| s.strip_suffix(".a"))
        };

        if let Some(v) = version {
            if v.bytes().all(|b| b.is_ascii_digit()) {
                libname = Some(format!("cplex{v}"));
                break;
            }
        }
    }

    let libname = libname.expect("no cplex<version> static library found");
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static={libname}");

    if !cfg!(windows) {
        println!("cargo:rustc-link-lib=dylib=m");
        println!("cargo:rustc-link-lib=dylib=pthread");
        println!("cargo:rustc-link-lib=dylib=dl");
    }
}
