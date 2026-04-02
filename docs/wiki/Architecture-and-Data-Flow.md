# Architecture and Data Flow

## Overview

`nix-cluster` has four primary runtime responsibilities:

1. Receive update triggers.
2. Decide whether a node should rebuild.
3. Report and aggregate service health.
4. Bootstrap and enroll nodes.

The runtime is driven from NixOS module options, not ad hoc environment assumptions.

---

## High-level architecture

```mermaid
flowchart LR
    subgraph Config
        A["services.nix-cluster.*"]
        B["flake.nix module"]
        C["/etc/nops-runtime-config.json"]
    end

    subgraph Triggers
        D["Matrix listener"]
        E["Webhook listener"]
    end

    subgraph Reconciliation
        F["UpdateManager"]
        G["Controller hook"]
        H["git fetch/reset/diff"]
        I["nixos-rebuild"]
    end

    subgraph HA
        J["ServiceReporter"]
        K["etcd runtime store"]
        L["ClusterMonitor"]
        M["Prometheus textfile metrics"]
        N["cluster-state.json"]
    end

    A --> B --> C
    C --> D
    C --> E
    C --> F
    C --> J
    C --> L
    D --> F
    E --> F
    F --> H --> I
    F --> G
    J --> K
    J --> M
    J --> N
    K --> L
    L --> N
```

---

## Configuration pipeline

### Step 1: options are declared in Nix

The NixOS module in `flake.nix` exposes `services."nix-cluster".*` options.

These options define:

- controller behavior
- trigger behavior
- update behavior
- HA behavior
- observability behavior
- module toggles
- file paths

### Step 2: options are serialized

The module writes a normalized runtime JSON file at:

- `/etc/nops-runtime-config.json`

This file becomes the operational contract between Nix and the runtime.

### Step 3: services consume the JSON

The Python services and several shell tools read the same runtime config file.

That gives consistent runtime behavior across:

- listeners
- update manager
- health reporting
- fleet status tools
- heartbeat checks

---

## Trigger architecture

## Matrix path

```mermaid
sequenceDiagram
    participant Matrix as Matrix room
    participant Listener as MatrixListener
    participant Updater as UpdateManager
    participant Git as local repo checkout
    participant Rebuild as nixos-rebuild

    Matrix->>Listener: room message
    Listener->>Listener: match trigger keywords
    Listener->>Updater: perform_update(event_id)
    Updater->>Git: git fetch
    Updater->>Git: git diff
    Updater->>Rebuild: optional rebuild
```

The Matrix listener:

- connects to the configured homeserver
- watches a specific room
- checks message text for trigger keywords
- forwards qualifying events to the updater

## Webhook path

```mermaid
sequenceDiagram
    participant GitHost as Forgejo/GitHub/GitLab
    participant Webhook as WebhookServer
    participant Updater as UpdateManager
    participant Git as local repo checkout
    participant Rebuild as nixos-rebuild

    GitHost->>Webhook: POST /webhook
    Webhook->>Webhook: parse payload
    Webhook->>Webhook: ignore skip marker if present
    Webhook->>Updater: perform_update(trigger_id)
    Updater->>Git: git fetch
    Updater->>Git: git diff
    Updater->>Rebuild: optional rebuild
```

The webhook listener also supports periodic controller reconciliation on controller nodes.

---

## Update manager behavior

`UpdateManager` is the reconciliation engine.

It is responsible for:

- fetching from the configured remote
- diffing against the configured branch ref
- deciding whether a rebuild is required
- running the controller script on controller nodes
- waiting for controller-generated changes on workers
- executing the configured rebuild commands

### Controller path

```mermaid
flowchart TD
    A["Trigger received"] --> B["git fetch"]
    B --> C["git diff"]
    C --> D["Controller node"]
    D --> E["git reset --hard branchRef"]
    E --> F["materialize controller script"]
    F --> G["execute controller hook"]
    G --> H["git fetch again"]
    H --> I["force rebuild path"]
    I --> J["run rebuild commands"]
```

### Worker path

```mermaid
flowchart TD
    A["Trigger received"] --> B["git fetch"]
    B --> C["git diff"]
    C --> D["Worker node"]
    D --> E["sleep workerWaitSeconds"]
    E --> F["git fetch again"]
    F --> G["recalculate changed paths"]
    G --> H{"relevant changes?"}
    H -- no --> I["git reset and exit"]
    H -- yes --> J["git reset and rebuild"]
```

### Rebuild scope

By default, relevant path prefixes include:

- `nodes/<hostname>/`
- `groups/`
- `modules/`
- `deployments.json`
- `secrets/`
- `scripts/`
- `flake.nix`
- `flake.lock`

This keeps workers from rebuilding on changes that do not affect them.

---

## HA and observability architecture

## ServiceReporter

`ServiceReporter` runs locally and samples service health.

It:

- queries `systemctl show`
- computes a health boolean
- writes local JSON snapshots
- writes Prometheus textfile metrics
- optionally publishes health state into etcd

### Reporter data flow

```mermaid
flowchart LR
    A["systemd units"] --> B["ServiceReporter"]
    B --> C["/var/lib/nops/ha/service-health.json"]
    B --> D["/var/lib/nops/metrics/service-health.prom"]
    B --> E["/nix-cluster/health/... in etcd"]
```

## ClusterMonitor

`ClusterMonitor` runs on controllers and aggregates etcd reports.

It:

- reads all reported service health entries
- marks reports healthy, unhealthy, or stale
- selects a recommended target per service
- writes aggregated local cluster state
- writes cluster metrics

### Aggregation flow

```mermaid
flowchart LR
    A["etcd service-health keys"] --> B["ClusterMonitor"]
    B --> C["group reports by service"]
    C --> D["mark stale/unhealthy/healthy"]
    D --> E["choose recommended target"]
    E --> F["/var/lib/nops/ha/cluster-state.json"]
    E --> G["/var/lib/nops/metrics/cluster-state.prom"]
```

---

## Worker heartbeat path

Workers can optionally run a heartbeat timer that checks controller reachability.

```mermaid
flowchart TD
    A["systemd timer"] --> B["controller-heartbeat.sh"]
    B --> C["read controller.monitor.targets"]
    C --> D["ping each target in order"]
    D --> E["write controller-status.json"]
    E --> F["emit journal event if state changed"]
```

This is reachability tracking only. It is not a failover engine and it does not directly trigger rebuilds.

---

## Installer and enrollment architecture

The installer path is centered on `setup.sh`.

It performs:

- install-time config parsing
- service account preparation
- repo clone/bootstrap
- template rendering
- SOPS setup
- fleet structure creation
- first rebuild
- optional bootstrap actions like Forgejo and Cloudflare provisioning

### Enrollment flow

```mermaid
flowchart TD
    A["nops-install"] --> B["setup.sh"]
    B --> C["parse CLI or JSON config"]
    C --> D["prepare nix-cluster account and keys"]
    D --> E["clone or initialize fleet repo"]
    E --> F["render node/group/module templates"]
    F --> G["prepare secrets and SOPS metadata"]
    G --> H["commit and push"]
    H --> I["nixos-rebuild switch"]
    I --> J["optional bootstrap actions"]
```

---

## Shell tooling map

| Tool | Purpose |
|---|---|
| `nops-install` | Bootstrap or enroll a node |
| `nops-observe` | Inspect local service state and journals |
| `nops-node` | Run observability commands on remote nodes |
| `nops-fleet-status` | Collect fleet-wide node state |
| `nops-fleet-watch` | Poll fleet state and display changes |
| `nops-controller-heartbeat` | Record worker->controller reachability |

---

## Packaging model

The flake builds wrapped executables for:

- listeners
- HA helpers
- shell tools
- installer tooling

This means runtime dependencies are injected by package wrappers rather than relying on ambient PATH state.

---

## Design principles

`nix-cluster` follows a few core principles:

- declarative runtime options
- controller/worker role separation
- shared normalized runtime config
- small Python runtime surface
- shell reserved for installer and ops tooling
- Git-driven desired state
- SOPS-managed secrets

---

## Next page

Continue with [Configuration Reference](Configuration-Reference.md).
