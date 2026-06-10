#!/usr/bin/env bash
# Kills all active queue-flood YARN apps on the cluster.
#
# These apps are raw YARN applications launched by the orchestrator in cluster
# mode — they are NOT Dataproc jobs, so `gcloud dataproc jobs kill` cannot reach
# them. This script submits a small Dataproc job that runs `yarn application
# -kill` from the master node, which is the only way to reach YARN on a cluster
# with internal_ip_only=true (no external IP / SSH access).

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

echo "Uploading yarn_kill.py to gs://$BUCKET_NAME/ ..."
gcloud storage cp spark_files/yarn_kill.py gs://$BUCKET_NAME/
echo ""

echo "Submitting kill job to $CLUSTER ..."
gcloud dataproc jobs submit pyspark gs://$BUCKET_NAME/yarn_kill.py \
    --cluster="$CLUSTER" \
    --region="$REGION"
