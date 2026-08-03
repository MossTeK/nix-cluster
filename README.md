# nix-cluster (Nix Cluster Controller) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**nix-cluster** is a lightweight, asynchronous GitOps deployment library for NixOS. It allows you to manage an entire "Fleet" of NixOS machines—and external infrastructure—from a single centralized Git repository. 

`nix-cluster` gives you the flexibility to trigger asynchronous updates via two methods:
1. **Matrix Pub/Sub:** Nodes connect to a secure Matrix room. When your Git host posts a push notification to the room, your nodes intelligently pull the changes. Zero open firewall ports required.
2. **Webhooks:** Nodes run a lightweight `aiohttp` web server to receive standard JSON push event payloads directly from Forgejo, GitLab, or GitHub. 

When a trigger is received, the nodes pull the repository, determine if their specific configurations are affected, and apply the updates automatically via systemd.

## Shared storage contract

The NixOS module supports controller-backed shared storage through
`services.nix-cluster.identity.sharedHomes` and
`services.nix-cluster.storage`. A configured home node exports `/home` over
NFS; workers mount it before user-facing services start. Application modules
declare persistent paths under `storage.applications.<slug>`, which defaults
to the shared application root and adds `RequiresMountsFor=` plus the
`nix-cluster-shared-storage-ready.service` dependency to declared services.

Shared-storage consumers fail closed when the controller export is missing.
Local storage is an explicit exception for caches or node-pinned services, not
an implicit fallback. All cluster nodes enable systemd time synchronization so
HA health timestamps remain comparable.

## 📚 Documentation

Public project documentation is available in the wiki-style docs under `docs/wiki/`:

- `docs/wiki/Home.md`
- `docs/wiki/Architecture-and-Data-Flow.md`
- `docs/wiki/Configuration-Reference.md`
- `docs/wiki/Operations-and-Enrollment.md`

If you are using `nix-cluster` with a private fleet repository, keep environment-specific inventory, secrets, rollout steps, and migration runbooks in that private repo.

---

## ✨ Key Features
* **Zero-Touch Node Enrollment:** Run a single `nix run` command on a fresh NixOS install to instantly bootstrap the daemon, generate secrets, and join the fleet.
* **Unified Infrastructure Controllers:** Designate one or more "Controller" nodes to safely execute pre-build infrastructure scripts (like Terraform) in a multi-node High Availability cluster.
* **Infinite Loop Prevention:** Built-in skip-marker detection ensures automated bot commits from your Controller node do not trigger recursive rebuild loops across your fleet.
* **Smart Fleet Management:** One repository rules them all. Nodes only rebuild if their specific `nodes/$HOSTNAME/` directory, shared `modules/`, or global secrets change.
* **Native SOPS Integration:** Built-in secret management using `sops-nix` and Age keys.

---

## 📋 Prerequisites
1. **A Git Host:** A private repository on Forgejo (or GitLab/GitHub).
2. **Update Trigger:** * *For Matrix:* A Matrix homeserver, a dedicated room for updates, a Bot Access Token, and a Git hook configured to message the room.
   * *For Webhooks:* The ability for your Git host to reach the node's IP/Domain on your configured port (default `8080`).

---


## 🚀 Quick Start: Bootstrapping the Controller Node

1. Start with a minimal NixOS install for the first controller node.
2. Run `nix-cluster-install` on that machine and choose controller/bootstrap mode, either through the interactive prompts or with `--config nix-cluster-config-template.json`.
3. The installer scaffolds the fleet repo, enrolls the controller, initializes `deployments.json`, and writes a reusable `nix-cluster-config-template.json` into the repo root.
4. The controller install also generates a controller SSH key, seeds that public key into the worker install template, and appends the controller node to `deployments.json` as inventory.
5. Once the controller is up, subsequent nodes are added by editing `deployments.json` and pushing to Git. You do not manually scaffold `nodes/<hostname>` entries.

If you want the controller to also host a PXE helper stack, set `pxe_enable: true` in the JSON. Keep `pxe_dhcp_enable: false` if your firewall already owns DHCP reservations; only enable it if the controller should also run DHCP/TFTP. `pxe_interface` is only needed in that case, while `pxe_http_port` and `pxe_boot_url` control the HTTP boot side.

## 🖥️ Scaling the Fleet: Node Addition

`nix-cluster` supports two worker enrollment styles:

1. **Controller-led live installer enrollment** for environments where the controller can reach a live ISO or PXE session over SSH.
2. **Manual ISO install plus local join** for environments where PXE, DNS, or early-network assumptions are not reliable yet.

The controller-led path remains supported, but the manual ISO flow is often the safer staged rollout for existing homelabs.

### Option A: controller-led live installer enrollment

1. Boot the worker node into the NixOS live ISO.
2. Set a password for the live installer user, usually `nixos`, so the controller can SSH in.
3. Open the existing SOPS-encrypted `deployments.json` in the fleet repo with `sops deployments.json`, then add a new entry:

```json
{
  "hostname": "node6",
  "installer_ip": "192.168.2.106",
  "installer_user": "nixos",
  "installer_auth_mode": "ssh_key",
  "installer_ssh_pub_key": "",
  "installer_password": "",
  "installer_mode": "default",
  "installer_script": "",
  "installer_pre_script": "",
  "installer_post_script": "",
  "disk": "/dev/sda",
  "fs": "zfs",
  "node_group": "web",
  "node_role": "worker",
  "keepalived_role": "backup",
  "node_admin": "moss",
  "ssh_password_auth": false,
  "node_admin_pass": "",
  "node_admin_password_hash": ""
}
```

`installer_mode` behavior:

- `default`: run the built-in `nixos-install` flow
- `replace`: run only `installer_script`
- `hooks`: run `installer_pre_script`, then the default installer, then `installer_post_script`

4. Save the encrypted file, then commit and push your changes to the fleet repository.
5. On the next controller update cycle, the controller SSHes into the live installer at `installer_user@installer_ip`, runs `nixos-anywhere` with Disko, and reboots the machine into the base OS.
6. After first boot, the controller reconnects using its SSH key and continues enrollment without enabling SSH password auth by default.
7. The controller hydrates `nix-cluster-config-template.json` with the node-specific values, runs `nix-cluster-install` remotely, adds the node under `nodes/<hostname>/`, updates `flake.nix`, injects the SOPS key, and pushes the enrollment commit.
8. The new node rebuilds into the fleet config and joins automatically.

### Option B: manual DHCP ISO install and local join

This is the recommended path when DNS is not ready yet or PXE behavior is unstable.

High-level flow:

1. Build a host-specific installer ISO from the private fleet repo.
2. Boot the node from that ISO.
3. Run `worker-base-install` from the live environment.
4. Reboot into the installed base OS.
5. SSH in as the created admin user.
6. Run `sudo /usr/local/bin/join-homelab-worker`.

That staged flow lets you separate:

- base disk install debugging
- first-boot validation
- `nix-cluster-install` enrollment debugging

The ISO helper can also carry a pre-rendered worker join config and a join script that pins the Git host in `/etc/hosts` through `repo_host_ip`, which removes the need for working internal DNS during first join.

In the homelab-fleet-style workflow, it is also common to maintain two shared SSH identities:

- a shared bootstrap node key used by the controller and live installer access
- a shared human admin key for the default admin user such as `moss`

Those public keys can live in a small tracked registry file, while the private keys remain in SOPS-managed secrets in the private fleet repo.

If you are documenting or operating that path, keep the exact host-specific runbook in the private fleet repo rather than this public repo.

For live ISO or live USB enrollment, set `installer_auth_mode` to `ssh_key`, `auto`, or `password`. `ssh_key` is now the default and is the expected mode for PXE-driven installs.

When worker inventory is declared in `services."nix-cluster".workers.<hostname>`, those fields are merged into controller inventory at runtime and can drive install mode/script behavior without editing deployment entries first.

Use `node_role` and `keepalived_role` to make HA placement explicit. The bootstrap controller defaults to `controller` plus `master`, while worker and backup nodes can be assigned `backup` or `service` roles for later module placement. You can also mark additional controller nodes with `node_role: controller`.

**Security Note:** `deployments.json` and `nix-cluster-config-template.json` contain bootstrap credentials and must remain SOPS-encrypted at rest. Edit them with `sops deployments.json` and `sops nix-cluster-config-template.json`.

`deployments.json` is the source of truth for controller-driven bare-metal enrollment. `nix-cluster-config-template.json` is the reusable non-interactive install template the controller hydrates and uses when it runs `nix-cluster-install` on worker nodes. The template also supports optional controller-hosted PXE fields for HTTP boot and, if explicitly enabled, DHCP/TFTP.

The intended operator workflow is:
- install the controller once with prompts or JSON
- let that install seed the repo templates
- boot workers into a PXE or live environment that already trusts the controller SSH key
- add workers and additional controllers only by appending entries to `deployments.json`
- let the controller scaffold `nodes/<hostname>` and `flake.nix` automatically

Do not manually create node directories for worker enrollment unless you are intentionally bypassing the controller automation path.

If `caddy_enable` is `true`, the installer scaffolds a base Caddy module and imports it into the selected group. On bootstrap nodes, if `forgejo_public_host` is also set, the installer adds a default Caddy reverse proxy so Forgejo is reachable remotely at that hostname.

If `keepalived_enable` is `true` during bootstrap, the installer also scaffolds a keepalived ingress VIP module so the configured tunnel target address is actually assigned on the first node. If `keepalived_vip_cidr` is left empty, the installer derives the prefix length from the selected network interface and combines it with `cloudflare_tunnel_vip`.

`repo_url` should be the final shared Git URL that every node can reach after bootstrap. During bootstrap, `nix-cluster` temporarily pushes through the local Forgejo instance, then restores `origin` back to `repo_url`. If you keep `repo_url` set to `localhost`, worker nodes will not be able to clone or pull the fleet repository.

`repo_host_ip` is optional. When set, `nix-cluster` writes a host override on the installing node so the hostname from `repo_url` resolves to that internal IP even before internal DNS is ready. The installer now also persists this mapping declaratively through a generated node import (`./repo-hosts.nix`) so it survives later `nixos-rebuild switch` runs instead of being lost with transient `/etc/hosts` edits.

For manual worker enrollment, `repo_host_ip` is also the preferred way to make first-join cloning deterministic before local DNS exists. In controller-managed enrollment, `repo_host_ip` now prefers the Keepalived VIP (when available in runtime config) and falls back to the controller primary IP.

If `repo_host_ip` is omitted during bootstrap, `nix-cluster` now defaults it to `cloudflare_tunnel_vip` when the hostname in `repo_url` matches `forgejo_public_host`. That covers the common first-node case where Git should use the same ingress VIP as the tunnel and Caddy path.

`keepalived_virtual_router_id` must be a unique integer from 1 to 255 on that subnet. Reusing a VRID from another VIP group on the same LAN will cause VRRP collisions even when the VIP addresses differ.

**Note:** When a custom node `configuration.nix` is provided, the installer still runs hydration for hostname, admin user, repo path, trigger mode, and controller flag substitutions. These become no-ops if your custom file does not contain the expected placeholders. Custom group files are copied as-is. Group configs are only created when the group directory does not already exist.

## 🔎 Enrollment observability and debugging

Recent installer and enrollment changes add clearer success markers and step-by-step debugging support.

### Success markers

- local installer success logs under `/var/log/nixos-install/`
- local join banner from `nix-cluster-install`:
  - `[SUCCESS] NODE JOINED: <hostname> role=<role> repo=<repo_url>`
- controller-side enrollment banner:
  - `=== NODE JOINED SUCCESSFULLY: <hostname> ===`
- controller runtime-store phase:
  - `join-complete`

### Debug mode

For shell-level tracing during install or join, export:

```bash
export NIX_CLUSTER_DEBUG=1
```

For the base OS installer itself, the helper forwards that into:

```bash
NIXOS_INSTALL_DEBUG=1
```

This enables `set -x` style tracing in the generated helper scripts and in `nixos-install`.

### Useful log paths

On the installing node or live ISO:

- `/var/log/nixos-install-launcher.log`
- `/var/log/nixos-install/install.log`
- `/var/log/nixos-install/state.env`

On the enrolled node after first boot:

- `/var/log/nix-cluster-join.log`
- `/var/log/nix-cluster-setup.log`

On the controller:

- provisioning artifact tree under `/home/nix-cluster/log/provisioning/<hostname>/latest/`
- `journalctl -t nix-cluster-install`
- `journalctl -u nix-cluster.service`

### Live vs installed SSH users

For the staged manual and PXE-assisted flows, these roles are intentionally separate:

- live installer environment: `nixos`
- installed admin account: `moss` or your configured admin user
- service automation account: `nix-cluster`

This separation keeps live bootstrap access simple while still allowing a stable local admin identity after install.

Operationally, `service-account-reachable` is not a completed enrollment state. It only means the bootstrap service account exists and answers over SSH. For non-reinstall workers, the controller should continue by preferring its passwordless admin-user SSH path before retrying bootstrap or installer probes, otherwise wrong-key attempts can trigger connection resets and hide a valid base-OS login.
