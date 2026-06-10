#!/usr/bin/env bash
# Saturates the YARN queue to trigger the Dataproc Queue Fast Burn alert.
#
# Why the obvious "submit many jobs" approach does NOT work:
#   The Dataproc Jobs API runs every job's driver on the MASTER node and caps
#   concurrent drivers (dataproc.scheduler.max-concurrent-jobs, ~5 on this 8 GB
#   master). Extra jobs sit in Dataproc's own queue (state=RUNNING, substate=
#   QUEUED, "Too many running jobs") and never create a YARN application at all —
#   so they are invisible to cluster_yarn_apps{status="pending"}. The ~5 that do
#   get a driver slot fit easily in the cluster and run, so YARN pending stays 0.
#   The queue forms in Dataproc's job queue, upstream of the YARN metric.
#
# Bypass the Dataproc job queue:
#   Submit ONE Dataproc job (the orchestrator, using a single driver slot). From
#   the master it fires NUM_BLOCKING_JOBS independent cluster-mode Spark apps
#   straight at YARN via spark-submit. Each app's driver IS its AM and is sized
#   to ~one worker node (spark.driver.memory=5g), so only ~4 fit across the 4
#   workers; the rest stack up in YARN ACCEPTED, status="pending".
#
# Alert condition (fast-burn, fires in ~4 min):
#   avg_over_time(pending[1h]) > 2  AND  avg_over_time(pending[5m]) > 2
#
# Why it fires in ~4 minutes despite the [1h] window:
#   avg_over_time([1h]) averages only the data points that actually EXIST in the
#   last hour — it does not pad missing history with zeros. With duration=0s (no
#   sustained requirement), once pending spikes to ~11 the very first data points
#   pull the 1h average above 2 immediately. Cloud Monitoring ingestion + eval lag
#   accounts for the ~4-minute delay. This is intentional: 60 min / 4.17 min ≈
#   14.4x burn rate — the alert fires early when severity is high.

set -euo pipefail

if [ -f .env ]; then
    set -a
    source .env
    set +a
else
    echo "ERROR: .env file not found"
    exit 1
fi

if [ -z "${BUCKET_NAME:-}" ]; then
    echo "ERROR: BUCKET_NAME is not set in .env"
    exit 1
fi

CLUSTER="secure-dataproc-cluster"
REGION="us-central1"
BLOCKING_URI="gs://$BUCKET_NAME/$BLOCKING_FILE"

echo "========================================================"
echo "  DATAPROC QUEUE FLOOD — ALERT TRIGGER TEST"
echo "========================================================"
echo "  Cluster : $CLUSTER ($REGION)"
echo "  YARN apps: $NUM_BLOCKING_JOBS (launched via 1 orchestrator job)"
echo "  Duration: ${SLEEP_SECONDS}s per app ($(( SLEEP_SECONDS / 60 )) min)"
echo "  Bucket  : gs://$BUCKET_NAME"
echo "========================================================"
echo ""

echo "[1/2] Uploading $BLOCKING_FILE and $ORCHESTRATOR_FILE to gs://$BUCKET_NAME/ ..."
gcloud storage cp "spark_files/$BLOCKING_FILE" "gs://$BUCKET_NAME/"
gcloud storage cp "spark_files/$ORCHESTRATOR_FILE" "gs://$BUCKET_NAME/"
echo "      Done."
echo ""

echo "[2/2] Submitting the orchestrator job ..."
# The orchestrator runs on the master (1 driver slot, no SparkContext) and loops
# spark-submit --deploy-mode cluster NUM_BLOCKING_JOBS times. Each launched app
# is an independent YARN application, so they are NOT throttled by the Dataproc
# job queue and instead compete directly for YARN scheduler capacity.
gcloud dataproc jobs submit pyspark "gs://$BUCKET_NAME/$ORCHESTRATOR_FILE" \
    --cluster="$CLUSTER" \
    --region="$REGION" \
    --async \
    -- "$NUM_BLOCKING_JOBS" "$SLEEP_SECONDS" "$BLOCKING_URI"

echo ""
echo "========================================================"
echo "  Orchestrator submitted. It will launch $NUM_BLOCKING_JOBS YARN apps."
echo ""
echo "  Only ~4 (5.6 GB) AM/driver containers fit in ~26 GB of YARN memory,"
echo "  so the remaining $(( NUM_BLOCKING_JOBS - 4 ))+ apps sit in ACCEPTED (pending)."
echo ""
echo "  NOTE: the launched apps are raw YARN apps, not Dataproc jobs, so"
echo "  'gcloud dataproc jobs list' will NOT show them. Monitor via the alert"
echo "  metric or the YARN ResourceManager UI (Component Gateway). To query the"
echo "  metric the alert reads:"
echo ""
echo "    PROJECT=\$(gcloud config get-value project)"
echo "    gcloud monitoring time-series list \\"
echo "      --filter='metric.type=\"dataproc.googleapis.com/cluster/yarn/apps\" AND metric.labels.status=\"pending\"' \\"
echo "      2>/dev/null  # or use the Monitoring API; see README"
echo ""
echo "  Cleanup: apps self-terminate after ${SLEEP_SECONDS}s. To kill early, SSH"
echo "  to the master and run: yarn application -list / yarn application -kill <id>"
echo ""
echo "  Alert fires in ~4 min (fast-burn: avg_over_time([1h]) > 2 with"
echo "  duration=0s fires as soon as the 1h average exceeds 2 — which happens"
echo "  within ~4 min of ingestion once pending spikes = 14.4x burn rate)."
echo "========================================================"
