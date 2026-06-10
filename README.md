# Secure Dataproc on GCP

Terraform configuration for a production-hardened Google Cloud Dataproc cluster.
The cluster runs on a private VPC with no external IPs, uses Cloud NAT for
outbound access, and ships with a Cloud Monitoring alert that detects YARN queue
saturation. A test suite validates the infrastructure and can reproduce the alert
condition on demand.

---

## Architecture

```
                        ┌────────────────────────────────────────────┐
                        │  Custom VPC  (10.10.0.0/24)                │
                        │                                            │
                        │  ┌──────────────┐   ┌──────────────────┐  │
                        │  │ Master node   │   │  Worker nodes    │  │
                        │  │ e2-standard-2 │   │  2× e2-standard-2│  │
                        │  └──────────────┘   │  2× preemptible  │  │
                        │         │           └──────────────────┘  │
                        │         │  internal-only traffic          │
                        │  ┌──────▼──────────────────────────────┐  │
                        │  │  Cloud NAT  (outbound internet only)  │  │
                        │  └─────────────────────────────────────┘  │
                        │                                            │
                        │  Private Google Access → GCS / APIs        │
                        └────────────────────────────────────────────┘
                                          │
                        ┌─────────────────▼──────────────────────────┐
                        │  Cloud Monitoring                           │
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

---

## Prerequisites

- Terraform `>= 1.5.0`
- Google Cloud SDK (`gcloud`)
- A GCP project with billing enabled
- A GCS bucket for Terraform remote state

---

## Getting started

### 1. Clone and configure

```bash
git clone <repo-url>
cd gc-dataproc
```

Copy the backend config template and fill in your state bucket:

```bash
cp backend.hcl.example backend.hcl
# edit backend.hcl: set bucket = "your-terraform-state-bucket"
```

Create `terraform.tfvars` with at minimum:

```hcl
project_id    = "your-gcp-project-id"
email_address = "you@example.com"
```

### 2. Initialise and deploy

```bash
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

### 3. Tear down

```bash
terraform destroy
```

---

## Infrastructure

### Networking (`networking.tf`)

| Resource | Default name | Purpose |
|---|---|---|
| VPC | `my-custom-vpc` | Isolated network, no auto-subnets |
| Subnet | `my-secure-subnet` | `10.10.0.0/24`, Private Google Access enabled |
| Cloud Router | `my-cloud-router` | Anchors the NAT gateway |
| Cloud NAT | `my-nat` | Outbound internet for the private subnet |
| Firewall | `allow-internal` | Permits all TCP/UDP/ICMP within the subnet |

### Dataproc cluster (`main.tf`)

| Setting | Default |
|---|---|
| Master | 1× `e2-standard-2` (set to 3 for HA) |
| Workers | 2× `e2-standard-2` |
| Preemptible workers | 2× `e2-standard-2`, `pd-standard` 50 GB |
| Image | Dataproc 2.1-debian11 |
| Metrics | YARN + Spark + Monitoring Agent defaults |
| Networking | Internal IPs only, Private Google Access |

### Storage (`storage.tf`)

A GCS staging bucket (`my-dataproc-staging-bucket-<project_id>`) is created for
Spark job uploads. `force_destroy = true` allows `terraform destroy` to clean it
up even if it contains objects.

### IAM (`iam.tf`)

A dedicated service account (`dataproc-worker-sa`) with two bindings:

- `roles/dataproc.worker` — required for cluster node operation
- `roles/storage.objectAdmin` — read/write access to the staging bucket

### APIs (`apis.tf`)

Terraform enables the following APIs if not already active:
- `cloudresourcemanager.googleapis.com`
- `compute.googleapis.com`
- `dataproc.googleapis.com`

### Alert (`alert.tf`)

A Cloud Monitoring alert fires when the YARN application queue is saturated.

**Metric:** `dataproc.googleapis.com/cluster/yarn/apps{status="pending"}`

**PromQL condition:**
```promql
avg_over_time(pending[1h]) > 2  AND  avg_over_time(pending[5m]) > 2
```

**Behaviour:** This is a **fast-burn alert**. `avg_over_time([1h])` with
`duration = "0s"` averages only existing data points — it does not pad missing
history with zeros. When `pending` spikes to ~11, the 1h average exceeds 2 on
the first sample. Combined with Cloud Monitoring ingestion lag, the alert fires
in **~4 minutes**, equivalent to a **14.4× burn rate** (`60 min / 4.17 min`).

The `[5m]` window acts as a recency guard — the alert does not re-fire from
historical data unless `pending` is actively elevated right now.

Notifications go to the email in `var.email_address`.

---

## Variables

| Variable | Default | Required | Description |
|---|---|---|---|
| `project_id` | — | Yes | GCP project ID |
| `email_address` | — | Yes | Alert notification email |
| `region` | `us-central1` | No | Deployment region |
| `custom_vpc` | `my-custom-vpc` | No | VPC name |
| `secure_subnet` | `my-secure-subnet` | No | Subnet name |
| `router` | `my-cloud-router` | No | Cloud Router name |
| `nat` | `my-nat` | No | Cloud NAT name |
| `allow_internal` | `allow-internal` | No | Internal firewall rule name |
| `dataproc_sa` | `dataproc-worker-sa` | No | Service account name |
| `dataproc_cluster_name` | `secure-dataproc-cluster` | No | Cluster name |
| `dataproc_master_num_instances` | `1` | No | Master count — must be `1` or `3` (HA) |
| `dataproc_master_machine_type` | `n1-standard-2` | No | Master machine type |
| `dataproc_worker_num_instances` | `2` | No | Worker count |
| `dataproc_worker_machine_type` | `n1-standard-2` | No | Worker machine type |
| `dataproc_preemptible_worker_num_instances` | `2` | No | Preemptible worker count |
| `dataproc_preemptible_worker_boot_disk_size` | `50` | No | Preemptible disk size (GB) |
| `dataproc_preemptible_worker_boot_disk_type` | `pd-standard` | No | Preemptible disk type |
| `dataproc_software_image_version` | `2.1-debian11` | No | Dataproc image version |

---

## Outputs

| Output | Description |
|---|---|
| `vpc_name` | Name of the created VPC |
| `subnet_name` | Name of the created subnet |
| `dataproc_cluster` | Name of the created Dataproc cluster |

---

## Testing

All test scripts live in `test/` and read from `test/.env`.

```bash
cd test
cp .env.example .env
# edit .env: set BUCKET_NAME to your staging bucket name
```

### Validate the cluster

Submits `test_cluster.py`, which runs two checks:
1. **Cloud NAT** — opens an outbound connection to a public IP echo service and
   prints the NAT gateway's external IP.
2. **Private Google Access + IAM** — writes a small CSV to the GCS staging bucket
   to confirm the service account and PGA routing are working.

```bash
./submit_job.sh
```

```bash
# Watch the output
gcloud dataproc jobs list --cluster=secure-dataproc-cluster --region=us-central1
```

### Trigger the Queue Fast Burn alert

Submits a single orchestrator job that fires `NUM_BLOCKING_JOBS` (default 15)
heavyweight cluster-mode YARN apps directly at the scheduler, bypassing
Dataproc's master job queue. Only ~4 fit across the 4 workers at once; the rest
stack up as `status="pending"`, tripping the alert in ~4 minutes.

```bash
./trigger_alert.sh
```

> **Why not just submit 15 jobs directly?**
> The Dataproc Jobs API caps concurrent drivers on the master (~5 on this machine
> type). Extra jobs queue inside Dataproc's own scheduler — they never create a
> YARN application and are invisible to `cluster_yarn_apps{status="pending"}`.
> See [`test/DATAPROC_YARN_SPARK.md`](test/DATAPROC_YARN_SPARK.md) for the full
> explanation.

Monitor the metric the alert reads:

```bash
gcloud monitoring time-series list \
  --filter='metric.type="dataproc.googleapis.com/cluster/yarn/apps" AND metric.labels.status="pending"'
```

### Kill the flood apps early

The launched apps are raw YARN applications — `gcloud dataproc jobs kill` cannot
reach them. This script submits a Dataproc job that runs `yarn application -kill`
from the master, which is the only approach on an `internal_ip_only` cluster:

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

## Sensitive files

| File | Tracked | Notes |
|---|---|---|
| `terraform.tfvars` | No — `*.tfvars` gitignored | Holds `project_id` and `email_address` |
| `test/.env` | No — `.env` gitignored | Holds `BUCKET_NAME` |
| `backend.hcl` | No — explicitly gitignored | Holds Terraform state bucket name |
| `backend.hcl.example` | Yes | Template — copy to `backend.hcl` and fill in |
| `test/.env.example` | Yes | Template — copy to `test/.env` and fill in |

---

## Further reading

[`test/DATAPROC_YARN_SPARK.md`](test/DATAPROC_YARN_SPARK.md) covers:

- How Dataproc, YARN, and Spark operate as three nested schedulers each with
  their own queue
- Why Spark `client` vs `cluster` deploy mode is central to the alert design
- What `cluster_yarn_apps{status="pending"}` actually measures and what it misses
- Why submitting many jobs directly never triggers the alert
- How the orchestrator pattern bypasses all of these constraints
- The fast-burn semantics of `avg_over_time([1h])` with `duration = "0s"`
