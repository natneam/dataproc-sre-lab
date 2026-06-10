'''
Orchestrator for the Queue Fast Burn alert test.

Runs as a SINGLE Dataproc job (one master driver slot), so it never hits the
Dataproc "Too many running jobs" master queue throttle. From the master it then
fires NUM_APPS independent cluster-mode Spark apps straight at YARN via
spark-submit, bypassing the Dataproc job queue entirely.

Each launched app (queue_block.py) is a heavyweight AM that holds ~one worker
node and sleeps. Only ~4 fit across the 4 workers, so the remaining NUM_APPS - 4
apps pile up in YARN ACCEPTED state = cluster_yarn_apps{status="pending"} — the
metric the Dataproc Queue Fast Burn alert evaluates.

This script intentionally does NOT create a SparkContext, so the orchestrator
itself consumes no YARN resources — it is purely a launcher.

Args (passed positionally by trigger_alert.sh):
    1: NUM_APPS       number of blocking YARN apps to launch
    2: BLOCK_SECONDS  how long each app holds its node
    3: BLOCKING_URI   gs:// path to queue_block.py
'''
import shutil
import subprocess
import sys

NUM_APPS = int(sys.argv[1])
BLOCK_SECONDS = sys.argv[2]
BLOCKING_URI = sys.argv[3]

# Locate spark-submit on the Dataproc master.
SPARK_SUBMIT = shutil.which("spark-submit") or "/usr/lib/spark/bin/spark-submit"

# Per-app sizing for e2-standard-2 workers (yarn.nodemanager.resource.memory-mb
# = 6554m/node). driver.memory=5g -> AM container ~5.6 GB, which fits one node
# but leaves no room for a second AM there, so at most 4 AMs run cluster-wide.
# dynamicAllocation=false + waitAppCompletion=false: hold resources, return fast.
COMMON_CONF = [
    "--master", "yarn",
    "--deploy-mode", "cluster",
    "--conf", "spark.yarn.submit.waitAppCompletion=false",
    "--conf", "spark.dynamicAllocation.enabled=false",
    "--conf", "spark.driver.memory=5g",
    "--conf", "spark.driver.cores=2",
    "--conf", "spark.executor.instances=1",
    "--conf", "spark.executor.memory=1g",
]

print(f"[orchestrator] using {SPARK_SUBMIT}", flush=True)
print(f"[orchestrator] launching {NUM_APPS} cluster-mode apps "
      f"({BLOCK_SECONDS}s each) from {BLOCKING_URI}", flush=True)

launched = 0
for i in range(NUM_APPS):
    cmd = [SPARK_SUBMIT, "--name", f"queue-flood-{i}"] + COMMON_CONF + [
        BLOCKING_URI, str(BLOCK_SECONDS),
    ]
    print(f"[orchestrator] launching app {i + 1}/{NUM_APPS} ...", flush=True)
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        launched += 1
    else:
        print(f"[orchestrator] app {i + 1} submit failed "
              f"(rc={result.returncode}):", flush=True)
        print(result.stdout, flush=True)
        print(result.stderr, flush=True)

print(f"[orchestrator] submitted {launched}/{NUM_APPS} apps; "
      f"~4 will run and the rest stay YARN-pending.", flush=True)
