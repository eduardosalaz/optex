//! Native binding crate for Optex. Milestone 0 ships only a trivial NIF that
//! proves the Rust<->Elixir bridge loads; the real HiGHS solve NIF lands in
//! Milestone 4.

#[rustler::nif]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

rustler::init!("Elixir.Optex.Solver.HiGHS.Native");
