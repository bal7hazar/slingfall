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

/// The v1 record (`Slingfall` v1, kept for `slingfall_sizes`' fixtures): `Best` in contract v2.
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

/// A player's best validated attempt on a level in one view (`best`: either tier; `best_settled`:
/// settled only), all zero when there is none. The v1 `Record` plus `timestamp` (what `expire`
/// measures) and `program_hash` (the engine release of the row).
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Best {
    pub score: u32,
    pub won: bool,
    pub inputs_hash: felt252,
    /// Block number of the submission.
    pub block: u64,
    /// Block timestamp of the submission.
    pub timestamp: u64,
    /// Validated by the Satellite fact (`submit_settled`), else provisional.
    pub settled: bool,
    /// The program the attempt was validated with: `c1main`'s hash (settled, and attested: the
    /// attestation names it), `SlingfallSim`'s class hash (SNIP-36).
    pub program_hash: felt252,
}

/// `Best` in storage: three felts (`score | won << 32 | settled << 33 | block << 34`, plus
/// `timestamp << 128`), `inputs_hash`, `program_hash`. Seven slots unpacked (measured:
/// `docs/contract-v2.md` "Gas").
#[derive(Copy, Drop, starknet::Store)]
pub struct PackedBest {
    meta: felt252,
    inputs_hash: felt252,
    program_hash: felt252,
}

const TWO_32: u128 = 0x100000000;
const TWO_33: u128 = 0x200000000;
const TWO_34: u128 = 0x400000000;

pub impl BestStorePacking of starknet::storage_access::StorePacking<Best, PackedBest> {
    fn pack(value: Best) -> PackedBest {
        let low: u128 = value.score.into()
            + if value.won {
                TWO_32
            } else {
                0
            }
            + if value.settled {
                TWO_33
            } else {
                0
            }
            + value.block.into() * TWO_34;
        let meta: u256 = u256 { low, high: value.timestamp.into() };
        PackedBest {
            meta: meta.try_into().unwrap(),
            inputs_hash: value.inputs_hash,
            program_hash: value.program_hash,
        }
    }

    fn unpack(value: PackedBest) -> Best {
        let meta: u256 = value.meta.into();
        let (block, flags) = DivRem::div_rem(meta.low, TWO_34.try_into().unwrap());
        let (settled, rest) = DivRem::div_rem(flags, TWO_33.try_into().unwrap());
        let (won, score) = DivRem::div_rem(rest, TWO_32.try_into().unwrap());
        Best {
            score: score.try_into().unwrap(),
            won: won != 0,
            inputs_hash: value.inputs_hash,
            block: block.try_into().unwrap(),
            timestamp: meta.high.try_into().unwrap(),
            settled: settled != 0,
            program_hash: value.program_hash,
        }
    }
}

/// `(won, score)` beats the stored best: `improves` on a `Best`.
pub fn improves_best(best: @Best, won: bool, score: u32) -> bool {
    if won != *best.won {
        return won;
    }
    score > *best.score
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

/// The leaderboard without `player`'s row (the same board when it has none).
pub fn remove(board: Span<Entry>, player: ContractAddress) -> Array<Entry> {
    let mut result: Array<Entry> = array![];
    for entry in board {
        if *entry.player != player {
            result.append(*entry);
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use slingfall_testing::opaque;
    use starknet::ContractAddress;
    use super::{
        Best, BestStorePacking, Entry, LEADERBOARD_SIZE, Record, improves, improves_best, insert,
        remove,
    };

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

    /// `improves_best` is `improves` on the same fields.
    #[test]
    fn test_improves_best_is_improves() {
        let records = array![
            Record { score: 0, won: false, inputs_hash: 0, block: 0, settled: false },
            Record { score: 100, won: false, inputs_hash: 0, block: 0, settled: false },
            Record { score: 100, won: true, inputs_hash: 0, block: 0, settled: false },
        ];
        for record in records {
            let best = Best {
                score: record.score,
                won: record.won,
                inputs_hash: 7,
                block: 1,
                timestamp: 2,
                settled: true,
                program_hash: 3,
            };
            for (won, score) in array![
                (false, 0), (false, 101), (true, 1), (true, 100), (true, 101),
            ] {
                assert_eq!(improves_best(@best, won, score), improves(@record, won, score));
            }
        }
    }

    /// Packing round-trips every field at its extremes.
    #[test]
    fn test_best_packing_round_trips() {
        let max = Best {
            score: 0xffffffff,
            won: true,
            inputs_hash: -1,
            block: 0xffffffffffffffff,
            timestamp: 0xffffffffffffffff,
            settled: true,
            program_hash: -1,
        };
        let cases = array![
            max, Best { won: false, ..max }, Best { settled: false, ..max },
            Best { score: 0, block: 0, ..max },
            Best {
                score: 1650,
                won: true,
                inputs_hash: 0xabc,
                block: 77,
                timestamp: 1_000,
                settled: false,
                program_hash: 0x12,
            },
            Best {
                score: 0,
                won: false,
                inputs_hash: 0,
                block: 0,
                timestamp: 0,
                settled: false,
                program_hash: 0,
            },
        ];
        for best in cases {
            assert_eq!(BestStorePacking::unpack(BestStorePacking::pack(best)), best);
        }
    }

    #[test]
    fn test_remove() {
        let board = array![entry(1, 90), entry(2, 80), entry(3, 70)];
        assert_eq!(rows(remove(board.span(), address(2))), array![(1, 90), (3, 70)]);
        assert_eq!(rows(remove(board.span(), address(1))), array![(2, 80), (3, 70)]);
        assert_eq!(remove(board.span(), address(9)), board);
        assert_eq!(remove(array![].span(), address(1)), array![]);
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
