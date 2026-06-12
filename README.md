# Dataproc SRE Lab

A GCP lab environment built for **chaos**. 

This serves as a practical testbed for practicing SRE alerting, debugging infrastructure plumbing, and untangling Spark/Hadoop internals on a production-hardened Dataproc cluster. 

**The goal here is simple:** deploy a real cluster, intentionally break it, and diagnose the fallout from the outside in. Whether saturating the YARN queue, inducing Out-of-Memory (OOM) errors, or simulating silent network failures, this repository provides a way to watch alerts fire and trace issues down to their root cause.

---

## What This Is

This is a **live troubleshooting and alerting testbed**, not just a reference architecture. The infrastructure is designed to support intentional failure scenarios across two main domains:

1. **Infrastructure & "Serverless" Plumbing:** Testing how Dataproc reacts when IAM permissions are stripped, VPC egress is blocked, or strict CPU quota limits are hit.
2. **Spark & YARN Observability:** Flooding queues, causing massive shuffles, and observing autoscaling behaviors using Preemptible (Spot) VMs.

> **Note on Architecture:** This cluster is deliberately production-hardened (private VPC, no external IPs, least-privilege IAM, Cloud NAT). This is because alert behavior and error logs on a "softened," fully open cluster rarely generalize to real-world SRE environments. The hardening is a necessary constraint for realistic learning, not the main point of the repo.

---

## What This Explores (and the rationale behind it)

### 1. Infrastructure as the Root Cause
Most "Dataproc issues" are actually VPC, DNS, or IAM issues in disguise. This lab simulates these exact failures, like removing `roles/storage.objectViewer` or blocking Google API egress, to document the specific error signatures left behind in the logs.

### 2. The "Three Schedulers" Problem & YARN Queueing
A key objective was to understand why the YARN *pending* state is so difficult to trigger. Investigation revealed that Dataproc, YARN, and Spark each have their own queues, concurrency limits, and visibility into pending work:
* Jobs stuck in the Dataproc Jobs API queue never create a YARN application, making them completely invisible to `cluster_yarn_apps{status="pending"}`. 
* To generate real YARN pending apps, it is necessary to bypass Dataproc's scheduler entirely *(This pattern is documented in [`test/DATAPROC_YARN_SPARK.md`](test/DATAPROC_YARN_SPARK.md))*.

### 3. What Fast-Burn Really Means in Cloud Monitoring
This lab validates Multi-Window Burn Rate math in practice. The alerts use `avg_over_time([1h])` with `duration = "0s"`. Because Cloud Monitoring averages only data points that exist (rather than padding missing history with zeros), it becomes possible to observe how a sudden spike in pending apps immediately pushes the 1-hour average above the threshold. The lab demonstrates firsthand how an alert can fire in ~4 minutes—a massive burn rate—even though the window is an hour wide.

### 4. Spark Observability (The Operator View)
For SREs, the primary focus is not writing ETL code, but ensuring the ETL code doesn't overwhelm the cluster. Using the Component Gateway, Spark UI, and YARN UI, this setup helps in identifying the visual signatures of underlying code issues from the outside:
* **Data Skew:** Identifying when one executor is doing 90% of the work.
* **OOMs:** Inducing and diagnosing failures by purposely suffocating `spark.executor.memory`.
* **Resource Starvation:** Watching `PENDING` states stack up in YARN to visualize autoscaling triggers.

---

## Architecture

```
                        ┌────────────────────────────────────────────┐
                        │  Custom VPC  (10.10.0.0/24)                │
                        │                                            │
                        │  ┌──────────────┐   ┌───────────────────┐  │
                        │  │ Master node  │   │   Worker nodes    │  │
                        │  │ e2-standard-2│   │   2× e2-standard-2│  │
                        │  └──────────────┘   │  2× preemptible   │  │
                        │         │           └───────────────────┘  │
                        │         │  internal-only traffic           │
                        │  ┌──────▼──────────────────────────────┐   │
                        │  │  Cloud NAT  (outbound internet only)│   │
                        │  └─────────────────────────────────────┘   │
                        │                                            │
                        │  Private Google Access → GCS / APIs        │
                        └────────────────────────────────────────────┘
                                          │
                        ┌─────────────────▼──────────────────────────┐
                        │  Cloud Monitoring                          │
                        │  Queue Fast Burn Alert (fires in ~4 min)   │
                        └────────────────────────────────────────────┘
```

### Security design

| Control | Detail |
|---|---|
| No external IPs | `internal_ip_only = true` on all cluster VMs |
| Private Google Access | Subnet routes GCS / API traffic internally via PGA |
| Cloud NAT | Outbound internet allowed; no inbound path |
| Dedicated service account | Least-privilege: `roles/dataproc.worker` + `roles/storage.objectAdmin` only |
| Firewall | Internal traffic only (`10.10.0.0/24`); no ingress from public internet |

> **Note:** `networking.tf` contains a commented-out egress-blocking firewall rule. Enabling it causes `terraform apply` to fail after ~28 minutes — the Dataproc control plane loses its connection to the cluster API.

---

## The alert

**Metric:** `dataproc.googleapis.com/cluster/yarn/apps{status="pending"}`

**PromQL condition:**
```promql
avg_over_time(pending[1h]) > 2  AND  avg_over_time(pending[5m]) > 2
```

The `[1h]` window detects sustained saturation. The `[5m]` window acts as a recency guard — the alert does not re-fire from historical data unless `pending` is actively elevated right now. Together they produce a fast-burn signal that fires in ~4 minutes at a **14.4× burn rate** (`60 min / 4.17 min`).

Notifications go to `var.email_address`.

---

## Testing

All test scripts live in `test/` and read from `test/.env`.

```bash
cd test
cp .env.example .env
# edit .env: set BUCKET_NAME to your staging bucket
```

### Validate the cluster

Submits `test_cluster.py`, which runs two checks:
1. **Cloud NAT** — opens an outbound connection to a public IP echo service and prints the NAT gateway's external IP.
2. **Private Google Access + IAM** — writes a small CSV to the GCS staging bucket to confirm the service account and PGA routing are working.

```bash
./submit_job.sh
```

### Trigger the Queue Fast Burn alert

Submits a single orchestrator job that fires `NUM_BLOCKING_JOBS` (default 15) heavyweight cluster-mode YARN apps directly at the YARN scheduler, bypassing Dataproc's master job queue. Only ~4 fit across the 4 workers at once; the rest stack up as `status="pending"`, tripping the alert in ~4 minutes.

```bash
./trigger_alert.sh
```

> **Why not just submit 15 jobs directly?**
> The Dataproc Jobs API caps concurrent drivers on the master (~5 on this machine type). Extra jobs queue inside Dataproc's own scheduler — they never create a YARN application and are invisible to `cluster_yarn_apps{status="pending"}`. See [`test/DATAPROC_YARN_SPARK.md`](test/DATAPROC_YARN_SPARK.md) for the full explanation.

Monitor the metric the alert reads:

```bash
gcloud monitoring time-series list \
  --filter='metric.type="dataproc.googleapis.com/cluster/yarn/apps" AND metric.labels.status="pending"'
```

### Kill the flood apps early

The launched apps are raw YARN applications — `gcloud dataproc jobs kill` cannot reach them. This script submits a Dataproc job that runs `yarn application -kill` from the master, which is the only approach on an `internal_ip_only` cluster:

```bash
./yarn_kill.sh
```

Apps also self-terminate after `SLEEP_SECONDS` (default 3600 s = 1 hour).

### Test file reference

| File | Purpose |
|---|---|
| `spark_files/test_cluster.py` | Validates Cloud NAT and GCS access |
| `spark_files/orchestrator.py` | Launches N cluster-mode YARN apps to flood the queue |
| `spark_files/queue_block.py` | Heavyweight blocking AM — holds a worker node for N seconds |
| `spark_files/yarn_kill.py` | Kills all `queue-flood-*` YARN apps via `yarn application -kill` |
| `submit_job.sh` | Uploads and submits `test_cluster.py` |
| `trigger_alert.sh` | Uploads and submits the orchestrator to trigger the alert |
| `yarn_kill.sh` | Uploads and submits `yarn_kill.py` to stop the flood |

### `.env` variables

| Variable | Description |
|---|---|
| `BUCKET_NAME` | GCS staging bucket name (required) |
| `TEST_FILE` | PySpark script for cluster validation (default: `test_cluster.py`) |
| `ORCHESTRATOR_FILE` | Orchestrator script (default: `orchestrator.py`) |
| `BLOCKING_FILE` | Blocking AM script (default: `queue_block.py`) |
| `NUM_BLOCKING_JOBS` | Number of YARN apps to launch for the flood (default: `15`) |
| `SLEEP_SECONDS` | How long each blocking app holds its node (default: `3600`) |

---

## Running the project

### Prerequisites

- Terraform `>= 1.5.0`
- Google Cloud SDK (`gcloud`) authenticated to your project
- A GCP project with billing enabled
- A GCS bucket for Terraform remote state

### Deploy

```bash
cp backend.hcl.example backend.hcl
# edit backend.hcl: set bucket = "your-terraform-state-bucket"
```

Create `terraform.tfvars`:

```hcl
project_id    = "your-gcp-project-id"
email_address = "you@example.com"
```

```bash
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

### Tear down

```bash
terraform destroy
```

### Sensitive files

| File | Tracked | Notes |
|---|---|---|
| `terraform.tfvars` | No — `*.tfvars` gitignored | Holds `project_id` and `email_address` |
| `test/.env` | No — `.env` gitignored | Holds `BUCKET_NAME` |
| `backend.hcl` | No — explicitly gitignored | Holds Terraform state bucket name |
| `backend.hcl.example` | Yes | Template — copy to `backend.hcl` and fill in |
| `test/.env.example` | Yes | Template — copy to `test/.env` and fill in |

---

## Post mortem links

| Incident | Report |
|---|---|
| | |