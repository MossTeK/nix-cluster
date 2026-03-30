{
  description = "nix-cluster - Nix Cluster Controller";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
  };

  outputs = { self, nixpkgs, sops-nix, ... }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    
    pythonDeps = ps: with ps; [ matrix-nio pyyaml aiohttp ];
    pythonEnv = pkgs.python3.withPackages pythonDeps;
  in {
    packages.${system} = {
      # Package definition for nops daemons.
      # Compiles the Python-based Matrix listener and Webhook server into wrapped executables.
      default = pkgs.stdenv.mkDerivation {
        pname = "nix-cluster";
        version = "2.2.0";
        src = ./.;
        nativeBuildInputs = [ pkgs.makeWrapper pkgs.dos2unix ];
        postPatch = ''
          dos2unix src/* templates/* flake.nix ||
          true
        '';

        installPhase = ''
          mkdir -p $out/bin $out/lib $out/share/nops
          cp -r src/* $out/lib/
          cp -r templates $out/share/nops/templates
          
          # Wraps the Matrix daemon with required binaries for fleet operations.
          # Injects git, nixos-rebuild, and secret management tools into the execution environment.
          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nops-daemon \
            --add-flags "$out/lib/listener.py" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.inetutils pkgs.nixos-rebuild pkgs.systemd pkgs.bash pkgs.sops pkgs.age pkgs.jq pkgs.openssh pkgs.sshpass pkgs.mkpasswd ]}

          # Wraps the Webhook server with required binaries for fleet operations.
          # Injects git, nixos-rebuild, and secret management tools into the execution environment.
          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nops-webhook \
            --add-flags "$out/lib/webhook.py" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.inetutils pkgs.nixos-rebuild pkgs.systemd pkgs.bash pkgs.sops pkgs.age pkgs.jq pkgs.openssh pkgs.sshpass pkgs.mkpasswd ]}
        '';
      };

      # Builds nops-install, an interactive CLI that scaffolds a new node's flake and SOPS secrets file.
      install = pkgs.stdenv.mkDerivation {
        name = "nops-install";
        src = ./.;
        nativeBuildInputs = [ pkgs.makeWrapper pkgs.dos2unix ];
        
        postPatch = ''
          dos2unix src/* templates/* flake.nix ||
          true
        '';

        installPhase = ''
          mkdir -p $out/share/nops/src $out/bin
          cp src/setup.sh $out/share/nops/src/setup.sh
          cp src/deploy.sh $out/share/nops/src/deploy.sh 2>/dev/null || true
          chmod +x $out/share/nops/src/*.sh
          cp -r templates $out/share/nops/templates

          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nops-install \
            --add-flags "$out/share/nops/src/setup.sh" \
            --set NOPS_TEMPLATES_DIR "$out/share/nops/templates" \
            --set NOPS_SRC_DIR "$out/share/nops/src" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ 
              pkgs.git pkgs.sops pkgs.age pkgs.vim pkgs.nano pkgs.openssh 
              pkgs.util-linux pkgs.nixos-rebuild pkgs.inetutils 
              pkgs.systemd pkgs.jq 
            ]}

          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nops-deploy \
            --add-flags "$out/share/nops/src/deploy.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ 
              pkgs.git pkgs.openssh pkgs.nix pkgs.mkpasswd
            ]}
        '';
      };
    };

    # NixOS module imported by fleet nodes via flake input.
    # Declares the nix-cluster service user, systemd daemon(s), firewall rules, and injects SOPS-decrypted secrets.
    nixosModules.default = { config, lib, pkgs, ... }: 
    let 
      cfg = config.services."nix-cluster";
      # Serializes repo path and rebuild commands to a JSON file the Python daemon reads at startup.
    nopsConfig = pkgs.writeText "nops-config.json" (builtins.toJSON {
      is_controller = cfg.isController;
      # AUTOMATIC SANITIZATION: Strip \r from the controller script
      controller_script = builtins.replaceStrings [ "\r" ] [ "" ] cfg.controllerScript;
      directories = {
        repo = cfg.repoPath;
        log = "/home/nops/log";
      };
      commands = {
        # AUTOMATIC SANITIZATION: Strip \r from every command in the update list
        update = builtins.map (cmd: builtins.replaceStrings [ "\r" ] [ "" ] cmd) cfg.afterPush;
      };
      controller = {
        reconcile_interval_seconds = cfg.controller.reconcileIntervalSeconds;
      };
      modules = {
        caddy = {
          enable = cfg.modules.caddy.enable;
        };
        keepalived = {
          enable = cfg.modules.keepalived.enable;
          interface = cfg.modules.keepalived.interface;
          virtual_router_id = cfg.modules.keepalived.virtualRouterId;
          priority = cfg.modules.keepalived.priority;
          vip_cidr = cfg.modules.keepalived.vipCidr;
        };
        cloudflare = {
          enable = cfg.modules.cloudflare.enable;
          tunnel = cfg.modules.cloudflare.tunnel;
          tunnel_name = cfg.modules.cloudflare.tunnelName;
          tunnel_domain = cfg.modules.cloudflare.tunnelDomain;
          tunnel_vip = cfg.modules.cloudflare.vip;
          zone_id = cfg.modules.cloudflare.zoneId;
          account_id = cfg.modules.cloudflare.accountId;
        };
        pxe = {
          enable = cfg.modules.pxe.enable;
          dhcp_enable = cfg.modules.pxe.dhcpEnable;
          interface = cfg.modules.pxe.interface;
          http_port = cfg.modules.pxe.httpPort;
          boot_url = cfg.modules.pxe.bootUrl;
        };
        postgres_backup = {
          enable = cfg.modules.postgresBackup.enable;
        };
      };
    });
    in {
      imports = [
        sops-nix.nixosModules.sops
        (lib.mkRenamedOptionModule [ "services" "nops" ] [ "services" "nix-cluster" ])
      ];
      options.services."nix-cluster" = {
        enable = lib.mkEnableOption "nix-cluster - Nix Cluster Controller";
        isController = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "If true, this node acts as the Controller for Terraform and Secrets.";
        };
        controllerScript = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Bash script to execute ONLY on the controller node before syncing and rebuilding.";
        };
        repoPath = lib.mkOption {
          type = lib.types.path;
          default = "/home/nops/";
        };
        afterPush = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "/run/wrappers/bin/sudo /run/current-system/sw/bin/systemd-run --working-directory=${config.services.\"nix-cluster\".repoPath} --service-type=oneshot --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin -- /run/current-system/sw/bin/nixos-rebuild switch --flake ${config.services.\"nix-cluster\".repoPath}#${config.networking.hostName} --impure"
          ];
          description = "Array of shell commands to execute after a push is received.";
        };
        controller.reconcileIntervalSeconds = lib.mkOption {
          type = lib.types.int;
          default = 60;
          description = "How often the controller should rerun reconciliation to detect provisionable nodes even when no webhook event occurs. Set to 0 to disable periodic reconciliation.";
        };
        modules = {
          caddy.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable the Caddy reverse proxy module.";
          };
          keepalived = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable the Keepalived VIP module.";
            };
            interface = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Network interface used by Keepalived.";
            };
            virtualRouterId = lib.mkOption {
              type = lib.types.int;
              default = 51;
              description = "Keepalived virtual router ID.";
            };
            priority = lib.mkOption {
              type = lib.types.int;
              default = 100;
              description = "Keepalived priority for this node.";
            };
            vipCidr = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "CIDR for the Keepalived VIP.";
            };
          };
          cloudflare = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable the Cloudflare tunnel module.";
            };
            tunnel = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Provision a Cloudflare tunnel for the fleet ingress.";
            };
            tunnelName = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Cloudflare tunnel name.";
            };
            tunnelDomain = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Cloudflare tunnel domain.";
            };
            vip = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Ingress VIP target for Cloudflare.";
            };
            zoneId = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Cloudflare zone ID.";
            };
            accountId = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Cloudflare account ID.";
            };
          };
          pxe = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable controller-hosted PXE assets.";
            };
            dhcpEnable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable dnsmasq DHCP/TFTP for PXE.";
            };
            interface = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Interface used by the PXE DHCP service.";
            };
            httpPort = lib.mkOption {
              type = lib.types.int;
              default = 8081;
              description = "HTTP port used to serve boot.ipxe.";
            };
            bootUrl = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "iPXE chainload URL.";
            };
          };
          postgresBackup.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable PostgreSQL backups for Forgejo.";
          };
        };
        matrix = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable the Matrix bot listener.";
          };
        };
        webhook = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable the Webhook listener (Forgejo/GitLab/GitHub).";
          };
          port = lib.mkOption {
            type = lib.types.int;
            default = 8080;
            description = "Port for the Webhook listener to bind to.";
          };
          sslCert = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Path to the SSL certificate file for the webhook listener.";
          };
          sslKey = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Path to the SSL private key file for the webhook listener.";
          };
        };
      };

      config = lib.mkIf cfg.enable {
        networking.firewall.allowedTCPPorts = lib.optionals cfg.webhook.enable [ cfg.webhook.port ];
        users.users.nops = {
          isNormalUser = true;
          description = "nix-cluster Service Daemon Account";
          group = "nops";
          extraGroups = [ "wheel" "docker" ];
          home = "/home/nops";
          createHome = true;
          shell = pkgs.bash;
        };
        users.groups.nops = {};
        environment.systemPackages = [ 
          self.packages.${system}.default 
          pkgs.git 
          pkgs.sops 
          pkgs.inetutils
          pkgs.openssh
          pkgs.jq
          pkgs.sshpass
          pkgs.mkpasswd
        ];
        systemd.tmpfiles.rules = [
          "d /home/nops/log 0755 nops nops -"
        ];
        
        # Runs the nix-cluster listener(s) as the nops user. Spawns the Matrix daemon and/or webhook server based on enabled options.
        systemd.services."nix-cluster" = {
          description = "nix-cluster Operations Listener Daemon";
          aliases = [ "nops.service" ];
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          path = [ pkgs.git pkgs.nixos-rebuild pkgs.inetutils pkgs.systemd pkgs.bash pkgs.openssl pkgs.sops pkgs.age pkgs.openssh pkgs.jq pkgs.sshpass pkgs.mkpasswd ]
            ++ lib.optionals cfg.isController [ pkgs.terraform ];
          serviceConfig = {
            User = "nops";
            Restart = "always";
            RestartSec = "10s";
            WorkingDirectory = cfg.repoPath;
          };
          
          environment = {
            NOPS_CONFIG_PATH = "${nopsConfig}";
            NOPS_LOG_PATH = "/home/nops/log/main.log";
            MATRIX_BOT_TOKEN_FILE = config.sops.secrets.matrix_bot_token.path;
            MATRIX_ROOM_ID_FILE = config.sops.secrets.matrix_room_id.path;
            MATRIX_HOMESERVER_FILE = config.sops.secrets.matrix_homeserver.path;
            WEBHOOK_PORT = builtins.toString cfg.webhook.port;
            WEBHOOK_SSL_CERT = if cfg.webhook.sslCert != null then cfg.webhook.sslCert else "";
            WEBHOOK_SSL_KEY = if cfg.webhook.sslKey != null then cfg.webhook.sslKey else "";
          };

          # Generates a self-signed TLS cert at the configured path if SSL is enabled and no cert exists yet.
          preStart = ''
            if [ "${builtins.toString cfg.webhook.enable}" = "1" ] && [ -n "${if cfg.webhook.sslCert != null then cfg.webhook.sslCert else ""}" ]; then
              CERT_PATH="${if cfg.webhook.sslCert != null then cfg.webhook.sslCert else ""}"
              KEY_PATH="${if cfg.webhook.sslKey != null then cfg.webhook.sslKey else ""}"
              CERT_DIR=$(dirname "$CERT_PATH")

              if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
                echo "Generating self-signed SSL certificates at $CERT_DIR..."
                mkdir -p "$CERT_DIR"
                ${pkgs.openssl}/bin/openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                  -keyout "$KEY_PATH" -out "$CERT_PATH" \
                  -subj "/CN=$(hostname)"
                chmod 600 "$KEY_PATH"
                chmod 644 "$CERT_PATH"
              fi
            fi
          '';

          # Spawns enabled listeners as background processes and waits for either to exit, triggering a systemd restart.
          script = ''
             export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
             
             if [ "${builtins.toString cfg.matrix.enable}" = "1" ]; then
               export MATRIX_BOT_TOKEN=$(cat $MATRIX_BOT_TOKEN_FILE)
               export MATRIX_ROOM_ID=$(cat $MATRIX_ROOM_ID_FILE)
               export MATRIX_HOMESERVER=$(cat $MATRIX_HOMESERVER_FILE)
               ${self.packages.${system}.default}/bin/nops-daemon &
             fi

             if [ "${builtins.toString cfg.webhook.enable}" = "1" ]; then
               ${self.packages.${system}.default}/bin/nops-webhook &
             fi
             
             wait -n
          '';
        };
      };
    };

    # Exposes nops commands as runnable Nix apps.
    apps.${system} = {
      install = { 
        type = "app"; 
        program = "${self.packages.${system}.install}/bin/nops-install"; 
      };
      deploy = { 
        type = "app"; 
        program = "${self.packages.${system}.install}/bin/nops-deploy"; 
      };
    };
  };
}