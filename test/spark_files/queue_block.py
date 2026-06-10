'''
Blocking app for the Queue Fast Burn alert test.

Launched in YARN **cluster** mode by orchestrator.py, so this script runs as the
ApplicationMaster (driver) on a worker node. With spark.driver.memory sized to
~one node, only ~4 of these AMs fit across the 4 workers; every additional app
sits in YARN ACCEPTED state = cluster_yarn_apps{status="pending"}, which is what
the Dataproc Queue Fast Burn alert fires on.

It creates a SparkContext (so the AM does not time out via spark.yarn.am.waitTime)
and then simply holds the AM container by sleeping in the driver for BLOCK_SECONDS
— it deliberately does not depend on executors, so the app keeps holding its node
whether or not executor containers are ever granted.

Usage (invoked by orchestrator.py, not directly):
    spark-submit --deploy-mode cluster queue_block.py [block_seconds]
'''
import sys
import time

from pyspark.sql import SparkSession

BLOCK_SECONDS = int(sys.argv[1]) if len(sys.argv) > 1 else 5400  # 90 min default

# Creating the context registers the AM with YARN and keeps it from timing out.
spark = SparkSession.builder.appName("QueueFlood-BlockingAM").getOrCreate()

print(f"[queue_block] AM up; holding this node for {BLOCK_SECONDS}s "
      f"({BLOCK_SECONDS / 60:.1f} min)", flush=True)

# The driver IS the AM in cluster mode, so sleeping here holds the AM container
# (spark.driver.memory) for the full duration — no executors required.
time.sleep(BLOCK_SECONDS)

print("[queue_block] done, releasing node", flush=True)
spark.stop()
