"""What a stwo-cairo proof commits to, read from the proof file with the Python standard library
(lot P1, `docs/proving.md`).

A `run_and_prove --proof-format binary` file is `bzip2(bincode(CairoProofForRustVerifier))`
(stwo-cairo 467d5c6, `cairo_air::utils::binary_serialize_to_file`; bincode 1.3 defaults: fixed-size
little-endian integers, `u64` sequence lengths, `Option` = one tag byte). Its first field is
`claim.public_data.public_memory`:

    program:         Vec<(u32 id, [u32; 8] value)>   the program's bytecode cells
    public_segments: PublicSegmentRanges             output range + 10 optional builtin ranges
    output:          Vec<(u32 id, [u32; 8] value)>   the output segment = the program's output
    safe_call_ids:   [u32; 2]

A felt is 8 little-endian `u32` limbs. The program hash is stwo's
(`cairo_air::utils::get_verification_output`): Blake2s-256 over the program cells, each encoded as
2 limbs (value < 2^63) or 8 limbs with the top bit set, limbs big-endian-ordered and each written
little-endian; the digest read as a little-endian integer, reduced mod P. A JSON proof has the same
fields under `claim.public_data.public_memory`.
"""

from __future__ import annotations

import bz2
import hashlib
import json
import struct
from pathlib import Path

P = 2**251 + 17 * 2**192 + 1
MSB_U32 = 0x80000000
N_OPTIONAL_SEGMENTS = 10  # pedersen .. mul_mod in `PublicSegmentRanges`
# Felts of each replay executable's binding header (`split_public_output`).
HEADER_LEN = {"main": 0, "init": 1, "step_chunk": 4, "outputs": 2}
# `ChunkState` felts read by the chain check (`crates/slingfall_replay/README.md`).
STATE_SHOTS_USED, STATE_OVER = 1, 2


class ProofDataError(Exception):
    """The file is not a proof this module can read."""


def limbs_to_int(limbs: list[int]) -> int:
    return sum(l << (32 * i) for i, l in enumerate(limbs))


def int_to_limbs(v: int) -> list[int]:
    return [(v >> (32 * i)) & 0xFFFFFFFF for i in range(8)]


def _read_section(buf: bytes, off: int) -> tuple[list[int], int]:
    (n,) = struct.unpack_from("<Q", buf, off)
    off += 8
    if n * 36 > len(buf) - off:
        raise ProofDataError(f"memory section of {n} cells overruns the proof")
    values = []
    for _ in range(n):
        limbs = struct.unpack_from("<9I", buf, off)
        values.append(limbs_to_int(list(limbs[1:])))
        off += 36
    return values, off


def parse_binary_public_memory(buf: bytes) -> dict:
    """`program` and `output` felts of a decompressed bincode proof."""
    program, off = _read_section(buf, 0)
    off += 16  # output: SegmentRange (start_ptr, stop_ptr: MemorySmallValue {id, value})
    for _ in range(N_OPTIONAL_SEGMENTS):
        tag = buf[off]
        if tag not in (0, 1):
            raise ProofDataError(f"bad Option tag {tag} at byte {off}")
        off += 1 + 16 * tag
    output, off = _read_section(buf, off)
    return {"program": program, "output": output}


def read_public_memory(path: Path) -> dict:
    """`{"program": [felt...], "output": [felt...]}` of a binary or JSON proof file."""
    raw = Path(path).read_bytes()
    if raw[:3] == b"BZh":
        return parse_binary_public_memory(bz2.decompress(raw))
    try:
        mem = json.loads(raw)["claim"]["public_data"]["public_memory"]
    except (ValueError, KeyError) as e:
        raise ProofDataError(f"{path}: neither a binary nor a JSON proof ({e})") from e
    return {k: [limbs_to_int(v[1]) for v in mem[k]] for k in ("program", "output")}


def program_hash(program: list[int]) -> int:
    """stwo's program hash of the program cells (`encode_and_hash_memory_section`)."""
    h = hashlib.blake2s(digest_size=32)
    for v in program:
        l = int_to_limbs(v)
        if v < 2**63:
            enc = [l[1], l[0]]
        else:
            enc = [l[7] + MSB_U32, l[6], l[5], l[4], l[3], l[2], l[1], l[0]]
        h.update(struct.pack(f"<{len(enc)}I", *enc))
    return int.from_bytes(h.digest(), "little") % P


def executable_bytecode(path: Path) -> list[int]:
    """The bytecode of a scarb `*.executable.json` (what the proof's program section holds). Jump
    offsets are written negative (`-0xc`): the felt is `P - x`."""
    doc = json.loads(Path(path).read_text())
    return [(int(x, 0) if isinstance(x, str) else int(x)) % P for x in doc["program"]["bytecode"]]


def split_public_output(program: str, felts: list[int]) -> dict:
    """A replay executable's returned felts, split into its binding header and its payload (lot
    P1b, `docs/proving.md` "Chunk binding"; the Cairo `slingfall_game::chunk::*_HEADER_LEN`):

        main        outputs (10)                                        no header
        init        [level_hash] ++ state
        step_chunk  [state_in_hash, inputs_hash, shot, k] ++ state
        outputs     [state_in_hash, inputs_hash] ++ outputs (10)

    A hash is Poseidon over the felts without their length prefix; a state is its `ChunkState`
    felts."""
    if program not in HEADER_LEN:
        raise ProofDataError(f"unknown executable {program!r}")
    n = HEADER_LEN[program]
    if len(felts) < n:
        raise ProofDataError(f"{program}: {len(felts)} output felts, shorter than its {n}-felt header")
    head, body = felts[:n], felts[n:]
    if program == "init":
        return {"level_hash": head[0], "state": body}
    if program == "step_chunk":
        return {"state_in_hash": head[0], "inputs_hash": head[1], "shot": head[2], "k": head[3],
                "state": body}
    if program == "outputs":
        return {"state_in_hash": head[0], "inputs_hash": head[1], "outputs": body}
    return {"outputs": body}


def returned_felts(output: list[int]) -> list[int]:
    """The `Array<felt252>` a standalone executable returns, from its output segment: the length
    then the felts (scarb 2.19, no panic flag in the segment of a non-panicking run)."""
    if not output or output[0] != len(output) - 1:
        raise ProofDataError(f"output segment {[hex(v) for v in output[:4]]}... is not [n, felt * n]")
    return output[1:]
