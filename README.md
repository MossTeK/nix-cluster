# NAD Core (Nix Automation Daemon)

NAD Core is a **NixOS Library** that allows you to deploy and manage the entirety of your nixos config via a simple lightweight git-ops platform.

---

## 🚀 Quick Start Guide

### Step 1: Create the 'nad' User (Prerequisite)

Before running the installer, you must manually create the `nad` user on your server.

1.  Open your `/etc/nixos/configuration.nix` or `/etc/nixos/flake.nix`.
2.  Add the user

    ```nix
    users.users.nad = {
      isNormalUser = true;
      extraGroups = [ "wheel" "docker" ];
    };
    ```

3.  Rebuild:
    ```bash
    sudo nixos-rebuild switch --uprade
    ```

---

### Step 2: Create Your Private Repository

Create a new **empty private repository** (e.g., `server-name`).

---

### Step 3: Run the Installer

```bash
nix run git+https://forgejo.mosstek.co/moss/nad-core.git#install
```
