"""relay: the prover service's optional relay of `submit_settled` (contract v2, `docs/contract-v2.md`
"Relay"; QA S10). Python 3 standard library.

Contract v2 records a settled attempt for `claim.player` whoever sends it, so once a job's fact is
on the Satellite the service may send `submit_settled(outputs, args, child_program_hash)` itself,
from its own account (`STARKNET_ACCOUNT_ADDRESS` + `STARKNET_PRIVATE_KEY` + `STARKNET_RPC_URL`, or
`SLINGFALL_*`; `atlantic.account_env`), and the player need not come back. It is off by default
(`serve --relay`). The player can still settle themselves: whoever comes second reverts on
`'submit: nullifier'`, so the relay reads the attempt's tier first and simulates before sending.

`NodeRelay` drives `deploy/slingfall.ts` (starknet.js signs; the service stays stdlib-only):
`attempt` is a read, `submit-settled --simulate` a `simulateTransaction`, `submit-settled` the
transaction. `prove_service.Service` decides when (`relay_job`); the tests replace `NodeRelay`
with a fake.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SLINGFALL_CLI = ROOT / "deploy" / "slingfall.ts"
# `nullifier::SETTLED`: the attempt's tier once `submit_settled` has landed.
SETTLED = 2
# At most this many transactions per job, `RELAY_RETRY` seconds apart; the loop's pause.
RELAY_ATTEMPTS = 3
RELAY_RETRY = 300.0
RELAY_INTERVAL = 60.0


class RelayError(Exception):
    """A read, a simulation or a transaction of the relay failed (the message says which)."""


def job_files(job: dict, tmp: Path) -> tuple[Path, Path]:
    """The `--outputs` and `--args` files of `slingfall.ts submit-settled` for a job."""
    outputs, args = tmp / "outputs.json", tmp / "args.json"
    outputs.write_text(json.dumps({"outputs": job["outputs"]}))
    args.write_text(json.dumps({"level_hash": job["level_hash"], "inputs": job["inputs"],
                                "child_program_hash": job["run"]["child_program_hash"]}))
    return outputs, args


class NodeRelay:
    """`submit_settled` of a job on `contract`, from the account of `env` (`atlantic.account_env`)."""

    def __init__(self, contract: int, env: dict[str, str], cli: Path = SLINGFALL_CLI, timeout: float = 600):
        self.contract, self.env, self.cli, self.timeout = contract, env, cli, timeout

    @property
    def address(self) -> str:
        return self.env["SLINGFALL_ACCOUNT_ADDRESS"]

    def _node(self, argv: list[str]) -> dict:
        full = ["node", str(self.cli), *argv, "--address", hex(self.contract), "--rpc", self.env["STARKNET_RPC"]]
        try:
            run = subprocess.run(full, capture_output=True, text=True, timeout=self.timeout, check=False,
                                 env={**os.environ, **self.env})
        except (OSError, subprocess.TimeoutExpired) as e:
            raise RelayError(f"cannot run {self.cli.name}: {e}") from None
        if run.returncode != 0:
            tail = (run.stderr or run.stdout).strip().splitlines()[-2:]
            raise RelayError(" | ".join(tail) or f"exit {run.returncode}")
        try:
            return json.loads(run.stdout)
        except ValueError:
            raise RelayError(f"unexpected answer: {run.stdout[-200:]!r}") from None

    def tier(self, job: dict) -> int:
        """`attempt(level_hash, player, inputs_hash)`: 0 none, 1 attested, 2 settled."""
        outputs = job["outputs"]
        answer = self._node(["attempt", "--level", job["level_hash"], "--player", outputs[3], "--inputs-hash", outputs[4]])
        return int(answer["attempt"])

    def _settle(self, job: dict, simulate: bool) -> dict:
        with tempfile.TemporaryDirectory(prefix="relay_") as tmp:
            outputs, args = job_files(job, Path(tmp))
            argv = ["submit-settled", "--outputs", str(outputs), "--args", str(args)]
            return self._node([*argv, "--simulate"] if simulate else argv)

    def simulate(self, job: dict) -> dict:
        """`simulateTransaction` of the settle: raises when it would revert (a re-pin, a race)."""
        return self._settle(job, simulate=True)

    def send(self, job: dict) -> dict:
        """The settle transaction: `{transaction_hash, level_validated, gas}`."""
        return self._settle(job, simulate=False)
