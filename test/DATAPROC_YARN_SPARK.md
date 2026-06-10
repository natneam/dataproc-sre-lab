# Dataproc, YARN & Spark — How They Fit Together, and Why the Alert Test Needs an Orchestrator By Claude

This document explains the three layers involved when you run a job on this
cluster — **Dataproc**, **YARN**, and **Spark** — how a job actually flows
through them, and why triggering the *Queue Fast Burn* alert required the
indirection of an "orchestrator" job (`spark_files/orchestrator.py`) instead of
simply submitting many jobs in a loop.

Everything here is grounded in the real configuration and behavior of the
cluster defined in this repo (4× `e2-standard-2` workers, `us-central1`).

---

## 1. The three layers

Think of it as three nested schedulers, each with its own queue. A job has to
clear **all three** to actually start doing work.

```
┌──────────────────────────────────────────────────────────────────────┐
│ 1. DATAPROC  (Google-managed control plane + agent on the master)      │
│    - You talk to it: `gcloud dataproc jobs submit ...`                 │
│    - Runs a job "driver" process on the MASTER node                    │
│    - Has its OWN queue: limits concurrent drivers per master           │
│    ┌──────────────────────────────────────────────────────────────┐   │
│    │ 2. YARN  (Hadoop's cluster resource manager)                   │   │
│    │    - Hands out "containers" (memory + vCPU) on WORKER nodes     │   │
│    │    - Has its OWN queue: apps wait here for resources            │   │
│    │    ┌────────────────────────────────────────────────────────┐  │   │
│    │    │ 3. SPARK  (the distributed compute framework)            │  │   │
│    │    │    - A "driver" coordinates "executors"                  │  │   │
│    │    │    - Both driver & executors run INSIDE YARN containers  │  │   │
│    │    └────────────────────────────────────────────────────────┘  │   │
│    └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

The crucial insight for this whole exercise: **each layer has a separate queue,
and our alert only watches the YARN one.** A job can be "stuck waiting" in the
Dataproc layer and never even reach YARN — invisible to the alert.

### 1.1 Dataproc

Dataproc is Google Cloud's managed Hadoop/Spark service. It provisions the VMs
(one master + N workers), installs Hadoop/YARN/Spark, and runs an **agent** on
the master node. When you run `gcloud dataproc jobs submit`, the request goes to
the Dataproc control plane, which tells the master agent to **launch the job's
driver process on the master node**.

Key point: the Dataproc *job* is a wrapper. Its lifecycle (PENDING → SETUP_DONE
→ RUNNING → DONE) describes the *driver process on the master*, **not** the YARN
application that driver may create.

### 1.2 YARN (Yet Another Resource Negotiator)

YARN is the cluster's resource manager. It owns all the memory and CPU on the
**worker** nodes and hands it out in units called **containers**. Its two parts:

- **ResourceManager (RM)** — one per cluster (on the master). Maintains the queue
  of applications and decides who gets containers.
- **NodeManager (NM)** — one per worker. Launches and monitors containers on its
  node.

On this cluster each worker NodeManager advertises
`yarn.nodemanager.resource.memory-mb = 6554` (≈6.4 GB) and
`yarn.nodemanager.resource.cpu-vcores = 2`. With 4 workers that is:

```
Total YARN capacity ≈ 4 × 6554 MB ≈ 26 GB  and  4 × 2 = 8 vCPU
Max single container = yarn.scheduler.maximum-allocation-mb = 6554 MB (one node)
```

> Note: by default YARN's CapacityScheduler uses the `DefaultResourceCalculator`,
> which schedules on **memory only** — vCores are effectively not a binding
> constraint here. That's why all the math below is about memory.

### 1.3 Spark

Spark is the compute framework that runs *on top of* YARN. A Spark application
has two kinds of processes, and **both run inside YARN containers**:

- **Driver** — runs your `main()`/script, builds the DAG, coordinates work.
- **Executors** — do the actual distributed computation, hold cached data.

Every Spark-on-YARN app also has an **ApplicationMaster (AM)** — a small
bootstrap container that negotiates with the YARN RM for executor containers.
*Where the driver runs depends on the deploy mode* (next section), and that turns
out to be central to this whole story.

---

## 2. Spark deploy modes: `client` vs `cluster`

This is the single most important concept for understanding the alert problem.

### `client` mode (Dataproc's default for the Jobs API)

```
        MASTER node                         WORKER nodes (YARN)
   ┌─────────────────────┐            ┌──────────────────────────────┐
   │  DRIVER (your code)  │◀──────────▶│  AM (ExecutorLauncher, ~1 GB) │
   │  runs HERE, OUTSIDE  │            │  + executors (in containers)  │
   │  of YARN             │            └──────────────────────────────┘
   └─────────────────────┘
```

- The **driver runs on the master node**, as an ordinary process — **not** inside
  a YARN container, and **not** counted against YARN's memory.
- YARN only sees a tiny **AM** (the "ExecutorLauncher"), sized by
  `spark.yarn.am.memory` (cluster default here: **640 MB**), plus whatever
  executors the driver requests.
- The **Dataproc Jobs API always uses client mode** — it needs the driver on the
  master so it can stream the driver's stdout/stderr back to you (the
  `driverOutputResourceUri` you see in `gcloud dataproc jobs describe`).

Consequence: setting `spark.driver.memory` or `spark.submit.deployMode=cluster`
on a `gcloud dataproc jobs submit` call **does nothing useful** — the driver
still runs on the master in client mode, and `spark.driver.memory` there doesn't
consume any YARN container.

### `cluster` mode (what the orchestrator uses)

```
        MASTER node                         WORKER nodes (YARN)
   ┌─────────────────────┐            ┌──────────────────────────────┐
   │  spark-submit client │            │  AM == DRIVER (your code)     │
   │  submits & exits     │──────────▶ │  runs HERE, sized by          │
   │                      │            │  spark.driver.memory          │
   └─────────────────────┘            │  + executors                  │
                                       └──────────────────────────────┘
```

- The **driver runs inside a YARN container on a worker**, and *is* the AM.
- Its size is `spark.driver.memory` (+ ~10% overhead). So in cluster mode the
  driver/AM is a real, sizeable YARN allocation you control.
- The submitting client can return immediately
  (`spark.yarn.submit.waitAppCompletion=false`) and leave the app running.

This is why the orchestrator launches apps in **cluster** mode: it lets each
blocking app occupy a big, controllable chunk of a worker node (5 GB driver/AM),
which is what lets us fill the cluster and force a queue. You can only get this
mode by calling `spark-submit` yourself — the Dataproc Jobs API won't give it to
you.

---

## 3. The YARN application lifecycle — and what "pending" means

A YARN application moves through these states:

```
NEW → NEW_SAVING → SUBMITTED → ACCEPTED → RUNNING → FINISHED / FAILED / KILLED
                                  │           │
                                  │           └─ AM container is allocated &
                                  │              the AM has registered
                                  └─ app accepted by the scheduler, WAITING for
                                     its AM container to be allocated
```

The metric our alert reads, `dataproc.googleapis.com/cluster/yarn/apps`, buckets
these into a `status` label with values we confirmed live:
`{pending, running, completed, failed, killed}`.

- **`pending`** = apps in **ACCEPTED** (and SUBMITTED) — i.e. **waiting for their
  AM container to be scheduled.**
- **`running`** = apps whose AM is up (state RUNNING).

### The subtle, critical part

> An app flips from `pending`(ACCEPTED) → `running` the instant its **AM
> container** is allocated — *regardless of whether its executors have been
> scheduled.*

So if you saturate the cluster's *executor* capacity, you do **not** create
pending apps. The apps are already RUNNING (their AM got in); the executor
requests just pile up as **pending containers inside running apps** — a
*different* thing that `cluster_yarn_apps{status="pending"}` does **not** count.

**To create pending *applications*, the bottleneck must be AM/driver-container
allocation, not executor allocation.** That is precisely what the orchestrator
engineers: big (5 GB) cluster-mode drivers/AMs, of which only ~4 fit, so the
rest are stuck in ACCEPTED waiting for an AM container = `pending`.

The alert policy (`alert.tf`):

```promql
(avg_over_time(cluster_yarn_apps{status="pending"}[1h]) > 2)
and
(avg_over_time(cluster_yarn_apps{status="pending"}[5m]) > 2)
```

This is a **fast-burn alert** — it fires in ~4 minutes, not ~60 minutes.

Here is why, and it is a subtlety of how Cloud Monitoring evaluates `avg_over_time`:

`avg_over_time(metric[1h])` averages only the data points that **actually exist**
within the last hour. It does **not** pad missing history with zeros. With
`duration = "0s"` (no sustained requirement), the condition fires as soon as the
computed average exceeds 2. Once `pending` spikes to ~11, the very first few data
points pull the 1h average straight to ~11 — far above 2. Cloud Monitoring metric
ingestion and evaluation scheduling accounts for the ~4-minute observed delay.

The burn-rate interpretation: the alert fires at ~4 minutes because `pending` is
so high relative to the threshold that the budget is consumed almost instantly.
Expressed as a burn rate: `60 min / 4.17 min ≈ 14.4x` — the cluster is burning
through its scheduling budget 14.4 times faster than a "sustained 1h" baseline
would. The alert is designed to fire quickly in high-severity situations, not only
after a full hour of degradation.

The `[5m]` window serves as a recency guard: even if the `[1h]` average is still
elevated from an old event, the alert won't re-fire unless `pending` is also
actively high *right now*.

---

## 4. How one normal job flows through all three layers

`./submit_job.sh` runs a single PySpark job. Here's the full path:

1. **Dataproc**: `gcloud dataproc jobs submit pyspark ...` → control plane →
   master agent launches the driver process on the master (client mode).
   Dataproc job state: PENDING → SETUP_DONE → RUNNING.
2. **Spark (driver)**: the driver starts, creates a `SparkSession`, which asks
   YARN for an **AM** (ExecutorLauncher, ~640 MB) and then executor containers.
3. **YARN**: RM puts the app in ACCEPTED briefly, allocates the AM container
   (app → RUNNING), then allocates executor containers as capacity allows.
4. **Spark (executors)**: executors come up inside their containers and run the
   tasks the driver sends them.

For one job on an idle cluster, all of this happens in seconds. The problem only
appears when you try to create a **backlog**.

---

## 5. Why "just submit many jobs in a loop" does NOT trigger the alert

This was the original approach, and it silently fails. Here's exactly why,
layer by layer, with the numbers we measured.

### 5.1 The Dataproc master job-queue throttle (the hidden gate)

Dataproc limits how many job **drivers** run concurrently on the master, because
every client-mode driver is a JVM living in the master's RAM (this master is
`e2-standard-2` = 8 GB). The limit is `dataproc.scheduler.max-concurrent-jobs`,
derived from master memory — about **5** on this cluster.

When we submitted 15 jobs, we observed:

```
$ gcloud dataproc jobs list ... --state-filter=active --format="value(status.substate)" | sort | uniq -c
   5            ← actually executing (blank substate)
  10 QUEUED     ← state=RUNNING, substate=QUEUED
```

And describing a queued job showed:

```yaml
status:
  state: RUNNING
  substate: QUEUED
  details: 'Awaiting execution: Too many running jobs'
```

**The 10 queued jobs have not created a YARN application at all.** They're
waiting in *Dataproc's* queue for a master driver slot. They are completely
invisible to `cluster_yarn_apps` — that metric only exists once a YARN app is
created.

> Gotcha: the top-level Dataproc job state is `RUNNING` even while the job is
> actually `QUEUED` (the real status is in `substate`). Looking at
> `gcloud dataproc jobs list` and seeing "RUNNING" misled us into thinking the
> jobs were running — they weren't.

### 5.2 The ~5 that do run don't queue at YARN either

The ~5 jobs that get a master driver slot create YARN apps. But:

- Each is a **client-mode** app, so its AM is only ~640 MB–1 GB.
- ~5 tiny AMs fit trivially in 26 GB, so all of them get their AM immediately and
  go **RUNNING**.
- Their *executors* may not all fit — but as explained in §3, that produces
  *pending containers*, not *pending apps*.

Net result we measured: `pending = 0` the entire time, even with 15 jobs
submitted. The queue formed in the **Dataproc layer**, upstream of and invisible
to the **YARN metric** the alert watches.

```
15 submitted
   │
   ├─ 10  → stuck in DATAPROC queue (substate=QUEUED)   ← no YARN app, metric blind
   └─  5  → got a master driver slot → YARN app → AM ~1 GB fits → RUNNING
                                                         ← pending stays 0
```

### 5.3 Why tuning Spark properties couldn't fix it

We tried, and confirmed none of these help from `gcloud dataproc jobs submit`:

- `spark.submit.deployMode=cluster` — **ignored**; the Jobs API forces client
  mode (it must stream driver output from the master).
- `spark.driver.memory=4g` — driver runs on the master in client mode, so this
  doesn't consume a YARN container; irrelevant to scheduling.
- `spark.yarn.am.memory=4g` — does enlarge the AM, but you still can't get past
  the ~5-driver Dataproc throttle, so you never have enough simultaneous YARN
  apps to build a pending backlog.

The real bottleneck (Dataproc's master driver slots) is a *cluster agent*
setting, not something a job submission can override.

---

## 6. The fix: one orchestrator job that submits apps directly to YARN

The trick is to **stop using the Dataproc Jobs API for the flood**, and instead
go straight to YARN — which means running `spark-submit` *on the cluster*.

`spark_files/orchestrator.py` is submitted as a **single** Dataproc job, so it
only consumes **one** master driver slot (never throttled). Critically, it does
**not** create a SparkContext, so it uses **zero** YARN resources — it is purely
a launcher. From the master it loops:

```python
spark-submit \
  --master yarn --deploy-mode cluster \
  --conf spark.yarn.submit.waitAppCompletion=false \
  --conf spark.dynamicAllocation.enabled=false \
  --conf spark.driver.memory=5g \
  --conf spark.executor.instances=1 --conf spark.executor.memory=1g \
  gs://<bucket>/queue_block.py <seconds>
```

…`NUM_BLOCKING_JOBS` times. Each invocation:

- launches an **independent YARN application** directly (these are *not* Dataproc
  jobs, so the Dataproc job queue never sees them — its throttle is bypassed);
- runs in **cluster** mode, so the driver **is** the AM and occupies
  `spark.driver.memory = 5 GB` (≈5.6 GB container) on a worker node;
- with `waitAppCompletion=false`, returns immediately so the next one can launch.

```
   1 Dataproc job (orchestrator, 1 master slot, 0 YARN resources)
        │  fires N spark-submit --deploy-mode cluster
        ▼
   N independent YARN apps, each needing a ~5.6 GB AM/driver container
        │
        ├─ ~4 fit (one per ~6.4 GB node)      → RUNNING
        └─ the rest can't get an AM container → ACCEPTED = pending  ✅
```

### Why exactly ~4 run and the rest pend

```
Per-node YARN memory      = 6554 MB
AM/driver container       = 5 GB + ~512 MB overhead ≈ 5632 MB
  → exactly ONE AM fits per node (5632 < 6554), with ~900 MB left over —
    not enough for a second AM, and not enough for the 1 GB executor either.
4 worker nodes            → at most 4 AMs cluster-wide.
Launch 15 apps            → ~4 RUNNING, ~11 stuck in ACCEPTED = pending.
```

`spark.dynamicAllocation.enabled=false` ensures the running apps never release
their containers early, so the backlog persists for the full `SLEEP_SECONDS`
(default 3600 s = 60 min). The alert fires in ~4 minutes, so the apps only need
to hold the cluster long enough to keep `pending` elevated past that point — but
60 minutes provides a generous safety margin and a realistic "stuck cluster" signal.

### `queue_block.py` — what each launched app does

In cluster mode the driver IS the AM, so the blocking app just needs to hold its
node:

1. Create a `SparkSession` — this is required so the AM registers with YARN
   before `spark.yarn.am.waitTime` (default 100 s) expires; otherwise YARN would
   kill the AM for never starting a SparkContext.
2. `time.sleep(BLOCK_SECONDS)` in the driver — since the driver is the AM, this
   holds the AM container (5 GB) for the whole duration, **without depending on
   executors**. (That independence matters: the cluster is so full that executors
   often can't be scheduled, but the app keeps holding its node anyway.)
3. `spark.stop()` and exit when the time is up.

### Verified behavior

A scaled-down test (8 apps × 480 s) produced, from the live metric:

```
t=120s:  pending=4 running=1
t=160s:  pending=7 running=1   ← sustained
t=240s:  pending=7 running=1
```

`pending` held at 7 — far above the alert's `> 2` threshold.

---

## 7. Trade-offs & operational notes

The orchestrator approach is the right tool here, but it has consequences worth
knowing:

- **Visibility**: the launched apps are raw YARN apps, **not** Dataproc jobs, so
  `gcloud dataproc jobs list` will **not** show them. Observe them via:
  - the alert metric (Cloud Monitoring, `dataproc.googleapis.com/cluster/yarn/apps`,
    `status="pending"`), or
  - the **YARN ResourceManager UI** through Dataproc Component Gateway.
- **Cleanup**: apps self-terminate after `SLEEP_SECONDS`. To stop them early, SSH
  to the master and use `yarn application -list` / `yarn application -kill <id>`.
  Killing the orchestrator Dataproc job does **not** stop them — it has already
  finished (it exits as soon as it's done launching, thanks to
  `waitAppCompletion=false`).
- **The alternative we rejected (Option B)**: raise
  `dataproc.scheduler.max-concurrent-jobs` so many normal jobs reach YARN at once.
  This works in principle but requires editing the cluster's `software_config`
  (immutable → cluster **recreate**), and is capped by master RAM (too many
  client-mode drivers OOM the 8 GB master). The orchestrator needs no cluster
  changes and puts the driver load on the workers instead of the master.

---

## 8. One-paragraph summary

A job must clear three independent queues — **Dataproc** (master driver slots),
**YARN** (worker containers), and then **Spark** schedules its own tasks. The
Queue Fast Burn alert watches only the **YARN** queue
(`cluster_yarn_apps{status="pending"}` = apps in ACCEPTED waiting for an AM
container). Submitting many jobs the normal way fails because they pile up in the
**Dataproc** queue (`substate=QUEUED`, "Too many running jobs") and never create
YARN apps, while the few that get through use tiny client-mode AMs that schedule
instantly — so YARN `pending` stays 0. The orchestrator fixes this by spending a
single Dataproc job slot to fire many **cluster-mode** apps straight at YARN,
each with a 5 GB driver/AM. Only ~4 of those big AMs fit in the cluster, so the
rest sit in YARN ACCEPTED = `pending` long enough to trip the alert.
