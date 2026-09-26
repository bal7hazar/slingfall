//! Level registry and per-player records (`docs/DESIGN.md` D9): the stored types of the contract,
//! the rule that decides whether an attempt improves a record, and the top-10 leaderboard kept by
//! insertion. The storage and entry points are in `submit::Slingfall`.

use starknet::ContractAddress;

/// Number of entries kept in a level's leaderboard.
pub const LEADERBOARD_SIZE: usize = 10;

/// A registered level. `version` is the level's format version (`LEVEL_VERSION`, never 0 once
/// registered): `version == 0` means "not registered".
#[derive(Copy, Drop, Serde, PartialEq, Debug, starknet::Store)]
pub struct LevelMeta {
    pub author: ContractAddress,
    pub version: u16,
    /// Inactive levels refuse submissions; the author or the admin toggles it.
    pub active: bool,
    /// Block timestamp of the registration.
    pub registered_at: u64,
}

/// A player's best validated attempt on a level (all zero when there is none).
#[derive(Copy, Drop, Serde, PartialEq, Debug, starknet::Store)]
pub struct Record {
    pub score: u32,
    pub won: bool,
    pub inputs_hash: felt252,
    /// Block number of the submission.
    pub block: u64,
    /// Validated by the Satellite fact (`submit_settled`), else provisional (an attestation).
    pub settled: bool,
}

/// One leaderboard row.
#[derive(Copy, Drop, Serde, PartialEq, Debug, starknet::Store)]
pub struct Entry {
    pub player: ContractAddress,
    pub score: u32,
}

/// `(won, score)` beats the stored record: a won attempt beats any lost one, then the higher
/// score wins; a tie keeps the stored record.
pub fn improves(record: @Record, won: bool, score: u32) -> bool {
    if won != *record.won {
        return won;
    }
    score > *record.score
}

/// The leaderboard after `player` reaches `score` on a won attempt: the player's previous row is
/// dropped, the new row goes after every row with a score `>=` (earlier rows keep ties), and the
/// board is cut to `LEADERBOARD_SIZE`. `board` is sorted by decreasing score.
pub fn insert(board: Span<Entry>, player: ContractAddress, score: u32) -> Array<Entry> {
    let mut result: Array<Entry> = array![];
    let mut placed = false;
    for entry in board {
        let entry = *entry;
        if entry.player == player {
            continue;
        }
        if !placed && score > entry.score {
            result.append(Entry { player, score });
            placed = true;
        }
        result.append(entry);
    }
    if !placed {
        result.append(Entry { player, score });
    }
    if result.len() <= LEADERBOARD_SIZE {
        return result;
    }
    let mut cut: Array<Entry> = array![];
    cut.append_span(result.span().slice(0, LEADERBOARD_SIZE));
    cut
}

#[cfg(test)]
mod tests {
    use slingfall_testing::opaque;
    use starknet::ContractAddress;
    use super::{Entry, LEADERBOARD_SIZE, Record, improves, insert};

    fn address(value: felt252) -> ContractAddress {
        value.try_into().unwrap()
    }

    fn entry(player: felt252, score: u32) -> Entry {
        Entry { player: address(player), score }
    }

    /// `(player, score)` pairs of a board.
    fn rows(board: Array<Entry>) -> Array<(felt252, u32)> {
        let mut rows = array![];
        for entry in board {
            rows.append((entry.player.into(), entry.score));
        }
        rows
    }

    #[test]
    fn test_improves() {
        let lost_100 = Record { score: 100, won: false, inputs_hash: 0, block: 0, settled: false };
        let won_100 = Record { score: 100, won: true, inputs_hash: 0, block: 0, settled: false };
        let none: Record = Record {
            score: 0, won: false, inputs_hash: 0, block: 0, settled: false,
        };
        // (record, won, score, expected).
        let cases: Array<(Record, bool, u32, bool)> = array![
            (none, false, 0, false), (none, false, 1, true), (none, true, 0, true),
            (lost_100, false, 100, false), (lost_100, false, 99, false),
            (lost_100, false, 101, true), (lost_100, true, 1, true), (won_100, false, 1000, false),
            (won_100, true, 100, false), (won_100, true, 101, true),
        ];
        for (record, won, score, expected) in cases {
            assert_eq!(improves(@record, won, score), expected);
        }
    }

    #[test]
    fn test_insert_orders_by_score_ties_keep_the_earlier_row() {
        let board = insert(array![].span(), address(1), 50);
        let board = insert(board.span(), address(2), 70);
        let board = insert(board.span(), address(3), 50);
        let board = insert(board.span(), address(4), 60);
        assert_eq!(rows(board), array![(2, 70), (4, 60), (1, 50), (3, 50)]);
    }

    #[test]
    fn test_insert_moves_an_improving_player() {
        let board = array![entry(1, 90), entry(2, 80), entry(3, 70)];
        assert_eq!(rows(insert(board.span(), address(3), 85)), array![(1, 90), (3, 85), (2, 80)]);
        assert_eq!(rows(insert(board.span(), address(2), 95)), array![(2, 95), (1, 90), (3, 70)]);
        assert_eq!(rows(insert(board.span(), address(1), 91)), array![(1, 91), (2, 80), (3, 70)]);
    }

    #[test]
    fn test_insert_keeps_the_top_ten() {
        let mut board = array![];
        for i in 0..LEADERBOARD_SIZE {
            let score: u32 = (100 - 10 * i).try_into().unwrap();
            board.append(entry((i + 1).into(), score));
        }
        // Below the last row: not kept.
        let same = insert(board.span(), address(99), 5);
        assert_eq!(same.len(), LEADERBOARD_SIZE);
        assert_eq!(*same[LEADERBOARD_SIZE - 1], entry(10, 10));
        // Equal to the last row: the earlier row keeps its place.
        assert_eq!(insert(board.span(), address(99), 10), board);
        // Above the last row: the last row is dropped.
        let pushed = insert(board.span(), address(99), 55);
        assert_eq!(pushed.len(), LEADERBOARD_SIZE);
        assert_eq!(*pushed[5], entry(99, 55));
        assert_eq!(*pushed[LEADERBOARD_SIZE - 1], entry(9, 20));
    }

    #[test]
    fn steps_leaderboard_insert__full_board() {
        let mut board = array![];
        for i in 0..LEADERBOARD_SIZE {
            let score: u32 = (100 - 10 * i).try_into().unwrap();
            board.append(entry((i + 1).into(), score));
        }
        let board = opaque(board);
        opaque(insert(board.span(), opaque(address(99)), opaque(55)));
    }
}
