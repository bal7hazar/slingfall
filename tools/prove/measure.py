#!/usr/bin/env python3
"""E1L: run one command, report wall time, exit status and peak RSS (a `/usr/bin/time -v`
substitute: ru_maxrss of the waited child = "Maximum resident set size"). Also samples the
cgroup's memory.current every 0.5 s to record the peak of the whole unit.

usage: measure.py <label> <log> [KEY=VAL...] -- <cmd...>
"""
import os, resource, subprocess, sys, threading, time

label, log = sys.argv[1], sys.argv[2]
cmd = sys.argv[sys.argv.index("--") + 1:]
# Optional KEY=VAL arguments between <log> and `--` are set in the child's environment.
for kv in sys.argv[3:sys.argv.index("--")]:
    k, v = kv.split("=", 1)
    os.environ[k] = v
cg = open("/proc/self/cgroup").read().strip().split("::")[-1]
cur_path = f"/sys/fs/cgroup{cg}/memory.current"
max_path = f"/sys/fs/cgroup{cg}/memory.max"
def rd(p):
    try:
        return open(p).read().strip()
    except OSError:
        return "?"
base = rd(cur_path)
peak = [0]
stop = False
def sample():
    while not stop:
        v = rd(cur_path)
        if v.isdigit():
            peak[0] = max(peak[0], int(v))
        time.sleep(0.5)
t = threading.Thread(target=sample, daemon=True); t.start()
t0 = time.time()
with open(log, "w") as f:
    p = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=os.environ)
wall = time.time() - t0
stop = True
ru = resource.getrusage(resource.RUSAGE_CHILDREN)
line = (f"{label}: exit={p.returncode} wall={wall:.1f}s maxrss={ru.ru_maxrss/1048576:.2f}GiB "
        f"cgroup={cg} memory.max={rd(max_path)} cgroup_base={(int(base)/2**30 if base.isdigit() else -1):.2f}GiB "
        f"cgroup_peak_sampled={peak[0]/2**30:.2f}GiB")
print(line)
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "results.txt"), "a") as f:
    f.write(line + "\n")
