# nix-cluster Wiki

## What `nix-cluster` is

`nix-cluster` is a GitOps control plane for NixOS fleets.

It is designed to let a fleet of NixOS machines converge from a shared Git repository while keeping node-specific rebuild decisions, controller-only orchestration, service health reporting, and installer automation in one system.

`nix-cluster` is the public control-plane project.

Your fleet repository is separate and private. The public project explains the engine, packaging, runtime, installer, and integration model. Private inventory, node definitions, secrets, and environment-specific operations belong in the fleet repository.

---

## Core capabilities

- Git-triggered fleet reconciliation
- Matrix and webhook trigger support
- Controller-only pre-rebuild orchestration
- Worker-side selective rebuilds
- SOPS-native secret handling
- Optional etcd-backed HA state
- Prometheus textfile metrics
- Optional Loki/Promtail integration
- Bootstrap and remote enrollment workflows
- Fleet inspection tooling

---

## How to read this wiki

Start here, then continue in this order:

1. [Architecture and Data Flow](Architecture-and-Data-Flow.md)
2. [Configuration Reference](Configuration-Reference.md)
3. [Operations and Enrollment](Operations-and-Enrollment.md)

---

## Project structure

The important parts of the repository are:

- `flake.nix` — package definitions and the NixOS module
- `src/nix_cluster/` — Python runtime
- `src/*.sh` — shell tooling and installer logic
- `templates/` — generated fleet scaffolding templates
- `docs/` — design and operator documentation

---

## Runtime model in one diagram

```mermaid
flowchart TD
    A[services.nix-cluster.* options] --> B[flake.nix NixOS module]
    B --> C[/etc/nops-runtime-config.json]
    C --> D[Matrix listener]
    C --> E[Webhook listener]
    C --> F[Update manager]
    C --> G[Service reporter]
    C --> H[Cluster monitor]
    C --> I[Shell observability tools]
    D --> F
    E --> F
    F --> J[git fetch / diff / reset]
    J --> K[nixos-rebuild switch]
    G --> L[JSON + Prometheus metrics]
    G --> M[etcd runtime store]
    M --> H
    H --> N[cluster-state outputs]
```

---

## Main concepts

### Fleet repository

The fleet repository is the desired-state source of truth.

Typical contents:

- per-node configuration
- shared groups and modules
- encrypted secrets
- deployment inventory
- installer templates

### Controller node

A controller can:

- run a pre-rebuild hook
- provision or update shared state
- publish inventory or join state
- run HA aggregation
- bootstrap additional nodes

### Worker node

A worker usually:

- receives the same Git trigger
- waits briefly for controller-generated state to land
- re-fetches upstream
- rebuilds only if the changed paths affect that node

### Runtime configuration

The runtime does not infer behavior from many separate files at startup.

Instead, the NixOS module serializes service options into `/etc/nops-runtime-config.json`, and the runtime reads that file as the single normalized source for operational settings.

---

## Runtime components

### Python runtime

The Python runtime is intentionally compact and currently lives in 8 files:

- `config.py`
- `core.py`
- `runtime.py`
- `update.py`
- `listener.py`
- `webhook.py`
- `ha.py`
- `__init__.py`

### Shell tools

The shell layer provides:

- installer and enrollment logic
- local and remote observability tools
- fleet status collection
- fleet status watching
- worker heartbeat checks

---

## What `nix-cluster` does not own

`nix-cluster` is not your private fleet repository.

It does not contain:

- your real encrypted secrets
- your real host inventory
- your production node definitions
- your private domain or token values
- your homelab-specific policy decisions

Those belong in the private fleet repo.

---

## Recommended public/private split

### Public repo: `nix-cluster`

Document here:

- architecture
- runtime model
- option reference
- installation model
- operational patterns
- examples and templates

### Private repo: fleet repo

Document there:

- node inventory
- migrations
- rollout steps
- host-specific caveats
- secrets workflows
- environment-specific recovery procedures

---

## Next page

Continue with [Architecture and Data Flow](Architecture-and-Data-Flow.md).
