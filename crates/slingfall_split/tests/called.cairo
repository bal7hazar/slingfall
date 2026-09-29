//! Which of `rapier2d_classes`' classes the game's layouts library-call, by measurement (lot H3):
//! the reference shot's whole chain (`chain::play_chain`) with one class left undeclared; a class
//! the shot calls makes its library call fail, hence the chain panic. Layout (e) is `WorldClass`,
//! the fallback (b) is `FallbackGame`. The result is `classes.json`'s list
//! (`scripts/classes.py`); the default chain tests run with exactly that list declared, so a class
//! outside it (`ContactPolygonClass` since alpha.8, `SolverClass`, `ForceEventsClass`) is never
//! declared and its `test_called_*` passes: the shot does not call it.

use crate::chain::play_chain_except;

fn e(skip: ByteArray) {
    play_chain_except("WorldClass", "reference", array![90, 17].span(), @skip);
}

fn b(skip: ByteArray) {
    play_chain_except("FallbackGame", "reference", array![50, 30, 10, 17].span(), @skip);
}

#[test]
#[ignore]
fn test_called_e_contact_ball() {
    e("ContactBallClass");
}

#[test]
#[ignore]
fn test_called_b_contact_ball() {
    b("ContactBallClass");
}

#[test]
#[ignore]
fn test_called_e_contact_polygon() {
    e("ContactPolygonClass");
}

#[test]
#[ignore]
fn test_called_b_contact_polygon() {
    b("ContactPolygonClass");
}

#[test]
#[ignore]
fn test_called_e_solver() {
    e("SolverClass");
}

#[test]
#[ignore]
fn test_called_b_solver() {
    b("SolverClass");
}

#[test]
#[ignore]
fn test_called_e_solve_advance() {
    e("SolveAdvanceClass");
}

#[test]
#[ignore]
fn test_called_b_solve_advance() {
    b("SolveAdvanceClass");
}

#[test]
#[ignore]
fn test_called_e_islands() {
    e("IslandsClass");
}

#[test]
#[ignore]
fn test_called_b_islands() {
    b("IslandsClass");
}

#[test]
#[ignore]
fn test_called_e_broad_phase() {
    e("BroadPhaseClass");
}

#[test]
#[ignore]
fn test_called_b_broad_phase() {
    b("BroadPhaseClass");
}

#[test]
#[ignore]
fn test_called_e_mass() {
    e("MassClass");
}

#[test]
#[ignore]
fn test_called_b_mass() {
    b("MassClass");
}

#[test]
#[ignore]
fn test_called_e_narrow_phase() {
    e("NarrowPhaseClass");
}

#[test]
#[ignore]
fn test_called_b_narrow_phase() {
    b("NarrowPhaseClass");
}

#[test]
#[ignore]
fn test_called_e_active_set() {
    e("ActiveSetClass");
}

#[test]
#[ignore]
fn test_called_b_active_set() {
    b("ActiveSetClass");
}

#[test]
#[ignore]
fn test_called_e_force_events() {
    e("ForceEventsClass");
}

#[test]
#[ignore]
fn test_called_b_force_events() {
    b("ForceEventsClass");
}

#[test]
#[ignore]
fn test_called_e_world_edit() {
    e("WorldEditClass");
}

#[test]
#[ignore]
fn test_called_b_world_edit() {
    b("WorldEditClass");
}
