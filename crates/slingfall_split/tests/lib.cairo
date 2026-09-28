//! Tests of spike S36a: the layouts against `main` (`fixtures/`, main's own chunk states from its
//! alpha.6 executables, `scripts/fixtures.py`), their Cairo steps per window, the class hashes the
//! world classes compile.

mod called;
mod chain;
mod harness;
mod hashes;
mod init;
mod ticks;
mod transactions;
mod windows_owner;
mod windows_reference;
