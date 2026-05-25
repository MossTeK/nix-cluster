# Project Plan: nix-cluster v3 Core Overhaul

## Agent Directives And Context
You are acting as the Lead Orchestration Agent for the `nix-cluster` project. The goal is to turn the current stack into a more opinionated, highly available GitOps platform for homelabs and small IT infrastructure.

This plan is intentionally written against the current codebase state, not an imagined clean-slate architecture. Use the existing implementation as the starting point and tighten contracts where they are already present.

## Non-Negotiable Rules
- Python handles imperative orchestration: HTTP endpoints, `systemctl`, `journalctl`, retries, failover logic, and etcd coordination.
- Nix handles declarative state: users, services, filesystems, mounts, secrets, runtime config serialization, and per-node defaults.
- Zero-password automation remains the default. Use SSH keys and `sops-nix`. Do not introduce plaintext secret workflows or password-based orchestration.
- HA behavior must be idempotent. Always verify etcd state or local system state before starting, stopping, or reassigning units.
- Work sequentially. Do not begin the next Epic until the current Epic is implemented, validated, and reported complete.

## Current State You Must Respect
1. `nix-cluster` already has an HA substrate.
   Files: `src/nix_cluster/ha.py`, `src/nix_cluster/config.py`, `flake.nix`
   Notes:
   - `ServiceReporter` already publishes service health.
   - `WorkerReconciler` already collects resource snapshots, publishes them to etcd, and reconciles managed units from placement keys.
   - `ClusterMonitor` already performs controller leadership, reads resource records, and ranks nodes by resources.
   - This means Epic 3 is primarily a contract-hardening and behavior-shaping effort, not a greenfield HA implementation.
2. Install-time filesystem choice is still spread across multiple repos.
   Files: `nixos-install/install.sh`, `nixos-install/templates/disko-zfs.nix`, `nixos-install/templates/disko-btrfs.nix`, `nixos-install/templates/disko-ext4.nix`, `nix-cluster/src/setup.sh`, `nix-cluster/src/lib/install-config.sh`
   Notes:
   - `nixos-install/install.sh` still accepts `--fs zfs|btrfs|ext4` and selects `templates/disko-${FS}.nix`.
   - `nix-cluster` enrollment metadata and worker inventory still carry `fs` fields even though the fleet currently defaults to ZFS.
3. A shared baseline already exists, but it is not yet a dedicated reusable users module.
   Files: `homelab-fleet/groups/homelab/configuration.nix`
   Notes:
   - Shared SSH, admin user, root-login restrictions, `sudo`, and SOPS defaults already live here.
   - Epic 1 should refactor and formalize this baseline instead of duplicating it.
4. `app-registry` already distinguishes official and community apps internally, but not through final, explicit flake outputs.
   Files: `app-registry/flake.nix`, `app-registry/catalog/community-modules.nix`
   Notes:
   - The current output shape is `nixosApps = { official = ...; community = ...; }`.
   - Epic 2 is about turning that into a stable public contract and tightening module expectations.
5. The live fleet is already partially HA-aware.
   Files: `homelab-fleet/groups/homelab/configuration.nix`, `homelab-fleet/nodes/node1/configuration.nix`, `homelab-fleet/nodes/node2/configuration.nix`, `homelab-fleet/nodes/node4/configuration.nix`
   Notes:
   - `node1` is the controller and local etcd server.
   - `node2` and `node4` are workers.
   - The current managed scheduler unit is `mtg-platform.service`.
   - Group-level defaults already enable ingress-related apps, while MTG is still enabled per worker node.

## Execution Model
1. Identify the owning repo and direct contract boundary before editing.
2. Prefer extending existing mechanisms over introducing a second control path.
3. When a change touches templates and generated outputs, update both sides in the same Epic.
4. After each Epic, stop and report:
   - files changed
   - contract changes introduced
   - validation completed
   - remaining blockers or migration risks
5. Do not move to the next Epic until the current Epic satisfies its acceptance criteria.

## Epic 1: Opinionated Baseline
### Goal
Standardize on ZFS as the only supported filesystem and converge all nodes on a single, reusable user baseline.

### Task 1.1: Remove Non-ZFS Install Paths
#### Repos in Scope
- `nixos-install`
- `nix-cluster`
- `homelab-fleet`

#### Required Work
1. In `nixos-install`, remove the user-facing ability to choose `btrfs` or `ext4`.
2. Delete or deprecate `templates/disko-btrfs.nix` and `templates/disko-ext4.nix`.
3. Hardcode the install flow to `disko-zfs.nix`.
4. Update CLI help text, validation logic, and documentation so the installer clearly states that ZFS is mandatory.
5. In `nix-cluster/src/setup.sh` and `nix-cluster/src/lib/install-config.sh`, remove new non-ZFS selection paths.
6. Decide whether `fs` remains as a backward-compatible field during migration.
   - Preferred outcome: reads of legacy `fs` values may continue temporarily, but all new writes normalize to `zfs`.
7. Update fleet bootstrap templates and worker inventory defaults so new nodes only emit `zfs`.

#### Important Design Constraint
Do not leave half-migrated interfaces behind. If the CLI stops accepting non-ZFS values, the JSON templates, worker metadata, docs, and help text must all agree.

#### Acceptance Criteria
- New installs can only target ZFS.
- No template or CLI path still advertises `ext4` or `btrfs` as supported.
- Enrollment-generated config no longer creates new non-ZFS metadata.
- Existing ZFS-based fleet behavior remains unchanged.

#### Validation
- Evaluate `nixos-install` after the CLI changes.
- Run the narrowest installer usage check possible, such as `--help` output or argument validation.
- Build `nix-cluster` install outputs after contract changes.
- Verify the fleet templates still evaluate after the installer metadata changes.

### Task 1.2: Standardize The User Baseline
#### Repos in Scope
- `homelab-fleet`

#### Required Work
1. Create a dedicated reusable module for the shared users baseline.
   Preferred path: `homelab-fleet/modules/core/users.nix`.
2. Move the currently shared user, SSH, and root-login restrictions out of the broad group configuration into this module where appropriate.
3. Ensure the module unconditionally defines:
   - the `nix-cluster` service account
   - the primary admin account pattern
   - root login restrictions
   - required `sudo` behavior for cluster automation
4. Keep current key sources and SOPS ownership patterns unless there is a separate migration plan.
5. Import the module from the authoritative shared baseline so controller, worker, and future storage nodes all inherit the same user model.

#### Important Design Constraint
This is a consolidation task, not a user-model redesign. Avoid mixing user baseline work with unrelated service or secret changes.

#### Acceptance Criteria
- Controller and worker nodes inherit the same user and SSH policy from one reusable module.
- Root login remains restricted.
- The `nix-cluster` service account remains compatible with current SOPS and Git workflows.
- No node-specific user duplication remains unless it is intentionally exceptional.

#### Validation
- Evaluate the affected fleet nodes.
- Confirm SOPS secret ownership and the git credential helper still point at the expected service account.

## Epic 2: App Registry v2
### Goal
Promote the registry from a small module bucket into a durable app contract with explicit official and community boundaries, plus a clear HA deployment model.

### Task 2.1: Promote Registry Outputs To A Stable Contract
#### Repos in Scope
- `app-registry`
- `homelab-fleet`

#### Required Work
1. Change `app-registry/flake.nix` to export explicit public outputs such as `officialApps` and `communityApps`.
2. Preserve compatibility with current consumers only if a staged migration requires it.
3. Define a clear metadata shape for community entries.
   At minimum include:
   - source location
   - module selector or import path
   - maintainer identity
   - review or trust status
4. Keep official apps as internally maintained modules and community apps as externally maintained sources with pinned metadata.
5. Update any docs that describe how registry consumers are expected to import modules.

#### Acceptance Criteria
- The public flake outputs make the official vs community split explicit.
- Community entries have a documented metadata contract.
- Current official modules still evaluate.

#### Validation
- Evaluate the `app-registry` flake outputs.
- Confirm the fleet flake can still consume the registry after the output rename or aliasing.

### Task 2.2: Define The Dormant HA App Contract
#### Repos in Scope
- `app-registry`
- `nix-cluster`
- `homelab-fleet`

#### Required Work
1. Document the HA app contract in the registry docs.
2. Introduce or formalize an app-level option that expresses HA intent.
   Target shape: `services.nix-cluster.apps.<appName>.ha = true`.
3. Enforce the rule that HA-enabled apps must be fully configured but not automatically started by boot-time `wantedBy` ownership.
4. Ensure the dormant unit still has:
   - binaries available
   - configuration rendered
   - secrets mapped through SOPS
   - mounts or storage dependencies defined
5. Update official app modules to follow the new contract.

#### Important Design Constraint
There must be exactly one runtime ownership model for an HA app. A service cannot be both boot-owned and controller-placed.

#### Acceptance Criteria
- HA-enabled app modules converge without auto-starting at boot.
- Non-HA app behavior remains explicit and separate.
- The contract is written down in a place contributors can follow.

#### Validation
- Evaluate at least one official HA-capable app module end to end.
- Confirm the generated unit is present but dormant when HA mode is enabled.

### Task 2.3: Integrate Registry v2 Into The Fleet
#### Repos in Scope
- `homelab-fleet`

#### Required Work
1. Update the fleet flake to consume the registry contract in its new shape.
2. Import the app modules through shared group-level configuration where that fits the intended placement model.
3. Keep node-level enablement only where the group-level abstraction is not ready yet.
4. Make sure eligible worker nodes have the dormant services rendered before controller placement logic tries to start them.

#### Acceptance Criteria
- The fleet can evaluate with the new registry outputs.
- Eligible nodes render dormant HA services before runtime placement.
- Existing ingress-related modules remain stable.

#### Validation
- Evaluate the controller and worker fleet nodes.
- Verify imports still line up with `nix-cluster` module expectations.

## Epic 3: Active HA Orchestration
### Goal
Make HA placement explicit, predictable, and observable using the current etcd-backed scheduler substrate.

### Architecture Note
The current repository already has a controller monitor, node resource publishing, and worker reconciliation path. Do not build a second orchestration system unless the design explicitly removes the first one. The preferred path is:
- controller computes desired owner
- controller publishes desired placement
- worker reconciler starts or stops the unit locally

If a direct worker API endpoint is still added, it must complement this design rather than create a second source of truth.

### Task 3.1: Normalize Worker Telemetry
#### Repos in Scope
- `nix-cluster`

#### Required Work
1. Review the current split between `ServiceReporter` and `WorkerReconciler`.
2. Decide whether service health and resource telemetry should be published by one component or remain split with a documented contract.
3. Ensure each worker publishes a stable node-state payload that includes:
   - service health or managed unit state
   - CPU load or normalized load per CPU
   - available memory
   - relevant local storage availability for runtime state
   - timestamp freshness
4. Keep the etcd key layout stable or migrate it deliberately with updated consumers.

#### Acceptance Criteria
- Controller placement decisions can rely on a documented, stable telemetry schema.
- Workers publish enough resource data to rank nodes consistently.
- Stale telemetry is detectable.

#### Validation
- Exercise the reporter or reconciler path locally.
- Verify the expected state files and etcd payloads are written.

### Task 3.2: Decide And Implement The Worker Execution Path
#### Repos in Scope
- `nix-cluster`

#### Required Work
1. Decide whether the existing worker reconciler remains the only execution path, or whether a direct `POST /ha/orchestrate/start` endpoint is still required.
2. If the endpoint is added:
   - add it to the aiohttp server in `webhook.py`
   - authenticate it
   - validate service names against an explicit allowlist or strict unit-name validation
   - use `subprocess.run(["systemctl", "start", service_name], check=True)` with no shell interpolation
   - capture stdout and stderr for logging
   - cover edge cases such as invalid unit names, inactive targets, and failed starts
3. If the endpoint is not added, document that the worker reconciler is the authoritative start path and keep controller behavior centered on placement publication.

#### Important Design Constraint
Do not create two conflicting ways to decide ownership. etcd placement remains the source of truth even if an HTTP helper exists.

#### Acceptance Criteria
- The runtime execution path for starting HA apps is explicit and safe.
- Unit-name validation is robust.
- Failed starts are observable in logs and do not silently succeed.

#### Validation
- Run narrow Python validation for the touched runtime files.
- Test success and failure cases for the execution path.

### Task 3.3: Tighten The Controller Placement Loop
#### Repos in Scope
- `nix-cluster`
- `homelab-fleet`

#### Required Work
1. Extend the controller-side logic to read the desired HA app set from the runtime config generated by Nix.
2. For each HA app, determine whether it is already healthy on an eligible node.
3. If it is not healthy anywhere:
   - rank candidate workers using the existing resource telemetry
   - prefer the best healthy or schedulable worker
   - fall back through the ranked workers in order
   - use the controller itself as the last-resort execution target
4. Emit a clear failover alert when placement changes because of a failed start or unhealthy node.
5. Ensure the worker-side state converges back into etcd so the controller does not repeatedly issue the same action.
6. Update the runtime config schema if the controller now needs an explicit declarative list of HA-managed apps or units.

#### Important Design Constraint
This controller loop must remain idempotent. It should not thrash unit ownership because of transient state or stale telemetry.

#### Acceptance Criteria
- The controller can identify that an HA app is down, choose an eligible target, and converge on a running instance.
- Failover produces an observable alert or tagged log event.
- Repeated control-loop passes do not restart already healthy services unnecessarily.

#### Validation
- Validate the ranking and placement path with the narrowest executable checks available.
- Confirm that healthy services are left alone and failed services cause ordered retries.

## Epic 4: Dedicated Storage Node Architecture
### Goal
Support small-SSD workers backed by a dedicated storage node that provides durable app data over the internal cluster network.

### Task 4.1: Create A Storage Role
#### Repos in Scope
- `homelab-fleet`

#### Required Work
1. Add a dedicated storage role or group, such as `groups/storage/configuration.nix`.
2. Define the ZFS dataset layout for persistent app data.
3. Export the datasets over NFSv4 or an equivalent network storage protocol restricted to the internal cluster network.
4. Keep storage-role configuration isolated from general worker defaults.
5. Add only the minimum firewall and service openings needed for internal storage traffic.

#### Acceptance Criteria
- The fleet has a dedicated storage role with an explicit dataset and export model.
- Storage exports are limited to the internal network.
- Existing controller and worker behavior is unaffected until an app opts into remote storage.

#### Validation
- Evaluate the storage-role configuration.
- Verify NFS export declarations and firewall rules are rendered as expected.

### Task 4.2: Add A Persistent Volume Abstraction To App Modules
#### Repos in Scope
- `app-registry`
- `homelab-fleet`

#### Required Work
1. Extend HA-capable app modules so they can declare a storage backend.
   Initial target:
   - `local`
   - `remote`
2. When `storageBackend = "remote"`, render a mount for `/var/lib/<app>` or the app-specific data path using the storage node export.
3. Ensure the mount orders correctly against `network-online.target` and before the app service.
4. Keep the dormant HA contract intact so a service can remain stopped while its storage and config are already present.
5. Update at least one real app module as the reference implementation.

#### Acceptance Criteria
- App modules can opt into remote persistent storage without ad hoc per-node glue.
- Mount ordering is explicit.
- The app remains dormant until the controller or reconciler places it.

#### Validation
- Evaluate at least one app in both local and remote storage modes.
- Confirm mount ordering and service dependency behavior are rendered in systemd.

## Cross-Cutting Deliverables
1. Keep docs updated as contracts move.
   Minimum surfaces:
   - `nix-cluster/README.md`
   - `nix-cluster/docs/`
   - `app-registry/docs/`
   - relevant `homelab-fleet/docs/`
2. When a template placeholder or runtime JSON field changes, update every direct consumer in the same Epic.
3. Preserve backward compatibility only when it reduces migration risk. Do not keep dead compatibility shims indefinitely.

## Recommended Validation Commands
Use the narrowest relevant validation for the touched repo.

- In `nix-cluster`:
  - `nix build .#default`
  - `nix build .#install`
- In `homelab-fleet`:
  - `nix build .#nixosConfigurations.node1.config.system.build.toplevel --override-input nixCluster path:/home/moss/repos/infra/nix-cluster`
  - `nix build .#nixosConfigurations.node2.config.system.build.toplevel --override-input nixCluster path:/home/moss/repos/infra/nix-cluster`
  - `nix build .#nixosConfigurations.node4.config.system.build.toplevel --override-input nixCluster path:/home/moss/repos/infra/nix-cluster`
- In `nixos-install`:
  - evaluate the installer after CLI changes
  - re-check installer help and argument validation paths
- In `app-registry`:
  - evaluate the flake outputs after changing the registry contract

## Stop Condition For The Agent
At the end of each Epic, stop and report:
1. what changed
2. what was validated
3. what remains risky or ambiguous
4. whether the next Epic should proceed

Do not silently continue into the next Epic.