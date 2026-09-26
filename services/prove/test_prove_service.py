"""Unit tests of the prover service (lots E3b, E3c). Offline: a fake `cairo1-run` (this file run as a
script writes a small PIE and prints the outputs), Atlantic and the Satellite replaced by fakes.

    python3 -m unittest discover -s services/prove -v
"""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import prove_service as ps  # noqa: E402

ROOT = HERE.parents[1]
E3A = json.loads((ROOT / "fixtures" / "proofs" / "atlantic" / "pile10-reference.json").read_text())
E3A_OUTPUT = [int(x, 16) for x in E3A["atlantic"]["output"]]
PLAYER = 0x706C61796572
# pile10-reference as E3a proved it: inputs [player, 1 shot, -604, -392, 0, 0].
INPUTS = [hex(PLAYER), "0x1", hex(-604 % ps.P), hex(-392 % ps.P), "0x0", "0x0"]
# A tiny program for the fake PIE: its Pedersen hash stands for c1main's.
FAKE_PROGRAM = {"builtins": ["output", "range_check", "bitwise", "poseidon"], "main": 0, "data": ["0x1", "0x2", "0x3"]}
FAKE_STEPS = 8_784_517
DONE_AT = "2026-09-26T13:07:07.484Z"


def fake_cairo1_run(argv: list[str]) -> int:
    """`cairo1-run SIERRA ... --cairo_pie_output PIE --args_file INPUT --print_output`: prints
    E3a's outputs when the input is E3a's argument, else fails."""
    pie = argv[argv.index("--cairo_pie_output") + 1]
    args = Path(argv[argv.index("--args_file") + 1]).read_text().strip()[1:-1].split()
    if [int(a) for a in args] != [int(a, 16) for a in E3A["args"]]:
        print("fake cairo1-run: unexpected arguments", file=sys.stderr)
        return 1
    with zipfile.ZipFile(pie, "w") as z:
        z.writestr("metadata.json", json.dumps({"program": FAKE_PROGRAM}))
        z.writestr("execution_resources.json", json.dumps({"n_steps": FAKE_STEPS}))
    print("Program Output : [" + " ".join(str(int(x, 16)) for x in E3A["outputs"]) + "]")
    return 0


class Service(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        tmp = Path(self.tmp.name)
        runner = tmp / "cairo1-run"
        runner.write_text(f"#!{sys.executable}\nimport sys\nsys.path.insert(0, {str(HERE)!r})\n"
                          "import test_prove_service as t\nsys.exit(t.fake_cairo1_run(sys.argv[1:]))\n")
        runner.chmod(runner.stat().st_mode | stat.S_IXUSR)
        sierra = tmp / "c1main.sierra.json"
        sierra.write_text("{}")
        self.submits: list[tuple] = []
        self.on_chain = {"isCairoFactValid": False, "isKeccakVerifiedFactHashValid": False}
        self.atl = {"status": "IN_PROGRESS", "stages": []}
        self.now = ps.parse_time(DONE_AT) + 1.0
        self.translations: list[tuple] = []
        self.translate_error: str | None = None

        def translator(sharp_fact, output):
            self.translations.append((sharp_fact, output))
            if self.translate_error:
                raise ps.atlantic.AtlanticError(self.translate_error)
            self.on_chain["isCairoFactValid"] = True
            return {"isCairoFactValid": True, "transaction": {"transaction_hash": "0xabc", "gas": {"l2Gas": 7}}}

        def submitter(pie, size, result, dedup_id, external_id):
            self.submits.append((pie.name, size, result, dedup_id, external_id))
            return {"query_id": "01TEST", "reused": False, "fields": {"dedupId": dedup_id}}

        self.service = ps.Service(
            ps.Store(tmp / "store"), ps.Runner(runner, sierra), submitter=submitter,
            status_of=lambda q: self.atl,
            facts_of=lambda integrity, sharp: {"satellite": "0x0", **self.on_chain, "asked": [hex(integrity), hex(sharp)]},
            translator=translator, grace=600.0, clock=lambda: self.now)

    def tearDown(self):
        self.tmp.cleanup()

    def test_job_runs_submits_and_settles(self):
        job, created = self.service.create("pile10", INPUTS)
        self.assertTrue(created)
        self.assertEqual(job["state"], "queued")
        job = self.service.work(job["id"])
        self.assertEqual(job["state"], "submitted", job.get("error"))
        self.assertEqual(job["outputs"], E3A["outputs"])
        self.assertEqual(job["run"]["steps"], FAKE_STEPS)
        # The facts are E3a's formula with the PIE's program hash.
        child = ps.encoding.program_hash_pedersen(FAKE_PROGRAM["builtins"], 0, [1, 2, 3])
        facts = ps.encoding.slingfall_fact(child, [int(x, 16) for x in E3A["outputs"]], [int(x, 16) for x in E3A["args"]])
        self.assertEqual(job["run"]["integrity_fact_hash"], hex(facts["integrity_fact_hash"]))
        self.assertEqual(job["run"]["sharp_fact_hash"], hex(facts["sharp_fact_hash"]))
        # pile10 needs L (E3a: M is OOM-killed); the dedup id is the job id.
        self.assertEqual(self.submits, [("pie.zip", "L", ps.DEFAULT_RESULT, f"slingfall-{job['id']}", f"slingfall-pile10-{job['id'][:8]}")])
        status = self.service.status(job["id"])
        self.assertFalse(status["settleable"])
        self.assertEqual(status["atlantic_status"]["status"], "IN_PROGRESS")
        self.assertEqual(status["chain"]["asked"], [job["run"]["integrity_fact_hash"], job["run"]["sharp_fact_hash"]])
        self.assertEqual((status["settleable_poseidon"], status["settleable_keccak"]), (False, False))
        # Either fact on the Satellite makes the job settleable; the Poseidon one is the cheap path.
        self.on_chain["isKeccakVerifiedFactHashValid"] = True
        status = self.service.status(job["id"])
        self.assertEqual((status["settleable"], status["settleable_poseidon"], status["settleable_keccak"]), (True, False, True))
        self.on_chain["isCairoFactValid"] = True
        status = self.service.status(job["id"])
        self.assertEqual((status["settleable"], status["settleable_poseidon"]), (True, True))
        self.assertEqual(status["translation"]["state"], "translated")

    def test_same_attempt_same_job(self):
        job, _ = self.service.create("pile10", INPUTS)
        by_hash, created = self.service.create(hex(int(E3A["outputs"][1], 16)), [int(x, 16) for x in INPUTS])
        self.assertFalse(created)
        self.assertEqual(by_hash["id"], job["id"])
        other, created = self.service.create("pile10", [*INPUTS[:2], hex(-600 % ps.P), *INPUTS[3:]])
        self.assertTrue(created)
        self.assertNotEqual(other["id"], job["id"])

    def test_bad_requests(self):
        cases = [("nope", INPUTS, "unknown"), (7, INPUTS, "name or a level hash"), ("pile10", INPUTS[:5], "4 felts per shot"),
                 ("pile10", "x", "Inputs"), ("pile10", [*INPUTS[:5], True], "not a felt")]
        for level, inputs, message in cases:
            with self.subTest(level=level, inputs=inputs):
                with self.assertRaises(ps.ProveError) as ctx:
                    self.service.create(level, inputs)
                self.assertEqual(ctx.exception.status, 400)
                self.assertIn(message, str(ctx.exception))
        with self.assertRaises(ps.ProveError) as ctx:
            self.service.status("../../etc")
        self.assertEqual(ctx.exception.status, 404)

    def test_failed_run_is_recorded(self):
        job, _ = self.service.create("one_block", [hex(PLAYER), "0x1", "0x1", "0x1", "0x0", "0x0"])
        job = self.service.work(job["id"])
        self.assertEqual(job["state"], "failed")
        self.assertIn("cairo1-run: exit 1", job["error"])
        self.assertEqual(self.submits, [])

    def test_built_job_is_submitted_later_and_resumed(self):
        self.service.submit = False
        job, _ = self.service.create("pile10", INPUTS)
        self.assertEqual(self.service.work(job["id"])["state"], "built")
        self.service.submit = True
        self.assertEqual(self.service.resume(), 1)
        self.assertEqual(self.service.work(job["id"])["state"], "submitted")
        self.assertEqual(len(self.submits), 1)
        self.assertEqual(self.service.resume(), 0)

    def submitted_job(self) -> str:
        job, _ = self.service.create("pile10", INPUTS)
        self.assertEqual(self.service.work(job["id"])["state"], "submitted")
        return job["id"]

    def test_translation_waits_for_the_grace_period_then_translates_once(self):
        jid = self.submitted_job()
        run = self.service.store.load(jid)["run"]
        # Atlantic still working: nothing to translate.
        self.assertEqual(self.service.translate_due(), 0)
        self.assertEqual(self.service.status(jid)["translation"]["state"], "waiting")
        # Done and keccak fact bridged, inside the grace period: Atlantic's own translation may come.
        self.atl = {"status": "DONE", "completedAt": DONE_AT, "stages": []}
        self.on_chain["isKeccakVerifiedFactHashValid"] = True
        self.assertEqual(self.service.status(jid)["translation"]["state"], "grace")
        self.now = ps.parse_time(DONE_AT) + 599.0
        self.assertEqual(self.service.translate_due(), 0)
        self.assertEqual(self.translations, [])
        # Past it: the service translates, with the output the Satellite re-hashes.
        self.now = ps.parse_time(DONE_AT) + 601.0
        self.assertEqual(self.service.status(jid)["translation"]["state"], "translate")
        self.assertEqual(self.service.translate_due(), 1)
        [(sharp, output)] = self.translations
        self.assertEqual(hex(sharp), run["sharp_fact_hash"])
        # (the fake PIE's program hash stands for c1main's)
        self.assertEqual(output, ps.encoding.run_output(int(run["child_program_hash"], 16),
                                                        [int(x, 16) for x in E3A["outputs"]], [int(x, 16) for x in E3A["args"]]))
        boot = ps.encoding.ATLANTIC_BOOTLOADER_PROGRAM_HASH
        self.assertEqual(hex(ps.encoding.sharp_fact_hash(boot, output)), run["sharp_fact_hash"])
        status = self.service.status(jid)
        self.assertEqual((status["settleable_poseidon"], status["translation"]["state"], status["translation"]["transaction_hash"]),
                         (True, "translated", "0xabc"))
        # Once translated: never again.
        self.now += 10_000
        self.assertEqual(self.service.translate_due(), 0)
        self.assertEqual(len(self.translations), 1)

    def test_atlantic_translating_first_costs_nothing(self):
        jid = self.submitted_job()
        self.atl = {"status": "DONE", "completedAt": DONE_AT, "stages": []}
        self.on_chain.update(isKeccakVerifiedFactHashValid=True, isCairoFactValid=True)
        self.now = ps.parse_time(DONE_AT) + 7200
        self.assertEqual(self.service.translate_due(), 0)
        self.assertEqual(self.translations, [])
        self.assertTrue(self.service.store.load(jid)["translation"]["translated"])

    def test_without_an_account_the_keccak_path_is_reported(self):
        jid = self.submitted_job()
        self.service.translator = None
        self.atl = {"status": "DONE", "completedAt": DONE_AT, "stages": []}
        self.on_chain["isKeccakVerifiedFactHashValid"] = True
        self.now = ps.parse_time(DONE_AT) + 7200
        self.assertEqual(self.service.translate_due(), 0)
        status = self.service.status(jid)
        self.assertEqual((status["settleable"], status["settleable_keccak"], status["settleable_poseidon"]), (True, True, False))
        self.assertEqual(status["translation"]["state"], "no-account")

    def test_failed_translation_backs_off_and_gives_up(self):
        jid = self.submitted_job()
        self.atl = {"status": "DONE", "completedAt": DONE_AT, "stages": []}
        self.on_chain["isKeccakVerifiedFactHashValid"] = True
        self.translate_error = "translate: exit 1: out of gas"
        self.now = ps.parse_time(DONE_AT) + 601
        self.assertEqual(self.service.translate_due(), 1)
        self.assertIn("out of gas", self.service.store.load(jid)["translation"]["error"])
        self.assertEqual(self.service.status(jid)["translation"]["state"], "backoff")
        self.assertEqual(self.service.translate_due(), 0)
        for _ in range(ps.TRANSLATE_ATTEMPTS - 1):
            self.now += ps.TRANSLATE_RETRY + 1
            self.assertEqual(self.service.translate_due(), 1)
        self.assertEqual(len(self.translations), ps.TRANSLATE_ATTEMPTS)
        self.now += ps.TRANSLATE_RETRY + 1
        self.assertEqual(self.service.translate_due(), 0)
        self.assertEqual(self.service.status(jid)["translation"]["state"], "gave-up")
        # A manual translation ignores the counters (and records the success).
        self.translate_error = None
        self.assertTrue(self.service.translate_job(jid, force=True)["translation"]["translated"])
        self.assertNotIn("error", self.service.store.load(jid)["translation"])

    def test_done_without_a_completion_time_starts_the_grace_at_first_sight(self):
        jid = self.submitted_job()
        self.atl = {"status": "DONE", "stages": []}
        self.on_chain["isKeccakVerifiedFactHashValid"] = True
        first = self.now
        self.assertEqual(self.service.translate_due(), 0)
        self.assertEqual(self.service.store.load(jid)["translation"]["seen_at"], first)
        self.now = first + 601
        self.assertEqual(self.service.translate_due(), 1)

    def test_http(self):
        server = ps.ThreadingHTTPServer(("127.0.0.1", 0), ps.make_handler(self.service, log=open(os.devnull, "w")))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        threading.Thread(target=self.service.worker, daemon=True).start()
        url = f"http://127.0.0.1:{server.server_address[1]}"
        try:
            def post(body):
                req = urllib.request.Request(url + "/prove", data=json.dumps(body).encode(), method="POST",
                                             headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    return resp.status, json.loads(resp.read())

            status, job = post({"level": "pile10", "inputs": INPUTS})
            self.assertEqual(status, 202)
            self.service.queue.join()
            self.assertEqual(post({"level": "pile10", "inputs": INPUTS})[0], 200)
            with urllib.request.urlopen(f"{url}/status/{job['id']}", timeout=10) as resp:
                self.assertEqual(json.loads(resp.read())["state"], "submitted")
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                post({"level": "pile10", "inputs": [1]})
            self.assertEqual(ctx.exception.code, 400)
        finally:
            server.shutdown()
            server.server_close()


class TranslationDecision(unittest.TestCase):
    CHAIN = {"isCairoFactValid": False, "isKeccakVerifiedFactHashValid": True}

    def test_table(self):
        grace = 600.0
        attempts = {"attempts": 1, "last_attempt": 700}
        cases = [
            # (atlantic status, done_at, chain, now, has account, stored translation, decision)
            ("DONE", 0.0, None, 9999, True, None, "unknown"),
            ("DONE", 0.0, {"error": "rpc"}, 9999, True, None, "unknown"),
            ("DONE", 0.0, {**self.CHAIN, "isCairoFactValid": True}, 9999, True, None, "translated"),
            ("IN_PROGRESS", None, self.CHAIN, 9999, True, None, "waiting"),
            ("DONE", 0.0, {**self.CHAIN, "isKeccakVerifiedFactHashValid": False}, 9999, True, None, "waiting"),
            ("DONE", 0.0, self.CHAIN, 599, True, None, "grace"),
            ("DONE", None, self.CHAIN, 9999, True, None, "grace"),
            ("DONE", 0.0, self.CHAIN, 600, True, None, "translate"),
            ("DONE", 0.0, self.CHAIN, 600, False, None, "no-account"),
            ("DONE", 0.0, self.CHAIN, 1000, True, attempts, "backoff"),
            ("DONE", 0.0, self.CHAIN, 1300, True, attempts, "translate"),
            ("DONE", 0.0, self.CHAIN, 99999, True, {"attempts": ps.TRANSLATE_ATTEMPTS, "last_attempt": 0}, "gave-up"),
        ]
        for status, done_at, chain, now, account, translation, expected in cases:
            with self.subTest(status=status, done_at=done_at, chain=chain, now=now, account=account, translation=translation):
                self.assertEqual(ps.translation_decision(status, done_at, chain, now, grace, account, translation), expected)

    def test_parse_time(self):
        self.assertEqual(ps.parse_time("2026-09-26T13:07:07Z"), ps.parse_time("2026-09-26T13:07:07+00:00"))
        self.assertIsNone(ps.parse_time(None))
        self.assertIsNone(ps.parse_time("yesterday"))


class Helpers(unittest.TestCase):
    def test_sizes_and_args(self):
        self.assertEqual(ps.declared_size(2_425_421), "M")  # one_block (E3a: M)
        self.assertEqual(ps.declared_size(8_784_517), "L")  # pile10 (E3a: L)
        level = ps.resolve_level("pile10")[2]
        self.assertEqual(ps.run_args(level, [int(x, 16) for x in INPUTS]), [int(x, 16) for x in E3A["args"]])
        self.assertEqual(ps.c1_input_text([1, -1]), f"[1 {ps.P - 1}]\n")

    def test_job_output_is_atlantics_output(self):
        # The output `translateFactHash` re-hashes: E3a's recorded one, from the job's own fields.
        job = {"level": "pile10", "inputs": INPUTS, "outputs": E3A["outputs"],
               "run": {"child_program_hash": E3A["run"]["child_program_hash"]}}
        self.assertEqual(ps.job_output(job), E3A_OUTPUT)

    def test_program_output(self):
        self.assertEqual(ps.parse_program_output("Program Output : [1 2\n3]\n"), [1, 2, 3])
        with self.assertRaises(ps.ProveError):
            ps.parse_program_output("nothing")


if __name__ == "__main__":
    unittest.main()
