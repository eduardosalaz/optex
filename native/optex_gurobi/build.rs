//! Locate and link the installed Gurobi library. The lib name embeds the
//! version (gurobi130.lib / libgurobi130.so), so it is discovered by scanning
//! GUROBI_HOME/lib rather than hardcoded (pattern borrowed from grb-sys2).
//! This crate is only compiled when the Elixir side detects GUROBI_HOME.

use std::{env, fs, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=GUROBI_HOME");

    let home = env::var("GUROBI_HOME")
        .expect("GUROBI_HOME must be set to the Gurobi install dir to build optex_gurobi");
    let lib_dir = PathBuf::from(&home).join("lib");

    let mut libname = None;

    for entry in fs::read_dir(&lib_dir).expect("cannot read GUROBI_HOME/lib") {
        let name = entry.unwrap().file_name().into_string().unwrap_or_default();

        let version = if cfg!(windows) {
            name.strip_prefix("gurobi")
                .and_then(|s| s.strip_suffix(".lib"))
        } else {
            name.strip_prefix("libgurobi")
                .and_then(|s| s.strip_suffix(".so"))
        };

        if let Some(v) = version {
            if !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit()) {
                libname = Some(format!("gurobi{v}"));
                break;
            }
        }
    }

    let libname = libname.expect("no gurobi<version> library found in GUROBI_HOME/lib");
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=dylib={libname}");
}
