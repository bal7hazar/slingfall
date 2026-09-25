//! Slingfall game rules on `rapier2d`: the world built from a `Level`, the slingshot, damage from
//! contact-force events, the end-of-shot calm rule, scoring and win (`docs/DESIGN.md` D2-D7).
//! Modules are pre-declared by the orchestrator (`docs/PLAN.md`, lot G3).

pub mod calm;
pub mod damage;
pub mod score;
pub mod sling;
pub mod world;

#[cfg(test)]
mod tests {
    use rapier2d::prelude::{Fixed, IntegrationParameters, Vec2, WORLD_STATE_VERSION, WorldTrait};
    use slingfall_testing::opaque;

    /// Empty probe: the fixed overhead snforge charges to any test in this crate.
    #[test]
    fn steps_baseline() {}

    /// `rapier2d` links: a world is built through the public prelude, keeps its gravity, and the
    /// `WorldState` layout is the one the chunked replay is written against.
    #[test]
    fn test_rapier2d_world_builds() {
        let gravity = Vec2 { x: Fixed { raw: 0 }, y: opaque(Fixed { raw: -0xa00000000 }) };
        let params: IntegrationParameters = Default::default();
        let world = WorldTrait::new(gravity, params);
        assert_eq!(world.gravity.y.raw, -0xa00000000);
        assert_eq!(WORLD_STATE_VERSION, 1);
    }
}
