#!/usr/bin/env python3
"""prove_local: the prover service of `scripts/play.sh` (lot L1, docs/play-local.md): the one of
`services/prove/prove_service.py serve`, with both proofs simulated on the local devnet.

    scripts/play/prove_local.py --config target/play/devnet.json [--host H] [--port N] [--store DIR]

* **Proven tier** (SNIP-36): the service's own path with the fake prover (`--snip36 fake`): the chain
  planned by simulation, one fake proof per virtual transaction (the devnet runs `--proof-mode none`),
  one Invoke per proof and `finalize`, from the account of the environment (`STARKNET_ACCOUNT_ADDRESS`,
  `STARKNET_PRIVATE_KEY`, `STARKNET_RPC_URL`: devnet account #2).
* **Settled tier**: no Atlantic, no `cairo1-run`. The run is the replay's `main` under `scarb execute`
  (what the attestation service re-executes; `c1main` returns the same outputs), its facts are
  computed for the program pinned on the contract (`encoding.slingfall_fact`, as a PIE of the same
  attempt would carry), and "Atlantic" registers the Poseidon fact on the devnet's `FakeSatellite`
  at once (`deploy/slingfall.ts fake-fact`, from the admin, account #0, which deployed it). The job
  is then `settleable`, and the relay (account #3, `RELAY_*` below; a pass every `--relay-interval`
  seconds) sends `submit_settled` for the player, as the service's `--relay` does on Sepolia.

HTTP, job store, `/health`, `/status/<id>`: `prove_service`'s, unchanged. Environment: the account
of the SNIP-36 path as above, `SLINGFALL_ADDRESS`, `RELAY_ACCOUNT_ADDRESS` / `RELAY_PRIVATE_KEY`.
Devnet only: this service signs nothing real and proves nothing.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "services" / "prove"))
sys.path.insert(0, str(ROOT / "tools" / "golden"))
import prove_service as ps  # noqa: E402
import golden  # noqa: E402  (scarb execute of the replay)

encoding, relaying, snip36 = ps.encoding, ps.relaying, ps.snip36
CLI = ROOT / "deploy" / "slingfall.ts"


class LocalRunner:
    """`prove_service.Runner` without `cairo1-run`: the replay's `main` (built) for the outputs, the
    facts for `child` (the contract's pinned program)."""

    def __init__(self, child: int):
        self.child = child

    def child_program(self) -> str:
        return f"local-{self.child:x}"

    def known_child_program_hash(self) -> int:
        return self.child

    def run(self, job_dir: Path, args: list[int]) -> dict:
        started = time.time()
        steps, outputs, _ = golden.execute("main", args)
        if len(outputs) != ps.N_OUTPUTS:
            raise ps.ProveError(500, f"scarb execute: {len(outputs)} output felts, expected {ps.N_OUTPUTS}")
        facts = encoding.slingfall_fact(self.child, outputs, args)
        run = {
            "outputs": [hex(x) for x in outputs], "steps": steps, "pie_bytes": 0,
            "run_seconds": round(time.time() - started, 1), "child_program_hash": hex(self.child),
            "integrity_fact_hash": hex(facts["integrity_fact_hash"]), "sharp_fact_hash": hex(facts["sharp_fact_hash"]),
        }
        # The fake Atlantic below reads the fact from here (it is handed the PIE's path only).
        (job_dir / "facts.json").write_text(json.dumps(run))
        return run


class FakeAtlantic:
    """`submit_pie` and `atlantic_status` of the devnet: the fact is on the `FakeSatellite` at once."""

    def __init__(self, config: Path, rpc: str):
        self.config, self.rpc = config, rpc

    def submit(self, pie: Path, size: str, result: str, dedup_id: str, external_id: str) -> dict:
        fact = json.loads((pie.parent / "facts.json").read_text())["integrity_fact_hash"]
        argv = ["node", str(CLI), "fake-fact", "--devnet", "--index", "0", "--config", str(self.config),
                "--fact", fact, "--rpc", self.rpc]
        run = subprocess.run(argv, capture_output=True, text=True, timeout=300, check=False)
        if run.returncode != 0:
            tail = (run.stderr or run.stdout).strip().splitlines()[-2:]
            raise ps.ProveError(502, f"fake Satellite: {' | '.join(tail)}")
        print(f"prove_local: {external_id}: fact {fact} registered on the FakeSatellite", file=sys.stderr, flush=True)
        return {"query_id": f"local-{dedup_id}", "reused": False, "fields": {"declaredJobSize": size, "result": result}}

    @staticmethod
    def status(query_id: str) -> dict:
        return {"status": "DONE", "step": "LOCAL", "jobSize": None, "integrityFactHash": None, "sharpFactHash": None,
                "errorReason": None, "createdAt": None, "completedAt": None, "totalSeconds": 0,
                "stages": [{"job": "FAKE_SATELLITE", "status": "DONE"}]}


def confirmed(send, rpc: str, what: str, timeout: float = 60.0):
    """`send(...)` (a `deploy/slingfall.ts` transaction, which returns `{transaction_hash, ...}`) checked
    against the devnet the service talks to: the transaction must have a receipt there (bounded wait),
    else the job fails with a clear message instead of reporting a transaction nobody can find. The
    devnet closes a block per transaction; one `devnet_createBlock` is asked for if it has not (a
    devnet on demand), as `FakeProver.ripen` asks for its own."""
    node = snip36.Rpc(rpc, 30)

    def run(*args):
        result = send(*args)
        tx = result.get("transaction_hash")
        if not tx:
            return result
        deadline, asked = time.time() + timeout, False
        while True:
            try:
                node("starknet_getTransactionReceipt", {"transaction_hash": tx})
                return result
            except snip36.Snip36Error as e:
                if time.time() > deadline:
                    raise snip36.Snip36Error(f"{what} {tx}: no receipt on {rpc} after {timeout:.0f} s ({e})") from None
            if not asked:
                asked = True
                print(f"prove_local: {what} {tx}: no receipt yet, closing a block", file=sys.stderr, flush=True)
                node("devnet_createBlock", {})
            time.sleep(0.5)
    return run


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--config", required=True, help="deploy/devnet.sh's DEVNET_OUT (address, program)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8549)
    parser.add_argument("--store", default=str(ROOT / "target" / "play" / "prove"))
    parser.add_argument("--relay-interval", type=float, default=2.0, help="seconds between two relay passes")
    args = parser.parse_args(argv)

    config = json.loads(Path(args.config).read_text())
    rpc = os.environ["STARKNET_RPC_URL"]
    # prove_service's own options for the SNIP-36 path; no translation (the fact is the Poseidon one).
    opts = argparse.Namespace(store=args.store, result=ps.DEFAULT_RESULT, no_submit=False, no_program_check=False,
                              snip36="fake", prover_url=None, budget=snip36.DEFAULT_BUDGET, parallel=4,
                              no_translate=True, translate_grace=None, relay=False)
    service = ps.make_service(opts)
    atlantic = FakeAtlantic(Path(args.config), rpc)
    chain = service.proven.chain
    chain.submit_proof = confirmed(chain.submit_proof, rpc, "submit-proof")
    chain.finalize = confirmed(chain.finalize, rpc, "finalize")
    service.runner = LocalRunner(int(config["program"]["current"], 16))
    service.submitter, service.status_of = atlantic.submit, atlantic.status
    # The relay from its own account: the SNIP-36 path's transactions never race its nonce.
    service.relayer = relaying.NodeRelay(int(config["address"], 16), {
        "STARKNET_RPC": rpc, "SLINGFALL_ACCOUNT_ADDRESS": os.environ["RELAY_ACCOUNT_ADDRESS"],
        "SLINGFALL_PRIVATE_KEY": os.environ["RELAY_PRIVATE_KEY"]})

    service.relayer.send = confirmed(service.relayer.send, rpc, "settle")
    resumed = service.resume()
    threading.Thread(target=service.worker, daemon=True).start()
    threading.Thread(target=service.proven_worker, daemon=True).start()
    threading.Thread(target=service.relay_loop, args=(args.relay_interval,), daemon=True).start()
    server = ThreadingHTTPServer((args.host, args.port), ps.make_handler(service))
    print(f"prove_local: listening on http://{args.host}:{server.server_address[1]} (store {args.store}, {resumed} job(s) "
          f"resumed; proven: SNIP-36 fake prover from {os.environ['STARKNET_ACCOUNT_ADDRESS']}; "
          f"settled: fake Atlantic, FakeSatellite {config['satellite']['satellite_address']}, relay from "
          f"{service.relayer.address}; program {config['program']['current']})", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
