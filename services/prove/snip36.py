"""snip36: the prover service's SNIP-36 path, contract v3's *proven* tier (lot W3; `docs/proving.md`
"SNIP-36 (proven tier)", `docs/contract-v3.md`). Python 3 standard library; beside Atlantic's path of
`prove_service.py`, which drives it.

A shot is proven as the chain of `slingfall_split::chain::SplitChain` (layout (e)): `init(level)`,
`step_chunk(state, inputs, shot, k)` x n, `outputs(state, inputs)`, each call one L2 to L1 message
(`[chain, 'SLINGFALL', payload]`). The pipeline of one attempt:

1. **Plan** (`schedule`): the chain runs locally through the node's simulation
   (`starknet_simulateTransactions`, no signature, no fee; the devnet or any RPC 0.10 node): every call's
   result is the next call's state. `k` is picked so that each *virtual transaction* stays under
   `budget` L2 gas (default 1.0e9, about 9M steps at the ~111 L2 gas per step of the reference shot's
   chunk 0-90, under the protocol's 1.1e9 cap). Consecutive calls share a transaction while they fit
   (`init` with the first chunk, the last chunk with `outputs`): one proof per transaction.
2. **Prove** every transaction in parallel through a `Prover`:
   * `FakeProver` (devnet): the node's own execution of the transaction (a simulation at base block
     `B`) gives the messages; the facts are laid out as the 0.14.4 virtual OS does
     (`[PROOF2, VIRTUAL_SNOS, program, VIRTUAL_SNOS0, B, hash(B), config, n, message hashes]`) with the
     devnet's accepted program and config hashes. The devnet runs with `PROOF_MODE=none`: it ignores
     the proof and still enforces the OS's header checks (allowed program, base block at least 10
     blocks old with its stored hash, config hash). `ripen` closes the 10 blocks (`devnet_createBlock`).
   * `Snip36Prover`: `starknet_proveTransaction(block_id, transaction)` of a prover URL (SN1 §5, §7):
     the transaction is the account's signed virtual Invoke (`deploy/slingfall.ts sign-virtual`: nonce at
     `B`, zero prices, `l2_gas.max_amount` 1.1e9); its answer's facts must be in the protocol layout and
     name exactly its messages (`check_facts`). Unit-tested on recorded answers, not run (no PROOF2
     prover today).
3. **Submit** one real Invoke per proof, once its base block is 10 blocks old: `submit_chunk(chain,
   kind, payload)` per message, the proof and its facts attached (`slingfall.ts submit-proof`).
4. **Finalize**: `finalize(chain, level_hash, inputs, outputs)` (`slingfall.ts finalize`), from the
   service's account for `inputs.player` (a relay).

The chain proven is the contract's `current_chain()`; the service refuses a job (409) unless the
contract declares it with this service's own bundle (`chain_bundle(chain) == own_bundle()`, the
Poseidon of the ordered class hashes of `crates/slingfall_split/src/hashes.cairo`) and it is valid now
(`chain_valid_until(chain) > now`): the proven tier's program check.
"""

from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib import request as urlrequest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "atlantic"))
import encoding  # noqa: E402  (Poseidon, starknet_keccak)

P = encoding.P
SLINGFALL_CLI = ROOT / "deploy" / "slingfall.ts"
HASHES = ROOT / "crates" / "slingfall_split" / "src" / "hashes.cairo"


def short_string(text: str) -> int:
    return int.from_bytes(text.encode(), "big")


MARKER = short_string("SLINGFALL")
KIND_INIT, KIND_STEP, KIND_OUTPUTS = 0, 1, 2
ENTRY_KIND = {"init": KIND_INIT, "step_chunk": KIND_STEP, "outputs": KIND_OUTPUTS}
# The facts' header (sequencer main-v0.14.4 `virtual_os_output.cairo`; contract v3 `verifier::facts`).
PROOF_VERSIONS = (short_string("PROOF1"), short_string("PROOF2"))
VIRTUAL_SNOS = short_string("VIRTUAL_SNOS")
VIRTUAL_SNOS0 = short_string("VIRTUAL_SNOS0")
N_MESSAGES_INDEX, MESSAGES_INDEX = 7, 8
BLOCK_HASH_BUFFER = 10
# The devnet's virtual-OS program and OS config hash: what starknet-devnet 0.10.0's own
# `starknet_proveTransaction` answered (`fixtures/devnet-prove-0.10.0.json`) and what its OS checks
# accept on a real Invoke. The program is the first of 0.14.4's two allowed hashes (SN1 §4).
DEVNET_VIRTUAL_OS = 0x53F6C9FCFD31D27279FF7D7E422B44623550A732B59FE193354A7316A96DAA1
DEVNET_OS_CONFIG_HASH = 0x57ED4D5E20D617D8CC087A5882EAE4F71D005172326BE6439B2E1FD8B4DC57
# Plan: the L2 gas budget of a virtual transaction and the protocol's cap (SN1 §3).
DEFAULT_BUDGET = 1_000_000_000
PROTOCOL_CAP = 1_100_000_000
# The first chunk's `k` before any tick was measured; `k` shrinks by this margin after an overrun.
FIRST_K = 60
SHRINK = 0.95
MAX_TICKS = 360 * 5
# The order of a bundle (`client/src/chain/slingfall.ts` `SPLIT_BUNDLE_CLASSES`).
BUNDLE_CLASSES = ("SplitChain", "BuildClass", "SettleClass", "EditClass", "WorldClass", "OutputsClass",
                  "RulesClass", "ContactBallClass", "ContactPolygonClass", "SolverClass", "SolveAdvanceClass",
                  "IslandsClass", "BroadPhaseClass", "MassClass", "NarrowPhaseClass", "ActiveSetClass",
                  "ForceEventsClass")
NOT_FINISHED = "split: not finished"
# How a node reports a run stopped by its step or gas cap (blockifier / cairo-vm).
OUT_OF_RESOURCES = ("no remaining steps", "Out of gas", "out of gas")
# A proven job's states: `queued` -> `planning` -> `proving` -> `submitting` -> `finalizing` -> `proven`
# (or `failed`); each proof `pending` -> `proving` -> `proved` -> `ripening` -> `submitted` (or `failed`).
PENDING = ("queued", "planning", "proving", "submitting", "finalizing")


class Snip36Error(Exception):
    """A read, a simulation, a proof or a transaction of the SNIP-36 path failed."""


def message_hash(sender: int, to: int, payload: list[int]) -> int:
    """`poseidon([from, to, len(payload), ...payload])`: the virtual OS's message hash, `verifier::message_hash`."""
    return encoding.poseidon_many([sender, to, len(payload), *payload])


def pinned_hashes(text: str | None = None) -> dict[str, int]:
    """The split crate's declared class hashes by contract name (`slingfall_split::hashes::pinned()`)."""
    text = HASHES.read_text() if text is None else text
    constants = {m[1]: int(m[2], 16) for m in re.finditer(r"pub const (\w+): felt252 =\s*(0x[0-9a-fA-F]+);", text)}
    pinned = text[text.index("pub fn pinned()"):]
    return {m[1]: constants[m[2]] for m in re.finditer(r'\("(\w+)", (\w+)\)', pinned)}


def bundle_hash(classes: dict[str, int]) -> int:
    """Poseidon of the ordered class hashes of a chain (`BUNDLE_CLASSES`)."""
    return encoding.poseidon_many([classes[name] for name in BUNDLE_CLASSES])


def own_bundle() -> int:
    """This service's release: the bundle of the split crate's pinned classes."""
    return bundle_hash(pinned_hashes())


def check_facts(facts: list[int], messages: list[dict], base_block: int | None = None) -> None:
    """The protocol's layout of `proof_facts` (SN1 §4) naming exactly `messages` (`from_address`,
    `to_address`, `payload`), in order; `base_block` when known. Raises `Snip36Error` otherwise."""
    if len(facts) < MESSAGES_INDEX:
        raise Snip36Error(f"facts: {len(facts)} felts, fewer than the {MESSAGES_INDEX} of the header")
    if facts[0] not in PROOF_VERSIONS or facts[1] != VIRTUAL_SNOS or facts[3] != VIRTUAL_SNOS0:
        raise Snip36Error("facts: not a SNIP-36 virtual-OS header (proof version, variant, output version)")
    if base_block is not None and facts[4] != base_block:
        raise Snip36Error(f"facts: base block {facts[4]}, the transaction was proven at {base_block}")
    n = facts[N_MESSAGES_INDEX]
    if n != len(messages) or len(facts) < MESSAGES_INDEX + n:
        raise Snip36Error(f"facts: n_l2_to_l1_messages {n:#x} for {len(messages)} messages "
                          "(not the 0.14.4 layout: index 7 is the message count)")
    for i, m in enumerate(messages):
        want = message_hash(int(m["from_address"], 16), int(m["to_address"], 16), [int(x, 16) for x in m["payload"]])
        if facts[MESSAGES_INDEX + i] != want:
            raise Snip36Error(f"facts: message {i}'s hash is not the fact at index {MESSAGES_INDEX + i}")


# --------------------------------------------------------------------------- RPC

class Rpc:
    """JSON-RPC over HTTP (`STARKNET_RPC_URL`)."""

    def __init__(self, url: str, timeout: float = 600):
        self.url, self.timeout = url, timeout

    def __call__(self, method: str, params) -> object:
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        req = urlrequest.Request(self.url, body, {"Content-Type": "application/json", "User-Agent": "slingfall/1.0"})
        try:
            with urlrequest.urlopen(req, timeout=self.timeout) as r:
                answer = json.loads(r.read())
        except OSError as e:
            raise Snip36Error(f"RPC {method}: {e}") from None
        if "error" in answer:
            raise Snip36Error(f"RPC {method}: {json.dumps(answer['error'])[:2000]}")
        return answer["result"]

    def post(self, body: dict) -> dict:
        """The whole JSON-RPC answer of `body`, errors included (a prover's)."""
        req = urlrequest.Request(self.url, json.dumps(body).encode(), {"Content-Type": "application/json"})
        try:
            with urlrequest.urlopen(req, timeout=self.timeout) as r:
                return json.loads(r.read())
        except OSError as e:
            raise Snip36Error(f"prover {self.url}: {e}") from None

    def call(self, contract: int, entry_point: str, calldata: list[int]) -> list[int]:
        result = self("starknet_call", {"request": {"contract_address": hex(contract),
                                                     "entry_point_selector": hex(encoding.selector(entry_point)),
                                                     "calldata": [hex(x) for x in calldata]}, "block_id": "latest"})
        return [int(x, 16) for x in result]

    def block(self, block_id="latest") -> dict:
        return self("starknet_getBlockWithTxHashes", {"block_id": block_id})


def chain_state(rpc: Rpc, contract: int, bundle: int) -> dict:
    """The contract's chain set against this service's `bundle`: `{"chain", "bundle_hash",
    "chain_valid_until", "now", "chain_match"}` (`chain_match`: the current chain is declared with
    `bundle` and valid now)."""
    [chain] = rpc.call(contract, "current_chain", [])
    [declared] = rpc.call(contract, "chain_bundle", [chain])
    [valid_until] = rpc.call(contract, "chain_valid_until", [chain])
    now = int(rpc.block()["timestamp"])
    return {"chain": hex(chain), "bundle_hash": hex(declared), "own_bundle_hash": hex(bundle), "chain_valid_until": valid_until,
            "now": now, "chain_match": chain != 0 and declared == bundle and valid_until > now}


# --------------------------------------------------------------------------- the chain, simulated

def execute_calldata(calls: list[dict]) -> list[int]:
    """A Cairo 1 account's `__execute__` calldata: `[n, (to, selector, len, data...) * n]`."""
    out = [len(calls)]
    for c in calls:
        out += [c["to"], encoding.selector(c["entrypoint"]), len(c["calldata"]), *c["calldata"]]
    return out


def call_dict(chain: int, entrypoint: str, calldata: list[int]) -> dict:
    return {"to": chain, "entrypoint": entrypoint, "calldata": calldata}


def _messages(node: dict, out: list[dict]) -> list[dict]:
    for m in node.get("messages") or []:
        out.append({"from_address": node["contract_address"], "to_address": m["to_address"], "payload": m["payload"]})
    for c in node.get("calls") or []:
        _messages(c, out)
    return out


class ChainRunner:
    """Simulates calls of the chain contract from `sender` (a deployed account; no signature, no fee):
    each call's return data and messages, the transaction's L2 gas."""

    def __init__(self, rpc: Rpc, sender: int):
        self.rpc, self.sender = rpc, sender

    def simulate(self, calls: list[dict], block_id="latest") -> dict:
        nonce = self.rpc("starknet_getNonce", {"block_id": block_id, "contract_address": hex(self.sender)})
        zero = {"max_amount": "0x0", "max_price_per_unit": "0x0"}
        tx = {"type": "INVOKE", "version": "0x3", "sender_address": hex(self.sender),
              "calldata": [hex(x % P) for x in execute_calldata(calls)], "signature": [], "nonce": nonce,
              "resource_bounds": {"l1_gas": zero, "l1_data_gas": zero,
                                  "l2_gas": {"max_amount": hex(PROTOCOL_CAP), "max_price_per_unit": "0x0"}},
              "tip": "0x0", "paymaster_data": [], "account_deployment_data": [],
              "nonce_data_availability_mode": "L1", "fee_data_availability_mode": "L1"}
        [sim] = self.rpc("starknet_simulateTransactions", {"block_id": block_id, "transactions": [tx],
                                                           "simulation_flags": ["SKIP_VALIDATE", "SKIP_FEE_CHARGE"]})
        trace = sim["transaction_trace"]
        execute = trace["execute_invocation"]
        if "revert_reason" in execute:
            raise SimulationReverted(execute["revert_reason"])
        result = [int(x, 16) for x in execute["result"]]
        # `__execute__` returns `Array<Span<felt252>>`: a count, then each call's return data.
        spans, i = [], 1
        for _ in range(result[0]):
            n = result[i]
            spans.append(result[i + 1: i + 1 + n])
            i += 1 + n
        per_call = [_messages(c, []) for c in execute.get("calls") or []]
        return {"results": spans, "messages": per_call, "l2_gas": int(trace["execution_resources"]["l2_gas"])}


class SimulationReverted(Snip36Error):
    pass


def _span(data: list[int]) -> list[int]:
    """A returned `Span<felt252>`: its length, then its felts."""
    if not data or data[0] != len(data) - 1:
        raise Snip36Error("chain: unexpected return data")
    return data[1:]


def schedule(runner: ChainRunner, chain: int, level: list[int], inputs: list[int], budget: int = DEFAULT_BUDGET,
             log=lambda text: None) -> dict:
    """The plan of one attempt: every call of the chain with its calldata, message and L2 gas, and the
    virtual transactions they are packed into (each under `budget` L2 gas, calls in order)."""
    if budget > PROTOCOL_CAP:
        raise Snip36Error(f"budget {budget:,} over the protocol's {PROTOCOL_CAP:,} L2 gas")
    calls: list[dict] = []
    txs: list[dict] = [{"calls": [], "l2_gas": 0}]

    def room() -> int:
        return budget - txs[-1]["l2_gas"]

    def add(entry: dict) -> None:
        if entry["l2_gas"] > room():
            txs.append({"calls": [], "l2_gas": 0})
        txs[-1]["calls"].append(len(calls))
        txs[-1]["l2_gas"] += entry["l2_gas"]
        calls.append(entry)

    def entry(entrypoint: str, calldata: list[int], sim: dict, **extra) -> dict:
        [messages] = sim["messages"]
        if len(messages) != 1 or int(messages[0]["to_address"], 16) != MARKER:
            raise Snip36Error(f"chain: {entrypoint} sent {len(messages)} messages, expected one to the marker")
        return {"entrypoint": entrypoint, "kind": ENTRY_KIND[entrypoint], "calldata": [hex(x) for x in calldata],
                "payload": messages[0]["payload"], "message": messages[0], "l2_gas": sim["l2_gas"], **extra}

    calldata = [len(level), *level]
    sim = runner.simulate([call_dict(chain, "init", calldata)])
    state = _span(sim["results"][0])
    add(entry("init", calldata, sim))
    log(f"init: {sim['l2_gas']:,} L2 gas")
    shots, shot, per_tick, ticks = inputs[1], 0, None, 0
    while True:
        # the shot in progress, in chunks
        over = False
        while not over:
            k = max(1, (room() * 95 // 100) // per_tick) if per_tick else FIRST_K
            while True:
                calldata = [len(state), *state, len(inputs), *inputs, shot, k]
                try:
                    sim = runner.simulate([call_dict(chain, "step_chunk", calldata)])
                except SimulationReverted as e:
                    # Past the node's step or gas cap the run stops without a figure: halve `k`.
                    if not any(cap in str(e) for cap in OUT_OF_RESOURCES) or k == 1:
                        raise
                    k = max(1, k // 2)
                    continue
                if sim["l2_gas"] <= room():
                    break
                if sim["l2_gas"] > budget and k == 1:
                    raise Snip36Error(f"chain: one tick of shot {shot} costs {sim['l2_gas']:,} L2 gas, over the budget")
                if k == 1 or (txs[-1]["calls"] and room() < budget // 10):
                    # no room left in this transaction: the chunk opens the next one
                    txs.append({"calls": [], "l2_gas": 0})
                    k = max(1, (budget * 95 // 100) // per_tick) if per_tick else FIRST_K
                    continue
                k = max(1, int(k * room() / sim["l2_gas"] * SHRINK))
            ret = _span(sim["results"][0])
            state, (stepped, over) = ret[:-2], (ret[-2], ret[-1] == 1)
            if stepped == 0:
                raise Snip36Error(f"chain: step_chunk of shot {shot} stepped no tick")
            per_tick = max(1, sim["l2_gas"] // stepped)
            ticks += stepped
            add(entry("step_chunk", calldata, sim, shot=shot, k=k, stepped=stepped))
            log(f"shot {shot}: {stepped} ticks (k {k}), {sim['l2_gas']:,} L2 gas; tx {len(txs) - 1} at {txs[-1]['l2_gas']:,}")
            if ticks > MAX_TICKS:
                raise Snip36Error("chain: more ticks than any level allows")
        # the shot is over: the level too, or the next shot
        calldata = [len(state), *state, len(inputs), *inputs]
        try:
            sim = runner.simulate([call_dict(chain, "outputs", calldata)])
        except SimulationReverted as e:
            if NOT_FINISHED not in str(e) and short_string(NOT_FINISHED).to_bytes(19, "big").hex() not in str(e):
                raise
            shot += 1
            if shot >= shots:
                raise Snip36Error("chain: every shot played and the level not finished") from None
            continue
        outputs = _span(sim["results"][0])
        add(entry("outputs", calldata, sim))
        log(f"outputs: {sim['l2_gas']:,} L2 gas; {len(txs)} transaction(s)")
        break
    plan = {"chain": hex(chain), "level_hash": hex(encoding.poseidon_many(level)), "inputs": [hex(x) for x in inputs],
            "outputs": [hex(x) for x in outputs], "budget": budget, "calls": calls, "txs": txs, "ticks": ticks}
    plan["txs"] = verify_txs(runner, plan, log)
    return plan


def verify_txs(runner: ChainRunner, plan: dict, log=lambda text: None) -> list[dict]:
    """Each packed transaction simulated whole: its own L2 gas, and a split at a call boundary when
    the node refuses it (the block's capacity counts builtins apart: a devnet block holds 2.0e9 of
    its weighted "sierra gas", which a transaction of ~0.94e9 L2 gas with many hashes can pass)."""
    out, queue = [], [list(tx["calls"]) for tx in plan["txs"]]
    chain = int(plan["chain"], 16)
    while queue:
        indices = queue.pop(0)
        calls = [call_dict(chain, plan["calls"][i]["entrypoint"], [int(x, 16) for x in plan["calls"][i]["calldata"]]) for i in indices]
        try:
            sim = runner.simulate(calls)
        except Snip36Error as e:
            refused = any(cap in str(e) for cap in (*OUT_OF_RESOURCES, "maximum block capacity"))
            if not refused or len(indices) == 1:
                raise
            half = len(indices) // 2
            log(f"transaction of calls {indices}: refused by the node ({str(e)[:60]}...); split")
            queue[:0] = [indices[:half], indices[half:]]
            continue
        out.append({"calls": indices, "l2_gas": sim["l2_gas"]})
    log(f"verified: {len(out)} transaction(s), L2 gas {[tx['l2_gas'] for tx in out]}")
    return out


def tx_calls(plan: dict, index: int) -> list[dict]:
    """The calls of virtual transaction `index`, as `{contractAddress, entrypoint, calldata}` (starknet.js)."""
    return [{"contractAddress": plan["chain"], "entrypoint": plan["calls"][i]["entrypoint"],
             "calldata": plan["calls"][i]["calldata"]} for i in plan["txs"][index]["calls"]]


# --------------------------------------------------------------------------- provers

class Prover:
    """The proving step: `prove(plan, index)` -> `{"proof", "proof_facts", "messages", "base_block"}`
    for virtual transaction `index`; `ripen(base_block)` returns once a proof of that base block can
    be sent (the OS wants it at least `BLOCK_HASH_BUFFER` blocks old)."""

    name = "prover"

    def prove(self, plan: dict, index: int) -> dict:
        raise NotImplementedError

    def ripen(self, base_block: int) -> None:
        raise NotImplementedError


class FakeProver(Prover):
    """The devnet's prover: the node executes the transaction (a simulation at the base block) and the
    facts are laid out as the 0.14.4 virtual OS lays them out; no proof (the devnet runs with
    `PROOF_MODE=none`). `devnet`: `ripen` closes blocks itself (`devnet_createBlock`)."""

    name = "fake"

    def __init__(self, rpc: Rpc, runner: ChainRunner, program: int = DEVNET_VIRTUAL_OS,
                 config_hash: int = DEVNET_OS_CONFIG_HASH, devnet: bool = True, poll: float = 5.0):
        self.rpc, self.runner, self.program, self.config_hash = rpc, runner, program, config_hash
        self.devnet, self.poll = devnet, poll
        self._lock = threading.Lock()

    def prove(self, plan: dict, index: int) -> dict:
        calls = [call_dict(int(plan["chain"], 16), plan["calls"][i]["entrypoint"],
                           [int(x, 16) for x in plan["calls"][i]["calldata"]]) for i in plan["txs"][index]["calls"]]
        with self._lock:
            # The base block is the latest one: the devnet keeps no state archive to simulate at an
            # older block, so a block closed meanwhile (another transaction) means another try.
            for _ in range(5):
                block = self.rpc.block("latest")
                sim = self.runner.simulate(calls, "latest")
                if self.rpc.block("latest")["block_hash"] == block["block_hash"]:
                    break
            else:
                raise Snip36Error("fake prover: the latest block kept moving")
            base = int(block["block_number"])
        messages = [m for per_call in sim["messages"] for m in per_call]
        hashes = [message_hash(int(m["from_address"], 16), int(m["to_address"], 16), [int(x, 16) for x in m["payload"]])
                  for m in messages]
        facts = [PROOF_VERSIONS[1], VIRTUAL_SNOS, self.program, VIRTUAL_SNOS0, base, int(block["block_hash"], 16),
                 self.config_hash, len(messages), *hashes]
        return {"proof": base64.b64encode(b"slingfall-fake-proof").decode(), "proof_facts": [hex(x) for x in facts],
                "messages": messages, "base_block": base, "l2_gas": sim["l2_gas"]}

    def ripen(self, base_block: int) -> None:
        while int(self.rpc.block("latest")["block_number"]) < base_block + BLOCK_HASH_BUFFER:
            if self.devnet:
                self.rpc("devnet_createBlock", {})
            else:
                time.sleep(self.poll)


class Snip36Prover(Prover):
    """A SNIP-36 prover (`starknet_proveTransaction` at `url`, SN1 §5): the account's signed virtual
    Invoke of the transaction's calls at the latest block (`sign(calls, block) -> transaction`);
    the answer's facts are checked (`check_facts`). `post(url, body) -> dict` is injectable."""

    name = "snip36"

    def __init__(self, url: str, rpc: Rpc, sign, post=None, poll: float = 30.0, timeout: float = 3600):
        self.url, self.rpc, self.sign, self.poll = url, rpc, sign, poll
        self.post = post or (lambda u, body: Rpc(u, timeout).post(body))
        self.timeout = timeout

    def prove(self, plan: dict, index: int) -> dict:
        base = int(self.rpc.block("latest")["block_number"])
        transaction = self.sign(tx_calls(plan, index), base)
        answer = self.post(self.url, {"jsonrpc": "2.0", "id": 1, "method": "starknet_proveTransaction",
                                      "params": {"block_id": {"block_number": base}, "transaction": transaction}})
        if "error" in answer:
            raise Snip36Error(f"prover: {json.dumps(answer['error'])[:500]}")
        result = answer.get("result") or {}
        messages = result.get("l2_to_l1_messages")
        if not isinstance(result.get("proof"), str) or not isinstance(result.get("proof_facts"), list) or not isinstance(messages, list):
            raise Snip36Error("prover: expected proof, proof_facts and l2_to_l1_messages")
        facts = [int(x, 16) for x in result["proof_facts"]]
        check_facts(facts, messages, base)
        return {"proof": result["proof"], "proof_facts": [hex(x) for x in facts],
                "messages": [{k: m[k] for k in ("from_address", "to_address", "payload")} for m in messages],
                "base_block": base}

    def ripen(self, base_block: int) -> None:
        deadline = time.time() + self.timeout
        while int(self.rpc.block("latest")["block_number"]) < base_block + BLOCK_HASH_BUFFER:
            if time.time() > deadline:
                raise Snip36Error(f"base block {base_block}: not {BLOCK_HASH_BUFFER} blocks old after {self.timeout:.0f} s")
            time.sleep(self.poll)


def proof_doc(plan: dict, index: int, proof: dict) -> dict:
    """What `slingfall.ts submit-proof` sends: each message's `submit_chunk(chain, kind, payload)`.
    The messages come from the proof, in order; each must be the planned call's (same payload)."""
    planned = [plan["calls"][i] for i in plan["txs"][index]["calls"]]
    if len(proof["messages"]) != len(planned):
        raise Snip36Error(f"proof {index}: {len(proof['messages'])} messages for {len(planned)} calls")
    messages = []
    for call, m in zip(planned, proof["messages"]):
        if [int(x, 16) for x in m["payload"]] != [int(x, 16) for x in call["payload"]]:
            raise Snip36Error(f"proof {index}: a message differs from the planned {call['entrypoint']}'s")
        if int(m["from_address"], 16) != int(plan["chain"], 16) or int(m["to_address"], 16) != MARKER:
            raise Snip36Error(f"proof {index}: a message is not the chain's to the marker")
        messages.append({"kind": call["kind"], "payload": m["payload"]})
    return {"chain": plan["chain"], "messages": messages, "proof_facts": proof["proof_facts"], "proof": proof["proof"]}


# --------------------------------------------------------------------------- transactions (Node)

class NodeChain:
    """The transactions of the path through `deploy/slingfall.ts` (starknet.js signs; the service stays
    stdlib-only), from the account of `env` (`atlantic.account_env`) on `contract`."""

    def __init__(self, contract: int, env: dict[str, str], cli: Path = SLINGFALL_CLI, timeout: float = 900):
        self.contract, self.env, self.cli, self.timeout = contract, env, cli, timeout

    @property
    def address(self) -> str:
        return self.env["SLINGFALL_ACCOUNT_ADDRESS"]

    def node(self, argv: list[str]) -> dict:
        full = ["node", str(self.cli), *argv, "--address", hex(self.contract), "--rpc", self.env["STARKNET_RPC"]]
        try:
            run = subprocess.run(full, capture_output=True, text=True, timeout=self.timeout, check=False,
                                 env={**os.environ, **self.env})
        except (OSError, subprocess.TimeoutExpired) as e:
            raise Snip36Error(f"cannot run {self.cli.name}: {e}") from None
        if run.returncode != 0:
            tail = (run.stderr or run.stdout).strip().splitlines()[-2:]
            raise Snip36Error(" | ".join(tail) or f"exit {run.returncode}")
        try:
            return json.loads(run.stdout)
        except ValueError:
            raise Snip36Error(f"unexpected answer: {run.stdout[-200:]!r}") from None

    def _with_file(self, name: str, doc, argv: list[str]) -> dict:
        with tempfile.TemporaryDirectory(prefix="snip36_") as tmp:
            path = Path(tmp) / name
            path.write_text(json.dumps(doc))
            return self.node([a.replace("{}", str(path)) for a in argv])

    def submit_proof(self, doc: dict) -> dict:
        return self._with_file("proof.json", doc, ["submit-proof", "--proof", "{}"])

    def finalize(self, plan: dict) -> dict:
        with tempfile.TemporaryDirectory(prefix="snip36_") as tmp:
            inputs, outputs = Path(tmp) / "inputs.json", Path(tmp) / "outputs.json"
            inputs.write_text(json.dumps(plan["inputs"]))
            outputs.write_text(json.dumps(plan["outputs"]))
            return self.node(["finalize", "--chain", plan["chain"], "--level", plan["level_hash"],
                              "--inputs", str(inputs), "--outputs", str(outputs)])

    def tier(self, level_hash: str, player: str, inputs_hash: str) -> int:
        return int(self.node(["attempt", "--level", level_hash, "--player", player, "--inputs-hash", inputs_hash])["attempt"])

    def sign_virtual(self, calls: list[dict], block: int) -> dict:
        return self._with_file("calls.json", calls, ["sign-virtual", "--calls", "{}", "--block", str(block)])


PROVEN = 3


# --------------------------------------------------------------------------- the pipeline

SETTLED = 2


class Snip36:
    """The proven path of `prove_service.Service`: `chain_of()` (the contract's chain set,
    `chain_state`), a `ChainRunner`, a `Prover`, a `NodeChain` (or fakes with the same methods),
    `level_felts(name) -> felts` (the service's level fixtures)."""

    def __init__(self, runner: ChainRunner, prover: Prover, chain: NodeChain, chain_of, bundle: int, level_felts,
                 budget: int = DEFAULT_BUDGET, parallel: int = 4, ttl: float = 30.0, clock=time.time):
        self.runner, self.prover, self.chain, self.chain_of, self.bundle = runner, prover, chain, chain_of, bundle
        self.level_felts = level_felts
        self.budget, self.parallel, self.ttl, self.clock = budget, parallel, ttl, clock
        self._cache: tuple[float, dict] | None = None
        self._lock = threading.Lock()

    def chain_view(self) -> dict:
        """`chain_state` of the contract, cached `ttl` seconds; `{"chain_match": None}` when unreadable."""
        now = self.clock()
        if self._cache is None or now - self._cache[0] >= self.ttl:
            try:
                self._cache = (now, self.chain_of())
            except Exception as e:  # noqa: BLE001  (an unreachable RPC never blocks on its own)
                if self._cache is None:
                    return {"chain": None, "bundle_hash": None, "own_bundle_hash": hex(self.bundle),
                            "chain_valid_until": None, "chain_match": None, "error": str(e)}
        return self._cache[1]

    def health(self) -> dict:
        view = self.chain_view()
        return {"available": view["chain_match"] is not False, "prover": self.prover.name, "budget": self.budget, **view}

    def job_id_key(self) -> str:
        return f"snip36:{self.bundle:#x}"

    def check(self) -> dict:
        """The proven tier's program check: the current chain is this release's and valid now."""
        view = self.chain_view()
        if view["chain_match"] is False:
            raise ChainMismatch(view)
        return view

    def work(self, store, job: dict, save) -> dict:
        """Runs (or resumes) a proven job to the end; `save(job)` persists every state change."""
        jdir = store.dir(job["id"])
        plan_path = jdir / "plan.json"
        view = self.check()
        chain = int(view["chain"], 16) if view.get("chain") else None
        inputs = [int(x, 16) for x in job["inputs"]]
        player, inputs_hash = hex(inputs[0]), hex(encoding.poseidon_many(inputs))
        if plan_path.is_file():
            plan = json.loads(plan_path.read_text())
        else:
            if chain is None:
                raise Snip36Error("no chain: the contract's current_chain() is unreadable")
            # The attempt may be proven already (another service) or settled by SHARP: both close it.
            tier = self.chain.tier(job["level_hash"], player, inputs_hash)
            if tier == PROVEN:
                job.update({"state": "proven", "finalize": {"state": "proven", "by": "someone else"}})
                return save(job)
            if tier == SETTLED:
                raise Snip36Error("the attempt is already settled (Satellite): the nullifier refuses a proven record")
            job["state"] = "planning"
            save(job)
            started = time.time()
            plan = schedule(self.runner, chain, self.level_felts(job["level"]), inputs, self.budget,
                            log=lambda text: print(f"snip36 {job['id'][:8]}: {text}", file=sys.stderr, flush=True))
            if int(plan["level_hash"], 16) != int(job["level_hash"], 16):
                raise Snip36Error("the chain's level hash is not the level's")
            plan_path.write_text(json.dumps(plan))
            job["plan"] = {"chain": plan["chain"], "transactions": len(plan["txs"]), "calls": len(plan["calls"]),
                           "ticks": plan["ticks"], "budget": plan["budget"], "seconds": round(time.time() - started, 1),
                           "l2_gas": [tx["l2_gas"] for tx in plan["txs"]]}
            job["outputs"] = plan["outputs"]
            job["proofs"] = [{"state": "pending"} for _ in plan["txs"]]
            save(job)
        # prove every transaction in parallel
        job["state"] = "proving"
        save(job)

        def prove(i: int) -> None:
            path = jdir / f"proof-{i}.json"
            if path.is_file():
                return
            with self._lock:
                job["proofs"][i]["state"] = "proving"
                save(job)
            started = time.time()
            try:
                proof = self.prover.prove(plan, i)
                doc = proof_doc(plan, i, proof)
            except Snip36Error as e:
                with self._lock:
                    job["proofs"][i].update({"state": "failed", "error": str(e)})
                    save(job)
                raise
            path.write_text(json.dumps({**doc, "base_block": proof["base_block"]}))
            with self._lock:
                job["proofs"][i].update({"state": "proved", "base_block": proof["base_block"], "messages": len(doc["messages"]),
                                         "prover": self.prover.name, "seconds": round(time.time() - started, 1)})
                save(job)

        with ThreadPoolExecutor(max_workers=max(1, min(self.parallel, len(plan["txs"])))) as pool:
            for future in [pool.submit(prove, i) for i in range(len(plan["txs"]))]:
                future.result()
        # one real Invoke per proof, then finalize
        job["state"] = "submitting"
        save(job)
        for i, entry in enumerate(job["proofs"]):
            if entry.get("transaction_hash"):
                continue
            doc = json.loads((jdir / f"proof-{i}.json").read_text())
            entry["state"] = "ripening"
            save(job)
            self.prover.ripen(doc.pop("base_block"))
            result = self.chain.submit_proof(doc)
            entry.update({"state": "submitted", "transaction_hash": result.get("transaction_hash"), "gas": result.get("gas")})
            save(job)
        job["state"] = "finalizing"
        save(job)
        if self.chain.tier(plan["level_hash"], player, inputs_hash) == PROVEN:
            job["finalize"] = {"state": "proven", "by": "someone else"}
        else:
            result = self.chain.finalize(plan)
            [event] = result.get("level_validated") or [None]
            if not event or not event.get("proven"):
                raise Snip36Error(f"finalize {result.get('transaction_hash')}: no proven LevelValidated")
            job["finalize"] = {"state": "finalized", "transaction_hash": result["transaction_hash"], "gas": result.get("gas"),
                               "program_hash": event.get("programHash"), "relayer": self.chain.address}
        job["state"] = "proven"
        return save(job)

    def status(self, job: dict) -> dict:
        """`/status` of a proven job: the tier being produced, each proof's state, the chain check."""
        answer = dict(job)
        view = self.chain_view()
        answer.update({"tier": "proven", "proven": job.get("state") == "proven", "settleable": False,
                       "settleable_poseidon": False, "settleable_keccak": False, "program_hash": view.get("own_bundle_hash"),
                       "chain": view.get("chain"), "chain_bundle": view.get("bundle_hash"),
                       "chain_valid_until": view.get("chain_valid_until"), "chain_match": view.get("chain_match"),
                       "program_match": view.get("chain_match"), "relay": {"state": "off"}, "relayed": False,
                       "relay_transaction_hash": (job.get("finalize") or {}).get("transaction_hash")})
        return answer


class ChainMismatch(Snip36Error):
    """The contract's current chain is not this service's release, or no longer valid."""

    def __init__(self, view: dict):
        super().__init__(f"prove: chain mismatch (this service proves bundle {view['own_bundle_hash']}; the contract's "
                         f"current chain {view['chain']} is declared with {view['bundle_hash']}, valid until "
                         f"{view['chain_valid_until']})")
        self.view = view
