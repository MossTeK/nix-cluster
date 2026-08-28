# nix-cluster System Specification

This document is the authoritative runtime contract for nix-cluster.  Git is
the durable desired-state source.  etcd contains observed state, scheduler
decisions, and short-lived coordination records; it is never a substitute for
Git configuration.

## Health and freshness

Workers publish a node heartbeat independently from service snapshots.  Every
service report carries a reporter instance identifier, a monotonically
increasing sequence, the observation time, and collection duration.  Missing
or stale telemetry is `unknown`, not proof that a service failed.  The
scheduler requires the configured number of consecutive fresh unhealthy
reports before moving a service.  Freshness must be no shorter than three
reporting intervals plus the collection deadline.

## Desired placement and observed ownership

Placement records under `/nix-cluster/scheduler/placement/<unit>` are versioned
state machines.  They retain the compatibility field `desired_owner` and add:

- `active_owner`: last owner committed healthy by the controller;
- `target_owner`: owner being prepared during handoff;
- `generation`: monotonically increasing handoff generation;
- `phase`: `stable`, `deactivating`, `awaiting-fence`, `activating`, or
  `verifying`;
- `phase_started_at`, `stable_since`, failure/success counters, cooldowns, and
  a transition reason.

A stale sample alone never changes a stable placement.  Stable ownership is
subject to a minimum dwell time except for confirmed failure or lease loss.
The controller requires consecutive healthy target reports before committing
the target as `active_owner`.

## Exclusive service leases and fencing

Each managed unit has at most one leased record under
`/nix-cluster/scheduler/ownership/<unit>`.  The record identifies the host,
placement generation, and observation time and is attached to an etcd lease.
A worker must hold the matching lease before starting a unit.  It stops the
unit before releasing ownership.  A dedicated keeper renews ownership every
15 seconds with a default 90-second TTL.  A timeout is an unknown renewal
result: the worker keeps the unit running only through the last server-confirmed
local lease deadline.  Confirmed conflicting ownership, confirmed expiry, or
passing that deadline stops the unit fail-closed.

During handoff the old owner stops and acknowledges inactivity before its
lease is released.  A target cannot start until it atomically acquires the
vacant ownership key.  If exclusivity cannot be proven, the transition remains
in `awaiting-fence`; nix-cluster does not risk two writers to shared storage.

## Ingress

Ingress routes only to a fresh placement's committed `active_owner` when that
owner has a matching unexpired ownership record and a fresh healthy service
report.  During a transition the previous active owner remains routable only
while all of those conditions hold.  Otherwise ingress fails closed with 503.

## Placement policy and operator moves

Per-unit Git policy may express ordered preferred nodes, minimum available
memory, maximum sustained load per CPU, estimated CPU and memory reservations,
state-storage requirements, and conservative rebalance thresholds.  Placement
uses at least three fresh resource samples.  Reservations for assigned and
activating units reduce advertised capacity before another unit is ranked.

`nix-cluster placement move <unit> <node>` submits a one-shot etcd request.
The controller validates and executes it through the same generation,
deactivation, fencing, activation, and verification state machine.  The
request never becomes a persistent override; durable preferences remain in
Git.

## Failure handling and observability

Activation and verification are bounded.  Failed targets enter a cooldown and
the scheduler may try the next eligible node after fencing remains proven.
Cluster state and metrics expose report age, reporter loop duration, placement
phase and generation, transition age, failure counters, lease ownership, and
the last successful reconciliation.  Repeated stale telemetry, ownership
churn, lease loss, fencing failure, and prolonged transitions are alertable.

## Acceptance invariants

1. Delayed-but-valid telemetry does not move or stop a healthy owner.
2. No placement generation has more than one active leased owner.
3. A target never starts before prior ownership is released or expires.
4. Controller and worker restart reconstruct state from etcd safely.
5. Shared-storage workloads fail closed when fencing cannot be proven.
6. Desired state remains in Git and private fleet data never enters the public
   module, documentation, fixtures, or logs.
