# nix-cluster — Nix Cluster Controller

Open-source GitOps deployment library for NixOS fleets. Version 2.2.0.

## Structure

```
flake.nix               # Packages (default, install), NixOS module, app entry point
src/
  listener.py            # Async Matrix client — triggers updates on room messages
  webhook.py             # Async aiohttp server — triggers updates on POST webhooks
  update.py              # Synchronous UpdateManager — git fetch, change detection, rebuild
  setup.sh               # Interactive/JSON enrollment CLI (nix-cluster-install)
templates/
  configuration.nix      # Node config template with placeholder substitution
  flake.nix              # Fleet flake template with NODES_MARKER
  imports.nix            # Group imports template
  nix-cluster-config-template.json  # Reference JSON for non-interactive enrollment
  secrets.yaml           # SOPS secrets template (plaintext, encrypted during setup)
  cloudflared.nix        # Cloudflare tunnel daemon module (Docker-based)
  main.tf                # Terraform template for CF tunnel provisioning
```

## Architecture

Three components, two daemons:

```
Git Push Event
  ├─ Matrix room message → listener.py (AsyncClient long-poll)
  └─ HTTP POST → webhook.py (aiohttp server)
       ↓
  run_in_executor() → UpdateManager.perform_update()
       ↓
  git fetch → change detection → controller/worker logic → nixos-rebuild
```

Both daemons run in a single systemd service (`nix-cluster`), forked as background processes. `wait -n` causes systemd restart if either exits.

## NixOS Module Options (services."nix-cluster".*)

| Option | Type | Default | Purpose |
|--------|------|---------|---------|
| `enable` | bool | false | Activate nix-cluster daemon |
| `repoPath` | path | "/home/nops/" | Fleet repo directory |
| `isController` | bool | false | Run controllerScript before rebuild |
| `controllerScript` | lines | "" | Pre-rebuild bash (Terraform, secrets, etc.) |
| `afterPush` | list[str] | `[nixos-rebuild switch ...]` | Post-update commands |
| `matrix.enable` | bool | true | Enable Matrix listener |
| `webhook.enable` | bool | false | Enable webhook server |
| `webhook.port` | int | 8080 | Webhook listen port |
| `webhook.sslCert` | str? | null | SSL cert path (auto-generates self-signed if null) |
| `webhook.sslKey` | str? | null | SSL key path |

## Smart Rebuild Logic

UpdateManager only rebuilds when changed files match:
- `nodes/{hostname}/` — node-specific config
- `groups/` — shared group config (all nodes rebuild)
- `modules/` — shared modules (all nodes rebuild)
- `secrets/` — fleet secrets (all nodes rebuild)
- `scripts/`, `flake.nix`, `flake.lock` — fleet-wide changes

Changes to other nodes' `nodes/` dirs are ignored.

## Controller vs Worker Flow

**Controller** (`isController = true`):
1. `git fetch` + `git reset --hard origin/main`
2. Execute `controllerScript` (Terraform, secrets generation)
3. Re-fetch (picks up own commits)
4. **Always rebuilds** regardless of changes
5. Execute `afterPush` commands

**Worker** (`isController = false`):
1. `git fetch` + `git reset --hard origin/main`
2. Sleep 30s (wait for controller's secret commits)
3. Re-fetch to pick up controller changes
4. Check if changes affect this node
5. Rebuild only if relevant changes detected
6. Execute `afterPush` only if rebuild ran

## Installer Flow (setup.sh / nix-cluster-install)

Supports `--config <file.json>` for non-interactive mode or interactive prompts.

- Collect config: git creds, repo URL, group name, admin user, trigger choice, role
- Generate or import Age key → `/var/lib/sops-nix/key.txt`
- Clone existing repo or `git init` for bootstrap
- Scaffold directories: `nodes/{hostname}/`, `groups/{group}/`, `modules/`, `secrets/`, `scripts/`
- Hydrate templates via `sed` (hostname, admin, trigger mode, controller flag, etc.)
- Support custom group/node config files (copied as-is for group, hydrated for node)
- Scaffold Cloudflare tunnel modules when enabled (see below)
- Configure `.sops.yaml` with node's Age public key
- Populate and encrypt `secrets/secrets.yaml`
- Inject `nixosConfigurations` entry at `# NODES_MARKER` in flake.nix
- Commit + push (or defer push if bootstrap mode)
- First `nixos-rebuild switch`
- Bootstrap-only: create Forgejo admin user + repo via API, push
- `deployments.json` and `nix-cluster-config-template.json` now carry `installer_auth_mode`, `installer_ssh_pub_key`, `node_role`, and `keepalived_role` fields for live USB and HA enrollment.

## Cloudflare Tunnel (Built-in Option)

When `cloudflare_tunnel: true` is set (interactive prompt or JSON config), setup.sh:
- Copies `templates/cloudflared.nix` → `modules/cloudflare/cloudflared.nix`
- Copies `templates/main.tf` → `modules/terraform/main.tf` with substituted tunnel name, domain, and VIP
- Injects `../../modules/cloudflare/cloudflared.nix` into the group `imports.nix`
- Injects Terraform provisioning block into the controller's `controllerScript` (plan/apply/token-update)
- Pre-populates tunnel name and domain in `secrets/secrets.yaml`

The controller script (injected via `CLOUDFLARE_CONTROLLER_SCRIPT_PLACEHOLDER`):
- Reads CF credentials and tunnel config from SOPS
- Runs `terraform init` → `plan` → `apply` in `modules/terraform/`
- Extracts tunnel token from Terraform output
- Updates `cloudflare_tunnel_token` in SOPS and commits with `[skip nops]`
- Workers pick up the token on next `git fetch` → cloudflared starts via Docker

JSON config fields: `cloudflare_tunnel`, `cloudflare_tunnel_name`, `cloudflare_tunnel_domain`, `cloudflare_tunnel_vip`
SOPS secrets: `cloudflare_api_token`, `cloudflare_tunnel_token`, `cloudflare_tunnel_name`, `cloudflare_tunnel_domain`, `cloudflare_zone_id`, `cloudflare_account_id`

## Template Placeholders

Key `sed` patterns in `templates/configuration.nix`:
- `HOST_ID_PLACEHOLDER` → random 8-char hex
- `networking.hostName = ".*";` → actual hostname
- `users.users.tdavis` → configured admin user
- `MATRIX_ENABLE_PLACEHOLDER` / `WEBHOOK_ENABLE_PLACEHOLDER` → true/false
- `IS_CONTROLLER_PLACEHOLDER` → true/false
- `ALLOW_UNFREE_PLACEHOLDER` → `nixpkgs.config.allowUnfree = true;` (controller) or deleted
- `CONTROLLER_PACKAGES_PLACEHOLDER` → `terraform` (controller) or deleted
- `FORGEJO_CONFIG_PLACEHOLDER` → Forgejo service block (bootstrap) or deleted
- `CLOUDFLARE_CONTROLLER_SCRIPT_PLACEHOLDER` → Terraform provisioning block (controller + CF) or deleted

## Python Stack

| Package | Used In | Purpose |
|---------|---------|---------|
| matrix-nio | listener.py | Async Matrix client (room sync, event handling) |
| aiohttp | webhook.py | Async HTTP server (POST `/webhook`) |
| pyyaml | (minimal) | Available but config uses `json.load` |

## SOPS Secrets Declared by Module

The NixOS module auto-declares these secrets owned by `nops` user:
`matrix_bot_token`, `matrix_room_id`, `matrix_homeserver`, `git_username`, `git_password`, `webhook_secret`, `cloudflare_api_token`, `cloudflare_tunnel_name`, `cloudflare_tunnel_domain`, `cloudflare_zone_id`, `cloudflare_account_id`

The cloudflared module (when enabled) declares: `cloudflare_tunnel_token`

## Build Commands

```bash
nix build .#default       # Daemon package (nix-cluster-daemon + nix-cluster-webhook)
nix build .#install       # Installer CLI (nix-cluster-install)
nix run .#install         # Run installer directly
```

## Pitfalls

- `setup.sh` uses `sed` for template substitution — fragile if template structure changes
- Worker 30s sleep is time-based, not event-driven (controller may not finish in time)
- Both daemons share one systemd service — if only one trigger is enabled, `wait -n` exits immediately
- `\r` carriage returns in controllerScript are auto-stripped (Windows Git workaround)
- `# NODES_MARKER` comment in fleet flake.nix must not be removed (setup.sh injects nodes there)
- No test suite — all testing is live enrollment and rebuild

## App and Fleet Input Update Workflow

When changing `sgt/nix-cluster`, `apps/nix-cluster-portal`,
`sgt/app-registry`, or any app repository consumed by a fleet, pushing the
source repository is not enough. Fleets deploy pinned flake inputs and will keep
serving the old code until their lockfiles are updated and rebuilt.

Required workflow:
- Commit and push the source repository change.
- In the consuming fleet, run `nix flake lock --update-input <input>` for the
  changed input.
- Inspect the fleet diff and confirm it only updates the intended lock entry
  unless broader fleet changes were requested.
- Run `git diff --check` and evaluate affected NixOS configurations.
- Commit and push the fleet lock update.
- Verify the controller fetched the new fleet commit, rebuilt from it, and
  restarted the affected service.
- For UI/static asset changes, verify the live origin serves the new asset hash
  or that the served CSS/JS contains the expected change.

If a webhook arrives while another update is active, confirm the queued
follow-up update ran before concluding the deployment is current.
