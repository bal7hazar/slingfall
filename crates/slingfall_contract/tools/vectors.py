#!/usr/bin/env python3
"""Golden vectors of the `slingfall_contract` tests, Python standard library only.

- `message-hash FROM TO PAYLOAD...`: the SNIP-36 message hash rule of `verifier::message_hash`,
  `poseidon_hash_span([from, to, len(payload), *payload])`.
- `pubkey SECRET`: the Stark-curve public key (x coordinate of `SECRET * G`).
- `sign SECRET FELT...`: the attestation of `verifier::StubVerifier`: `z = poseidon_hash_span(felts)`
  and a Stark-curve ECDSA signature `(r, s)` of `z`, verified here as
  `core::ecdsa::check_ecdsa_signature` does (`s * R == z * G + r * Q`).
- `golden`: prints every constant the Cairo tests pin (`src/submit/fixtures.cairo`,
  `src/verifier.cairo`).

Integers are read as decimal or `0x` hexadecimal, short strings as `'text'`. Poseidon comes from
`tools/levelc/poseidon.py` (checked against Cairo by the level crate's golden hashes). The nonce is
derived deterministically (SHA-256 of the key and the message), so the output is reproducible.
"""

from __future__ import annotations

import sys
from hashlib import sha256
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools" / "levelc"))
from poseidon import P, hash_span  # noqa: E402

# Stark curve `y^2 = x^3 + ALPHA x + BETA` over the Starknet field, its order and generator.
ALPHA = 1
BETA = 0x6F21413EFBE40DE150E596D72F7A8C5609AD26C15C915C1F4CDFCB99CEE9E89
N = 0x0800000000000010FFFFFFFFFFFFFFFFB781126DCAE7B2321E66A241ADC64D2F
G = (
    0x1EF15C18599971B7BECED415A40F0C7DEACFD9B0D1819E03D723D8BC943CFCA,
    0x5668060AA49730B7BE4801DF46EC62DE53ECD11ABE43A32873000C36E8DC1F,
)

# Constants shared with the Cairo tests.
SECRET = 0x736C696E6766616C6C  # 'slingfall': a test key, never a deployment key.
PLAYER = 0x706C61796572  # 'player'
MARKER = 0x534C494E4746414C4C  # 'SLINGFALL', `simulate::MARKER`
FROM = 0x5AFE  # contract address of the message-hash vector
PILE10_HASH = 0x1B7372774C035DDCB4F559F8A8E37E0215235D87AAB0748DE58EF2BA0C18B54
# `[version, level_hash, seed, player, inputs_hash, score, won, shots_used, ticks_run,
# final_state_hash]` of the golden claim.
OUTPUTS = [1, PILE10_HASH, 0, PLAYER, 0xABC, 1650, 1, 2, 431, 0x33]


def on_curve(p: tuple[int, int]) -> bool:
    x, y = p
    return (y * y - (x * x * x + ALPHA * x + BETA)) % P == 0


def add(p: tuple[int, int] | None, q: tuple[int, int] | None) -> tuple[int, int] | None:
    if p is None:
        return q
    if q is None:
        return p
    if p[0] == q[0]:
        if (p[1] + q[1]) % P == 0:
            return None
        lam = (3 * p[0] * p[0] + ALPHA) * pow(2 * p[1], -1, P) % P
    else:
        lam = (q[1] - p[1]) * pow(q[0] - p[0], -1, P) % P
    x = (lam * lam - p[0] - q[0]) % P
    return x, (lam * (p[0] - x) - p[1]) % P


def mul(k: int, p: tuple[int, int]) -> tuple[int, int] | None:
    acc = None
    while k:
        if k & 1:
            acc = add(acc, p)
        p = add(p, p)
        k >>= 1
    return acc


def pubkey(secret: int) -> int:
    return mul(secret, G)[0]


def verify(z: int, public_key: int, r: int, s: int) -> bool:
    """`check_ecdsa_signature`: `(z G ± r Q).x == (s R).x`, `Q.x = public_key`, `R.x = r`."""
    y_q, y_r = lift_x(public_key), lift_x(r)
    if y_q is None or y_r is None or s % N == 0:
        return False
    q = (public_key, y_q)
    s_r = mul(s, (r, y_r))
    z_g = mul(z, G)
    r_q = mul(r, q)
    minus_r_q = (r_q[0], (-r_q[1]) % P)
    return any(pt is not None and pt[0] == s_r[0] for pt in (add(z_g, r_q), add(z_g, minus_r_q)))


def lift_x(x: int) -> int | None:
    rhs = (x * x * x + ALPHA * x + BETA) % P
    y = pow(rhs, (P + 1) // 4, P) if P % 4 == 3 else tonelli(rhs)
    return y if y is not None and y * y % P == rhs else None


def tonelli(n: int) -> int | None:
    if n == 0:
        return 0
    if pow(n, (P - 1) // 2, P) != 1:
        return None
    q, s = P - 1, 0
    while q % 2 == 0:
        q, s = q // 2, s + 1
    z = 2
    while pow(z, (P - 1) // 2, P) != P - 1:
        z += 1
    m, c, t, r = s, pow(z, q, P), pow(n, q, P), pow(n, (q + 1) // 2, P)
    while t != 1:
        i, t2 = 0, t
        while t2 != 1:
            t2, i = t2 * t2 % P, i + 1
        b = pow(c, 1 << (m - i - 1), P)
        m, c, t, r = i, b * b % P, t * b * b % P, r * b % P
    return r


def sign(secret: int, z: int) -> tuple[int, int]:
    counter = 0
    while True:
        seed = f"{secret:x}:{z:x}:{counter}".encode("ascii")
        k = int.from_bytes(sha256(seed).digest(), "big") % N
        counter += 1
        if k == 0:
            continue
        r = mul(k, G)[0]
        # `check_ecdsa_signature` needs `r` itself to be the x of a curve point: `R.x < N`.
        if r >= N or r == 0:
            continue
        s = pow(k, -1, N) * (z + r * secret) % N
        if s == 0:
            continue
        return r, s


def message_hash(from_address: int, to_address: int, payload: list[int]) -> int:
    return hash_span([from_address, to_address, len(payload), *payload])


def parse(text: str) -> int:
    if text.startswith("'") and text.endswith("'"):
        return int.from_bytes(text[1:-1].encode("ascii"), "big")
    return int(text, 0) % P


def golden() -> None:
    public_key = pubkey(SECRET)
    z = hash_span(OUTPUTS)
    r, s = sign(SECRET, z)
    assert verify(z, public_key, r, s)
    print(f"ATTESTATION_KEY = {public_key:#x}")
    print(f"GOLDEN_ATTESTATION_HASH = {z:#x}")
    print(f"GOLDEN_R = {r:#x}")
    print(f"GOLDEN_S = {s:#x}")
    print(f"GOLDEN_MESSAGE_HASH = {message_hash(FROM, MARKER, OUTPUTS):#x}")


def main(argv: list[str]) -> int:
    assert on_curve(G)
    if not argv or argv[0] == "golden":
        golden()
    elif argv[0] == "message-hash" and len(argv) >= 3:
        print(hex(message_hash(parse(argv[1]), parse(argv[2]), [parse(a) for a in argv[3:]])))
    elif argv[0] == "pubkey" and len(argv) == 2:
        print(hex(pubkey(parse(argv[1]))))
    elif argv[0] == "sign" and len(argv) >= 2:
        secret = parse(argv[1])
        z = hash_span([parse(a) for a in argv[2:]])
        r, s = sign(secret, z)
        assert verify(z, pubkey(secret), r, s)
        print(f"hash {z:#x}\nr {r:#x}\ns {s:#x}")
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
