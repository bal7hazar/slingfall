"""encoding: the hashes of the Atlantic + Integrity round trip (lot E3a). Python 3 standard library.

The chain, from our run to the fact a Starknet contract reads (`docs/proving.md` "Atlantic +
Integrity"; every step matched against Atlantic's `metadata.json` and the chain on 2026-09-26):

1. `task_output(outputs, args)`: the public output of `cairo1-run --append_return_values` on
   `tools/atlantic/c1main`: `[0 (panic flag), len(outputs), outputs..., len(args), args...]`.
2. `program_hash_pedersen(builtins, main, data)`: the hash the bootloader gives the task (cairo-lang
   `compute_program_hash_chain`, Pedersen): Atlantic's `child_program_hash`.
3. `atlantic_output(child, task)`: Atlantic's bootloader output, `[0, pedersen(0, 0), 1, len(task) + 2,
   child, task...]` (the first two felts are the bootloader's configuration, constant).
4. `sharp_fact_hash(bootloader, output)` = `keccak(bootloader || keccak(output))` (32-byte big-endian
   words): the L1 SHARP fact, bridged to Starknet's Satellite (`sharpFactHash`).
5. `translated_fact_hash(bootloader, output)` = `bootloaded_fact_hash(SHARP_BOOTLOADER_PROGRAM_HASH,
   bootloader, output)`: the Poseidon fact the Satellite registers from the keccak one
   (`translateFactHash`, Atlantic's `integrityFactHash`).

Also: `fact_hash` / `bootloaded_fact_hash` (Integrity `src/lib_utils.cairo`), `verification_hash` /
`verifier_config_hash` (the registry's keys), `selector` (`starknet_keccak`), `keccak256` (Keccak, not
`hashlib.sha3_256`), `pedersen` (STARK curve), `decode_verifications` (the registry's answer).
Poseidon is `tools/levelc/poseidon.py` (`hash_span` = `poseidon_hash_span` = `PoseidonImpl` chain).
"""

from __future__ import annotations

import json
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "levelc"))
import poseidon  # noqa: E402

P = poseidon.P

# Integrity `src/lib_utils.cairo` (main, 2026-09-26).
SHARP_BOOTLOADER_PROGRAM_HASH = 0x5AB580B04E3532B6B18F81CFA654A05E29DD8E2352D88DF1E765A84072DB07
STONE_BOOTLOADER_PROGRAM_HASH = 0x40519557C48B25E7E7D27CB27297300B94909028C327B385990F0B649920CC3
# Atlantic's bootloader (`metadata.json` `program_hash` of every query of 2026-09-26, Stwo lane).
ATLANTIC_BOOTLOADER_PROGRAM_HASH = 0x288BA12915C0C7E91DF572CF3ED0C9F391AA673CB247C5A208BEAA50B668F09


def poseidon_many(felts: list[int]) -> int:
    return poseidon.hash_span([x % P for x in felts])


def fact_hash(program_hash: int, output: list[int]) -> int:
    return poseidon_many([program_hash, poseidon_many(output)])


def bootloader_output(child_program_hash: int, child_output: list[int]) -> list[int]:
    """The simple bootloader's public output for one task."""
    return [1, len(child_output) + 2, child_program_hash, *child_output]


def bootloaded_fact_hash(bootloader_program_hash: int, child_program_hash: int, child_output: list[int]) -> int:
    return fact_hash(bootloader_program_hash, bootloader_output(child_program_hash, child_output))


# --------------------------------------------------------------------------- the Atlantic chain

def task_output(outputs: list[int], args: list[int]) -> list[int]:
    return [0, len(outputs), *outputs, len(args), *args]


def atlantic_output(child_program_hash: int, task: list[int]) -> list[int]:
    return [0, pedersen(0, 0), *bootloader_output(child_program_hash, task)]


def sharp_fact_hash(program_hash: int, output: list[int]) -> int:
    words = lambda xs: b"".join((x % P).to_bytes(32, "big") for x in xs)  # noqa: E731
    return int.from_bytes(keccak256(words([program_hash]) + keccak256(words(output))), "big")


def translated_fact_hash(program_hash: int, output: list[int]) -> int:
    return bootloaded_fact_hash(SHARP_BOOTLOADER_PROGRAM_HASH, program_hash, output)


def run_output(child_program_hash: int, outputs: list[int], args: list[int]) -> list[int]:
    """Atlantic's public output of one proven run of `c1main` (its 10 outputs, its argument felts):
    what `translateFactHash` re-derives both facts from."""
    return atlantic_output(child_program_hash, task_output(outputs, args))


def slingfall_fact(child_program_hash: int, outputs: list[int], args: list[int]) -> dict[str, int]:
    """The facts of one proven run of `c1main` (its 10 outputs, its argument felts)."""
    out = run_output(child_program_hash, outputs, args)
    return {"sharp_fact_hash": sharp_fact_hash(ATLANTIC_BOOTLOADER_PROGRAM_HASH, out),
            "integrity_fact_hash": translated_fact_hash(ATLANTIC_BOOTLOADER_PROGRAM_HASH, out)}


# --------------------------------------------------------------------------- program hashes

def _program_chain(builtins: list[str], main: int, data: list[int], bootloader_version: int) -> list[int]:
    return [bootloader_version, main, len(builtins), *(short_string(b) for b in builtins), *data]


def program_hash(builtins: list[str], main: int, data: list[int], bootloader_version: int = 0) -> int:
    """cairo-lang `compute_program_hash_chain`, Poseidon variant: `poseidon(header..., data...)`."""
    return poseidon_many(_program_chain(builtins, main, data, bootloader_version))


def program_hash_pedersen(builtins: list[str], main: int, data: list[int], bootloader_version: int = 0) -> int:
    """cairo-lang `compute_program_hash_chain`, Pedersen variant (what Atlantic's bootloader uses):
    `compute_hash_chain([len(chain), *chain])` with `chain = [version, main, n_builtins, builtins...,
    data...]`, i.e. `h(x0, h(x1, ... h(x_{n-2}, x_{n-1})))`."""
    chain = _program_chain(builtins, main, data, bootloader_version)
    return pedersen_hash_chain([len(chain), *chain])


def pie_program(pie_zip: str) -> tuple[list[str], int, list[int]]:
    """(builtins, main, data) of a Cairo PIE's program (`metadata.json`)."""
    program = json.loads(zipfile.ZipFile(pie_zip).read("metadata.json"))["program"]
    data = [int(x, 0) if isinstance(x, str) else int(x) for x in program["data"]]
    return list(program["builtins"]), int(program["main"]), data


# --------------------------------------------------------------------------- Pedersen

# starkware `crypto/signature/pedersen_params.json`: the STARK curve y^2 = x^3 + x + B and the
# shift point P0 and the four generators P1..P4 of `pedersen_hash`.
_B = 0x6F21413EFBE40DE150E596D72F7A8C5609AD26C15C915C1F4CDFCB99CEE9E89
_POINTS = [
    (0x49EE3EBA8C1600700EE1B87EB599F16716B0B1022947733551FDE4050CA6804,
     0x3CA0CFE4B3BC6DDF346D49D06EA0ED34E621062C0E056C1D0405D266E10268A),
    (0x234287DCBAFFE7F969C748655FCA9E58FA8120B6D56EB0C1080D17957EBE47B,
     0x3B056F100F96FB21E889527D41F4E39940135DD7A6C94CC6ED0268EE89E5615),
    (0x4FA56F376C83DB33F9DAB2656558F3399099EC1DE5E3018B7A6932DBA8AA378,
     0x3FA0984C931C9E38113E0C0E47E4401562761F92A7A23B45168F4E80FF5B54D),
    (0x4BA4CC166BE8DEC764910F75B45F74B40C690C74709E90F3AA372F0BD2D6997,
     0x40301CF5C1751F4B971E46C4EDE85FCAC5C59A5CE5AE7C48151F27B24B219C),
    (0x54302DCB0E6CC1C6E44CCA8F61A63BB2CA65048D53FB325D36FF12C49A58202,
     0x1B77B3E37D13504B348046268D8AE25CE98AD783C25561A879DCC77E99C2426),
]
_WINDOW = 8
_TABLES: list[list[list[tuple[int, int] | None]]] = []


def _on_curve(pt: tuple[int, int]) -> bool:
    x, y = pt
    return (y * y - (x * x * x + x + _B)) % P == 0


def _affine_add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    (x1, y1), (x2, y2) = a, b
    if x1 == x2:
        if (y1 + y2) % P == 0:
            return None
        lam = (3 * x1 * x1 + 1) * pow(2 * y1, -1, P) % P
    else:
        lam = (y2 - y1) * pow(x2 - x1, -1, P) % P
    x3 = (lam * lam - x1 - x2) % P
    return x3, (lam * (x1 - x3) - y1) % P


def _jac_add_affine(acc, pt):
    """Jacobian `acc` + affine `pt` (either may be None = infinity)."""
    if pt is None:
        return acc
    if acc is None:
        return (pt[0], pt[1], 1)
    X1, Y1, Z1 = acc
    x2, y2 = pt
    z1z1 = Z1 * Z1 % P
    u2 = x2 * z1z1 % P
    s2 = y2 * Z1 * z1z1 % P
    h = (u2 - X1) % P
    r = (s2 - Y1) % P
    if h == 0:
        if r != 0:
            return None
        return _jac_double(acc)
    hh = h * h % P
    hhh = h * hh % P
    v = X1 * hh % P
    X3 = (r * r - hhh - 2 * v) % P
    Y3 = (r * (v - X3) - Y1 * hhh) % P
    return X3, Y3, Z1 * h % P


def _jac_double(acc):
    X1, Y1, Z1 = acc
    if Y1 == 0:
        return None
    yy = Y1 * Y1 % P
    s = 4 * X1 * yy % P
    z4 = pow(Z1, 4, P)
    m = (3 * X1 * X1 + z4) % P
    X3 = (m * m - 2 * s) % P
    return X3, (m * (s - X3) - 8 * yy * yy) % P, 2 * Y1 * Z1 % P


def _tables() -> list[list[list[tuple[int, int] | None]]]:
    """Per generator P1..P4, per 8-bit window w, the multiples k * 2^(8w) * P for k < 256."""
    if not _TABLES:
        for gen, bits in ((_POINTS[1], 248), (_POINTS[2], 4), (_POINTS[3], 248), (_POINTS[4], 4)):
            windows = []
            base = gen
            for _ in range((bits + _WINDOW - 1) // _WINDOW):
                row = [None]
                for _k in range(1, 1 << _WINDOW):
                    row.append(_affine_add(row[-1], base))
                windows.append(row)
                base = _affine_add(row[-1], base)  # 256 * base
            _TABLES.append(windows)
    return _TABLES


def pedersen(x: int, y: int) -> int:
    """starkware `pedersen_hash(x, y)`: `(P0 + x_low P1 + x_high P2 + y_low P3 + y_high P4).x`,
    `low` the 248 low bits, `high` the 4 high bits."""
    tables = _tables()
    acc = (_POINTS[0][0], _POINTS[0][1], 1)
    mask = (1 << 248) - 1
    for value, (t_low, t_high) in ((x % P, (tables[0], tables[1])), (y % P, (tables[2], tables[3]))):
        for part, table in ((value & mask, t_low), (value >> 248, t_high)):
            w = 0
            while part:
                acc = _jac_add_affine(acc, table[w][part & 0xFF])
                part >>= _WINDOW
                w += 1
    X, _, Z = acc
    return X * pow(Z * Z, -1, P) % P


def pedersen_hash_chain(data: list[int]) -> int:
    """cairo-lang `compute_hash_chain`: `h(d0, h(d1, ... h(d_{n-2}, d_{n-1})))`."""
    acc = data[-1]
    for value in reversed(data[:-1]):
        acc = pedersen(value, acc)
    return acc


# --------------------------------------------------------------------------- strings, registry

def short_string(text: str) -> int:
    """Cairo short string (`'recursive'`) as a felt."""
    data = text.encode("ascii")
    if len(data) > 31:
        raise ValueError(f"short string longer than 31 bytes: {text!r}")
    return int.from_bytes(data, "big")


def decode_short_string(felt: int) -> str:
    data = felt.to_bytes(32, "big").lstrip(b"\0")
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        return hex(felt)
    return text if text and text.isprintable() else hex(felt)


def verifier_config_hash(layout: str, hasher: str, stone_version: str, memory_verification: str) -> int:
    return poseidon_many([short_string(s) for s in (layout, hasher, stone_version, memory_verification)])


def verification_hash(fact: int, config_hash: int, security_bits: int) -> int:
    return poseidon_many([fact, config_hash, security_bits])


def decode_verifications(felts: list[int]) -> list[dict]:
    """`Array<VerificationListElement>` / `Span<..>` (Serde: length, then per element
    `verification_hash, security_bits, layout, hasher, stone_version, memory_verification`)."""
    if not felts:
        raise ValueError("empty answer")
    n, rest = felts[0], felts[1:]
    if len(rest) != 6 * n:
        raise ValueError(f"expected {6 * n} felts for {n} verifications, got {len(rest)}")
    out = []
    for i in range(n):
        vh, bits, layout, hasher, stone, memory = rest[6 * i : 6 * i + 6]
        out.append({
            "verification_hash": hex(vh),
            "security_bits": bits,
            "layout": decode_short_string(layout),
            "hasher": decode_short_string(hasher),
            "stone_version": decode_short_string(stone),
            "memory_verification": decode_short_string(memory),
        })
    return out


# --------------------------------------------------------------------------- Keccak-256

_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [
    [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]
_MASK = (1 << 64) - 1


def _rol(x: int, n: int) -> int:
    return ((x << n) | (x >> (64 - n))) & _MASK if n else x


def _keccak_f(a: list[list[int]]) -> None:
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                a[x][y] ^= d[x]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
        for x in range(5):
            for y in range(5):
                a[x][y] = b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y])
        a[0][0] ^= rc


def keccak256(data: bytes) -> bytes:
    rate = 136
    msg = bytearray(data) + b"\x01" + b"\0" * ((-len(data) - 1) % rate)
    msg[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        block = msg[off : off + rate]
        for i in range(rate // 8):
            a[i % 5][i // 5] ^= int.from_bytes(block[8 * i : 8 * i + 8], "little")
        _keccak_f(a)
    return b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(4))


def selector(name: str) -> int:
    """`starknet_keccak`: Keccak-256 of the name, masked to 250 bits."""
    return int.from_bytes(keccak256(name.encode("ascii")), "big") & ((1 << 250) - 1)
