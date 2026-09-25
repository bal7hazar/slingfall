//! Scoring and win condition (`docs/DESIGN.md` D7). Lot G3.
//!
//! A destroyed block or core scores its material's `score` (the level carries the D7 values below
//! in its materials); every shot left when the level is won scores `UNUSED_SHOT`. Integer `u32`.

use slingfall_level::level::Material;
use crate::world::Game;

/// D7 score of a destroyed timber block.
pub const TIMBER: u32 = 50;
/// D7 score of a destroyed frost block.
pub const FROST: u32 = 100;
/// D7 score of a destroyed slate block.
pub const SLATE: u32 = 150;
/// D7 score of a destroyed core.
pub const CORE: u32 = 1_000;
/// D7 score of each shot left when the level is won.
pub const UNUSED_SHOT: u32 = 2_000;

/// A block or core of `material` was destroyed (by damage or by leaving the bounds).
pub fn on_destroyed(ref game: Game, material: @Material) {
    game.score += *material.score;
}

/// The level was won with `shots_left` shots unused: `UNUSED_SHOT` each. Called once, at the end
/// of the winning shot (`GameTrait::play_shot`).
pub fn on_win(ref game: Game, shots_left: u8) {
    let shots_left: u32 = shots_left.into();
    game.score += shots_left * UNUSED_SHOT;
}

/// Every core is destroyed (checked after each tick).
pub fn won(game: @Game) -> bool {
    *game.cores_left == 0
}

#[cfg(test)]
mod tests {
    use slingfall_level::level::LevelTrait;
    use crate::world::GameTrait;
    use crate::world::fixtures::pile10;
    use super::{CORE, FROST, SLATE, TIMBER, UNUSED_SHOT, on_destroyed, on_win, won};

    /// The fixture materials carry the D7 scores: timber, slate, frost, core.
    #[test]
    fn test_fixture_materials_carry_d7_scores() {
        let level = pile10();
        level.validate();
        let scores: Array<u32> = array![TIMBER, SLATE, FROST, CORE];
        let mut i = 0;
        for material in level.materials.span() {
            assert_eq!(*material.score, *scores[i]);
            i += 1;
        }
    }

    #[test]
    fn test_scoring_and_win() {
        let level = pile10();
        let mut game = GameTrait::new(@level);
        assert_eq!(game.score, 0);
        assert!(!won(@game));
        on_destroyed(ref game, level.materials[0]);
        on_destroyed(ref game, level.materials[3]);
        assert_eq!(game.score, 1_050);
        on_win(ref game, 2);
        assert_eq!(game.score, 5_050);
        on_win(ref game, 0);
        assert_eq!(game.score, 5_050);
        game.cores_left = 0;
        assert!(won(@game));
        assert_eq!(UNUSED_SHOT, 2_000);
    }
}
