//! Locate and link the installed COPT (Cardinal Optimizer) library. Unlike
//! Gurobi's, the import library name is unversioned (copt.lib / libcopt.so),
//! so COPT_HOME/lib is used directly. This crate is only compiled when the
//! Elixir side detects COPT_HOME.

use std::{env, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=COPT_HOME");

    let home = env::var("COPT_HOME")
        .expect("COPT_HOME must be set to the COPT install dir to build optex_copt");
    let lib_dir = PathBuf::from(&home).join("lib");

    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=dylib=copt");
}
