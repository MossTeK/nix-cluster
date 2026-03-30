# nops (Nix Operations Daemon) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**nops** is a lightweight, asynchronous GitOps deployment library for NixOS. It allows you to manage an entire "Fleet" of NixOS machines—and external infrastructure—from a single centralized Git repository. 

`nops` gives you the flexibility to trigger asynchronous updates via two methods:
1. **Matrix Pub/Sub:** Nodes connect to a secure Matrix room. When your Git host posts a push notification to the room, your nodes intelligently pull the changes. Zero open firewall ports required.
2. **Webhooks:** Nodes run a lightweight `aiohttp` web server to receive standard JSON push event payloads directly from Forgejo, GitLab, or GitHub. 

When a trigger is received, the nodes pull the repository, determine if their specific configurations are affected, and apply the updates automatically via systemd.

---

## ✨ Key Features
* **Zero-Touch Node Enrollment:** Run a single `nix run` command on a fresh NixOS install to instantly bootstrap the daemon, generate secrets, and join the fleet.
* **Unified Infrastructure Controllers:** Designate one or more "Controller" nodes to safely execute pre-build infrastructure scripts (like Terraform) in a multi-node High Availability cluster.
* **Infinite Loop Prevention:** Built-in `[skip nops]` commit detection ensures automated bot commits from your Controller node do not trigger recursive rebuild loops across your fleet.
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
2. Run `nops-install` on that machine and choose controller/bootstrap mode, either through the interactive prompts or with `--config nops-config-template.json`.
3. The installer scaffolds the fleet repo, enrolls the controller, initializes `deployments.json`, and writes a reusable `nops-config-template.json` into the repo root.
4. The controller install also generates a controller SSH key, seeds that public key into the worker install template, and appends the controller node to `deployments.json` as inventory.
5. Once the controller is up, subsequent nodes are added by editing `deployments.json` and pushing to Git. You do not manually scaffold `nodes/<hostname>` entries.

If you want the controller to also host a PXE helper stack, set `pxe_enable: true` in the JSON. Keep `pxe_dhcp_enable: false` if your firewall already owns DHCP reservations; only enable it if the controller should also run DHCP/TFTP. `pxe_interface` is only needed in that case, while `pxe_http_port` and `pxe_boot_url` control the HTTP boot side.

## 🖥️ Scaling the Fleet: Zero-Touch Node Addition

1. Boot the worker node into the NixOS live ISO.
2. Set a password for the live installer user, usually `nixos`, so the controller can SSH in.
3. Open the existing SOPS-encrypted `deployments.json` in the fleet repo with `sops deployments.json`, then add a new entry:

```json
{
  "hostname": "node6",
  "installer_ip": "192.168.2.106",
  "installer_user": "nixos",
  "installer_auth_mode": "auto",
  "installer_ssh_pub_key": "",
  "installer_password": "changeme",
  "disk": "/dev/sda",
  "fs": "zfs",
  "node_group": "web",
  "node_role": "worker",
  "keepalived_role": "backup",
  "node_admin": "moss",
  "node_admin_pass": "changeme"
}
```

4. Save the encrypted file, then commit and push your changes to the fleet repository.
5. On the next controller update cycle, the controller SSHes into the live installer at `installer_user@installer_ip`, runs `nixos-anywhere` with Disko, and reboots the machine into the base OS.
6. After first boot, the controller reconnects using its SSH key when available, or falls back to `node_admin` and `node_admin_pass` if needed.
7. The controller hydrates `nops-config-template.json` with the node-specific values, runs `nops-install` remotely, adds the node under `nodes/<hostname>/`, updates `flake.nix`, injects the SOPS key, and pushes the enrollment commit.
8. The new node rebuilds into the fleet config and joins automatically.

For live ISO or live USB enrollment, set `installer_auth_mode` to `password`, `ssh_key`, or `auto`. If the live environment already trusts the controller key, `ssh_key` avoids password-based SSH.

Use `node_role` and `keepalived_role` to make HA placement explicit. The bootstrap controller defaults to `controller` plus `master`, while worker and backup nodes can be assigned `backup` or `service` roles for later module placement. You can also mark additional controller nodes with `node_role: controller`.

**Security Note:** `deployments.json` and `nops-config-template.json` contain bootstrap credentials and must remain SOPS-encrypted at rest. Edit them with `sops deployments.json` and `sops nops-config-template.json`.

`deployments.json` is the source of truth for controller-driven bare-metal enrollment. `nops-config-template.json` is the reusable non-interactive install template the controller hydrates and uses when it runs `nops-install` on worker nodes. The template also supports optional controller-hosted PXE fields for HTTP boot and, if explicitly enabled, DHCP/TFTP.

The intended operator workflow is:
- install the controller once with prompts or JSON
- let that install seed the repo templates
- boot workers into the live ISO and set the installer password
- add workers and additional controllers only by appending entries to `deployments.json`
- let the controller scaffold `nodes/<hostname>` and `flake.nix` automatically

Do not manually create node directories for worker enrollment unless you are intentionally bypassing the controller automation path.

If `caddy_enable` is `true`, the installer scaffolds a base Caddy module and imports it into the selected group. On bootstrap nodes, if `forgejo_public_host` is also set, the installer adds a default Caddy reverse proxy so Forgejo is reachable remotely at that hostname.

If `keepalived_enable` is `true` during bootstrap, the installer also scaffolds a keepalived ingress VIP module so the configured tunnel target address is actually assigned on the first node. If `keepalived_vip_cidr` is left empty, the installer derives the prefix length from the selected network interface and combines it with `cloudflare_tunnel_vip`.

`repo_url` should be the final shared Git URL that every node can reach after bootstrap. During bootstrap, `nops` temporarily pushes through the local Forgejo instance, then restores `origin` back to `repo_url`. If you keep `repo_url` set to `localhost`, worker nodes will not be able to clone or pull the fleet repository.

`repo_host_ip` is optional. When set, `nops` writes a host override on the installing node so the hostname from `repo_url` resolves to that internal IP even before internal DNS is ready. This is useful during first-node bootstrap when the public hostname already exists in Cloudflare but the homelab should reach Forgejo through a LAN VIP.

If `repo_host_ip` is omitted during bootstrap, `nops` now defaults it to `cloudflare_tunnel_vip` when the hostname in `repo_url` matches `forgejo_public_host`. That covers the common first-node case where Git should use the same ingress VIP as the tunnel and Caddy path.

`keepalived_virtual_router_id` must be a unique integer from 1 to 255 on that subnet. Reusing a VRID from another VIP group on the same LAN will cause VRRP collisions even when the VIP addresses differ.

**Note:** When a custom node `configuration.nix` is provided, the installer still runs hydration for hostname, admin user, repo path, trigger mode, and controller flag substitutions. These become no-ops if your custom file does not contain the expected placeholders. Custom group files are copied as-is. Group configs are only created when the group directory does not already exist.