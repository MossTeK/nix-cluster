# Copilot instructions for nix-cluster

## Project shape
- `nops` is a GitOps deployment system for NixOS fleets.
- The main control flow is: Matrix room message or webhook POST → `src/update.py` → `git fetch`/change detection → `nixos-rebuild`.
- `flake.nix` packages the daemons (`nops-daemon`, `nops-webhook`) and exposes `nops-install`/`nops-deploy` apps.
- The deployed systemd service name is `nix-cluster`; use `nix-cluster.service` in operational docs and troubleshooting steps.

## Read first
- `README.md` explains the operator model and enrollment flow.
- `src/setup.sh` is the source of truth for bootstrap/enrollment behavior.
- `templates/configuration.nix`, `templates/flake.nix`, `templates/controllerScript-autoprovision.sh`, and `templates/imports.nix` define the generated fleet layout.

## Fleet layout and deployment model
- The fleet repo is organized around `nodes/<hostname>/`, `groups/<group>/`, `modules/`, `secrets/`, and `scripts/`.
- Do not manually create worker node folders when the controller path is intended; `src/setup.sh` and the controller script scaffold them.
- For a 4-node Lenovo ThinkCentre fleet, treat one machine as the controller/bootstrap node and add the other ThinkCentres as entries in `deployments.json`.
- `templates/deployments.json` is the controller inventory source of truth: each entry needs `hostname`, `installer_ip`, `installer_user`, `installer_password`, `disk`, `fs`, `node_group`, `node_admin`, and `node_admin_pass`.

## Update/rebuild rules
- `src/update.py` only rebuilds when the current host’s `nodes/<hostname>/` tree changes, or when `groups/`, `modules/`, `secrets/`, `scripts/`, `flake.nix`, or `flake.lock` change.
- Changes to other nodes’ directories are ignored on workers.
- Controllers always run their `controllerScript` before rebuilding.
- Workers sleep 30s before rechecking the repo to let controller secret commits land.
- Webhook commits containing `[skip nops]` are intentionally ignored to prevent loops.

## Configuration conventions
- Keep placeholder names stable: `HOST_ID_PLACEHOLDER`, `IS_CONTROLLER_PLACEHOLDER`, `MATRIX_ENABLE_PLACEHOLDER`, `WEBHOOK_ENABLE_PLACEHOLDER`, `ALLOW_UNFREE_PLACEHOLDER`, `FORGEJO_CONFIG_PLACEHOLDER`, `CLOUDFLARE_CONTROLLER_SCRIPT_PLACEHOLDER`, and `# NODES_MARKER`.
- `templates/flake.nix` uses `# NODES_MARKER`; `src/setup.sh` inserts `nixosConfigurations.<hostname>` there.
- `templates/configuration.nix` is hydrated with `sed`; avoid structural edits that break those substitutions.
- Secrets are managed with SOPS and Age via `sops-nix`; bootstrap files like `deployments.json` and `nops-config-template.json` may be encrypted at rest.

## Bootstrap and integrations
- `src/setup.sh` handles both interactive and `--config <file.json>` enrollment.
- Bootstrap mode can create local Forgejo, wire Caddy, keepalived, and Cloudflare tunnel support, then restore the remote Git URL afterward.
- Cloudflare tunnel commits are pushed with `[skip nops]` after token updates.
- Keepalived VRIDs must stay unique per subnet; the script derives a VIP CIDR when possible.

## Useful commands
- `nix build .#default` builds the daemon package.
- `nix build .#install` builds the installer.
- `nix run .#install` runs the installer directly.

## When changing code
- Prefer updating templates and generator logic together.
- Preserve the controller/worker split and the bootstrap handoff flow.
- Keep file/path references consistent with the generated repo structure.