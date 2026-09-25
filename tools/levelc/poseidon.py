"""Starknet Poseidon (Hades permutation, state 3, rate 2) and `poseidon_hash_span`, stdlib only.

Round constants are derived as in the reference parameters: SHA-256 of `"Hades" + index` read as a
big-endian integer, modulo the field prime, for index `3 * round + lane`. 8 full rounds (4 + 4)
around 83 partial rounds; the linear layer is `[[3, 1, 1], [1, -1, 1], [1, 1, -2]]`.
`levelc.py` results are checked against Cairo's `poseidon_hash_span` by the golden hashes of the
level crate's tests (`fixtures/levels/*.felts.json`).
"""

from __future__ import annotations

from hashlib import sha256

P = 2**251 + 17 * 2**192 + 1
FULL_ROUNDS = 8
PARTIAL_ROUNDS = 83
ROUNDS = FULL_ROUNDS + PARTIAL_ROUNDS
ROUND_CONSTANTS = [
    [int.from_bytes(sha256(f"Hades{3 * r + i}".encode("ascii")).digest(), "big") % P for i in range(3)]
    for r in range(ROUNDS)
]


def _mix(s: list[int]) -> list[int]:
    a, b, c = s
    return [(3 * a + b + c) % P, (a - b + c) % P, (a + b - 2 * c) % P]


def permute(state: list[int]) -> list[int]:
    s = list(state)
    for r in range(ROUNDS):
        s = [(x + k) % P for x, k in zip(s, ROUND_CONSTANTS[r])]
        if r < FULL_ROUNDS // 2 or r >= FULL_ROUNDS // 2 + PARTIAL_ROUNDS:
            s = [pow(x, 3, P) for x in s]
        else:
            s[2] = pow(s[2], 3, P)
        s = _mix(s)
    return s


def hash_span(felts: list[int]) -> int:
    """`core::poseidon::poseidon_hash_span`."""
    s = [0, 0, 0]
    items = list(felts)
    while len(items) >= 2:
        a, b = items.pop(0), items.pop(0)
        s = permute([(s[0] + a) % P, (s[1] + b) % P, s[2]])
    if items:
        s = permute([(s[0] + items[0]) % P, (s[1] + 1) % P, s[2]])
    else:
        s = permute([(s[0] + 1) % P, s[1], s[2]])
    return s[0]
