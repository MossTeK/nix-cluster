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
      # Package definition for nix-cluster daemons.
      # Compiles the Python-based Matrix listener and Webhook server into wrapped executables.
      default = pkgs.stdenv.mkDerivation {
        pname = "nix-cluster";
        version = "2.2.0";
        src = ./.;
        nativeBuildInputs = [ pkgs.makeWrapper pkgs.dos2unix ];
        postPatch = ''
          dos2unix src/*.sh src/lib/* src/scripts/* templates/* flake.nix ||
          true
        '';

        installPhase = ''
          mkdir -p $out/bin $out/lib $out/share/nix-cluster
          cp -r src/* $out/lib/
          cp -r templates $out/share/nix-cluster/templates
          
          # Wraps the Matrix daemon with required binaries for fleet operations.
          # Injects git, nixos-rebuild, and secret management tools into the execution environment.
          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster-daemon \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.listener" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.inetutils pkgs.nixos-rebuild pkgs.systemd pkgs.bash pkgs.sops pkgs.age pkgs.jq pkgs.openssh pkgs.sshpass pkgs.mkpasswd ]}

          # Wraps the Webhook server with required binaries for fleet operations.
          # Injects git, nixos-rebuild, and secret management tools into the execution environment.
          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster-webhook \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.webhook" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.inetutils pkgs.nixos-rebuild pkgs.systemd pkgs.bash pkgs.sops pkgs.age pkgs.jq pkgs.openssh pkgs.sshpass pkgs.mkpasswd ]}

          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nix-cluster-observe \
            --add-flags "$out/lib/scripts/observe.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.jq pkgs.bash ]}

          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nix-cluster-node \
            --add-flags "$out/lib/scripts/node-observe.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.openssh pkgs.sshpass pkgs.sops pkgs.age pkgs.jq pkgs.bash ]}

          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nix-cluster-fleet-status \
            --add-flags "$out/lib/scripts/fleet-status.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.sops pkgs.age pkgs.jq pkgs.openssh pkgs.bash ]}

          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nix-cluster-fleet-watch \
            --add-flags "$out/lib/scripts/fleet-watch.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.jq pkgs.coreutils pkgs.bash ]}

          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nix-cluster-controller-heartbeat \
            --add-flags "$out/lib/scripts/controller-heartbeat.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.iputils pkgs.inetutils pkgs.systemd pkgs.jq pkgs.coreutils pkgs.bash ]}

          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster-reporter \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.ha reporter" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.coreutils pkgs.bash ]}

          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster-monitor \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.ha monitor" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.coreutils pkgs.bash ]}

          ln -s nix-cluster-daemon $out/bin/nops-daemon
          ln -s nix-cluster-webhook $out/bin/nops-webhook
          ln -s nix-cluster-observe $out/bin/nops-observe
          ln -s nix-cluster-node $out/bin/nops-node
          ln -s nix-cluster-fleet-status $out/bin/nops-fleet-status
          ln -s nix-cluster-fleet-watch $out/bin/nops-fleet-watch
          ln -s nix-cluster-controller-heartbeat $out/bin/nops-controller-heartbeat
          ln -s nix-cluster-reporter $out/bin/nops-reporter
          ln -s nix-cluster-monitor $out/bin/nops-monitor
        '';
      };

      # Builds nix-cluster-install, an interactive CLI that scaffolds a new node's flake and SOPS secrets file.
      install = pkgs.stdenv.mkDerivation {
        name = "nix-cluster-install";
        src = ./.;
        nativeBuildInputs = [ pkgs.makeWrapper pkgs.dos2unix ];
        
        postPatch = ''
          dos2unix src/*.sh src/lib/* src/scripts/* templates/* flake.nix ||
          true
        '';

        installPhase = ''
          mkdir -p $out/share/nix-cluster/src $out/bin
          cp src/setup.sh $out/share/nix-cluster/src/setup.sh
          mkdir -p $out/share/nix-cluster/src/scripts
          cp -r src/lib $out/share/nix-cluster/src/lib 2>/dev/null || true
          chmod +x $out/share/nix-cluster/src/setup.sh $out/share/nix-cluster/src/scripts/*.sh 2>/dev/null || true
          cp -r templates $out/share/nix-cluster/templates

          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nix-cluster-install \
            --add-flags "$out/share/nix-cluster/src/setup.sh" \
            --set NIX_CLUSTER_TEMPLATES_DIR "$out/share/nix-cluster/templates" \
            --set NIX_CLUSTER_SRC_DIR "$out/share/nix-cluster/src" \
            --set NOPS_TEMPLATES_DIR "$out/share/nix-cluster/templates" \
            --set NOPS_SRC_DIR "$out/share/nix-cluster/src" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ 
              pkgs.git pkgs.sops pkgs.age pkgs.vim pkgs.nano pkgs.openssh 
              pkgs.util-linux pkgs.nixos-rebuild pkgs.inetutils 
              pkgs.systemd pkgs.jq pkgs.mkpasswd
            ]}

          ln -s nix-cluster-install $out/bin/nops-install
        '';
      };
    };

    # NixOS module imported by fleet nodes via flake input.
    # Declares the nix-cluster service user, systemd daemon(s), firewall rules, and injects SOPS-decrypted secrets.
    nixosModules.default = { config, lib, pkgs, ... }: 
    let 
      cfg = config.services."nix-cluster";
      serviceUser = "nix-cluster";
      serviceGroup = serviceUser;
      serviceHome = "/home/${serviceUser}";
      legacyServiceHome = "/home/nops";
      runtimeConfigEtcPath = lib.removePrefix "/etc/" cfg.paths.runtimeConfigPath;
      serviceLogFile = "${cfg.paths.logDir}/main.log";
      repoPathString = toString cfg.repoPath;
      legacyRepoPath = if lib.hasPrefix "${serviceHome}/" repoPathString then "${legacyServiceHome}/${lib.removePrefix "${serviceHome}/" repoPathString}" else "";
      storeCfg = cfg.ha.runtimeStore.localServer;
      storeAdvertisePeerUrl = if storeCfg.initialAdvertisePeerUrls != [] then builtins.elemAt storeCfg.initialAdvertisePeerUrls 0 else "http://${config.networking.hostName}:2380";
      storeInitialCluster = if storeCfg.initialCluster != [] then lib.concatStringsSep "," storeCfg.initialCluster else "${storeCfg.name}=${storeAdvertisePeerUrl}";
      trackedUnits = lib.unique (
        [ "nix-cluster.service" ]
        ++ lib.optionals cfg.modules.caddy.enable [ "caddy.service" ]
        ++ lib.optionals cfg.modules.keepalived.enable [ "keepalived.service" ]
        ++ lib.optionals cfg.modules.cloudflare.enable [ "cloudflared.service" ]
        ++ lib.optionals cfg.modules.pxe.enable [ "caddy.service" ]
        ++ lib.optionals (cfg.modules.pxe.enable && cfg.modules.pxe.dhcpEnable) [ "dnsmasq.service" ]
        ++ lib.optionals cfg.modules.postgresBackup.enable [ "postgresqlBackup.timer" ]
        ++ lib.optionals cfg.ha.runtimeStore.localServer.enable [ "nix-cluster-runtime-store.service" ]
        ++ lib.optionals cfg.observability.prometheus.enable [ "prometheus-node-exporter.service" ]
        ++ lib.optionals (cfg.observability.loki.enable && cfg.observability.loki.url != "") [ "promtail.service" ]
        ++ cfg.observability.extraTrackedUnits
      );
      # Serializes repo path and rebuild commands to a JSON file the Python daemon reads at startup.
    nixClusterConfig = pkgs.writeText "nix-cluster-config.json" (builtins.toJSON {
      is_controller = cfg.isController;
      hostname = config.networking.hostName;
      # AUTOMATIC SANITIZATION: Strip \r from the controller script
      controller_script = builtins.replaceStrings [ "\r" ] [ "" ] cfg.controllerScript;
      directories = {
        repo = cfg.repoPath;
        log = cfg.paths.logDir;
        state = cfg.paths.stateDir;
        metrics = cfg.paths.metricsDir;
        heartbeat = cfg.paths.heartbeatStateDir;
        runtime_config = cfg.paths.runtimeConfigPath;
        controller_script_dir = cfg.paths.controllerScriptDir;
      };
      commands = {
        # AUTOMATIC SANITIZATION: Strip \r from every command in the update list
        update = builtins.map (cmd: builtins.replaceStrings [ "\r" ] [ "" ] cmd) cfg.afterPush;
      };
      update = {
        update = builtins.map (cmd: builtins.replaceStrings [ "\r" ] [ "" ] cmd) cfg.afterPush;
        remote_name = cfg.update.remoteName;
        branch_ref = cfg.update.branchRef;
        relevant_paths = cfg.update.relevantPaths;
        worker_wait_seconds = cfg.update.workerWaitSeconds;
      };
      controller = {
        reconcile_interval_seconds = cfg.controller.reconcileIntervalSeconds;
        monitor = {
          enable = cfg.controller.monitor.enable;
          interval_seconds = cfg.controller.monitor.intervalSeconds;
          targets = cfg.controller.monitor.targets;
        };
      };
      placement = {
        node_role = cfg.placement.nodeRole;
        ha_role = cfg.placement.haRole;
        keepalived_role = cfg.placement.keepalivedRole;
      };
      observability = {
        tracked_units = trackedUnits;
        prometheus = {
          enable = cfg.observability.prometheus.enable;
          port = cfg.observability.prometheus.port;
        };
        loki = {
          enable = cfg.observability.loki.enable;
          url = cfg.observability.loki.url;
        };
      };
      ha = {
        enable = cfg.ha.enable;
        reporting = {
          enable = cfg.ha.reporting.enable;
          mode = cfg.ha.reporting.mode;
          services = cfg.ha.reporting.services;
          include_tracked_units = cfg.ha.reporting.includeTrackedUnits;
          interval_seconds = cfg.ha.reporting.intervalSeconds;
        };
        runtime_store = {
          type = cfg.ha.runtimeStore.type;
          endpoint = cfg.ha.runtimeStore.endpoint;
          key_prefix = cfg.ha.runtimeStore.keyPrefix;
          inventory_prefix = cfg.ha.runtimeStore.inventoryPrefix;
          join_prefix = cfg.ha.runtimeStore.joinPrefix;
          stale_after_seconds = cfg.ha.runtimeStore.staleAfterSeconds;
          local_server = {
            enable = cfg.ha.runtimeStore.localServer.enable;
            name = cfg.ha.runtimeStore.localServer.name;
            listen_client_urls = cfg.ha.runtimeStore.localServer.listenClientUrls;
            advertise_client_urls = cfg.ha.runtimeStore.localServer.advertiseClientUrls;
            listen_peer_urls = cfg.ha.runtimeStore.localServer.listenPeerUrls;
            initial_advertise_peer_urls = cfg.ha.runtimeStore.localServer.initialAdvertisePeerUrls;
            initial_cluster = cfg.ha.runtimeStore.localServer.initialCluster;
            initial_cluster_state = cfg.ha.runtimeStore.localServer.initialClusterState;
          };
        };
        scheduler = {
          enable = cfg.ha.scheduler.enable;
          interval_seconds = cfg.ha.scheduler.intervalSeconds;
        };
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
      matrix = {
        enable = cfg.matrix.enable;
        trigger_keywords = cfg.matrix.triggerKeywords;
      };
      webhook = {
        enable = cfg.webhook.enable;
        bind_address = cfg.webhook.bindAddress;
        port = cfg.webhook.port;
        ssl_cert = if cfg.webhook.sslCert != null then cfg.webhook.sslCert else "";
        ssl_key = if cfg.webhook.sslKey != null then cfg.webhook.sslKey else "";
        skip_commit_marker = cfg.webhook.skipCommitMarker;
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
          default = "${serviceHome}/";
        };
        paths = {
          logDir = lib.mkOption {
            type = lib.types.str;
            default = "${serviceHome}/log";
            description = "Directory used for nix-cluster log files.";
          };
          stateDir = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/nix-cluster";
            description = "State directory used for runtime snapshots and HA data.";
          };
          metricsDir = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/nix-cluster/metrics";
            description = "Directory used for Prometheus textfile metrics.";
          };
          heartbeatStateDir = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/nix-cluster-heartbeat";
            description = "Directory used by the worker controller-heartbeat timer.";
          };
          runtimeConfigPath = lib.mkOption {
            type = lib.types.str;
            default = "/etc/nix-cluster-runtime-config.json";
            description = "Path to the generated runtime configuration JSON consumed by the nix-cluster daemons.";
          };
          controllerScriptDir = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/nix-cluster";
            description = "Directory where the controller hook script is materialized before execution.";
          };
        };
        update = {
          remoteName = lib.mkOption {
            type = lib.types.str;
            default = "origin";
            description = "Git remote used by the update manager.";
          };
          branchRef = lib.mkOption {
            type = lib.types.str;
            default = "origin/main";
            description = "Git ref that the update manager resets to before rebuilding.";
          };
          relevantPaths = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "nodes/${config.networking.hostName}/"
              "groups/"
              "modules/"
              "deployments.json"
              "secrets/"
              "scripts/"
              "flake.nix"
              "flake.lock"
            ];
            description = "Repo paths that should trigger a rebuild on this node when changed upstream.";
          };
          workerWaitSeconds = lib.mkOption {
            type = lib.types.int;
            default = 30;
            description = "Seconds a worker waits before re-fetching after controller-side provisioning.";
          };
        };
        afterPush = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "/run/wrappers/bin/sudo /run/current-system/sw/bin/systemd-run --working-directory=${config.services."nix-cluster".repoPath} --service-type=oneshot --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin -- /run/current-system/sw/bin/nixos-rebuild switch --flake ${config.services."nix-cluster".repoPath}#${config.networking.hostName} --impure"
          ];
          description = "Array of shell commands to execute after a push is received.";
        };
        controller.reconcileIntervalSeconds = lib.mkOption {
          type = lib.types.int;
          default = 60;
          description = "How often the controller should rerun reconciliation to detect provisionable nodes even when no webhook event occurs. Set to 0 to disable periodic reconciliation.";
        };
        controller.monitor.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "On non-controller nodes, periodically ping known controller targets and log state changes.";
        };
        controller.monitor.intervalSeconds = lib.mkOption {
          type = lib.types.int;
          default = 15;
          description = "How often workers should check controller reachability.";
        };
        controller.monitor.targets = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Controller hostnames or IPs that workers should ping. Configure at least one stable controller address or VIP.";
        };
        placement = {
          nodeRole = lib.mkOption {
            type = lib.types.enum [ "controller" "worker" "service" "backup" "spare" ];
            default = "worker";
            description = "Default node placement role that modules can use for active/passive/spare decisions.";
          };
          haRole = lib.mkOption {
            type = lib.types.enum [ "active" "passive" "spare" ];
            default = "passive";
            description = "Default HA service role that modules can use to decide whether to expose, standby, or stay idle.";
          };
          keepalivedRole = lib.mkOption {
            type = lib.types.enum [ "master" "backup" "disabled" ];
            default = "disabled";
            description = "Derived Keepalived placement role for modules that need ingress/VIP awareness.";
          };
        };
        observability.extraTrackedUnits = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Additional systemd units to include in on-demand observability checks.";
        };
        observability.prometheus = {
          enable = lib.mkEnableOption "Prometheus node exporter integration for nix-cluster runtime metrics";
          port = lib.mkOption {
            type = lib.types.int;
            default = 9100;
            description = "Port exposed by the node exporter when Prometheus integration is enabled.";
          };
        };
        observability.loki = {
          enable = lib.mkEnableOption "Promtail shipping of systemd journal logs, including nix-cluster.service";
          url = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Loki push endpoint, for example http://loki:3100/loki/api/v1/push.";
          };
        };
        ha = {
          enable = lib.mkEnableOption "real-time service health reporting and controller-side aggregation";
          reporting = {
            enable = lib.mkEnableOption "report selected systemd service health into the nix-cluster runtime store";
            mode = lib.mkOption {
              type = lib.types.enum [ "only" "none_except" "all_except" ];
              default = "only";
              description = "Filter mode for service health reporting. `only` and `none_except` report only the listed services; `all_except` reports every service except the listed ones.";
            };
            services = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Systemd service units used by the reporting filter logic, for example nix-cluster.service or caddy.service.";
            };
            includeTrackedUnits = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Always include the tracked observability units in reporting decisions.";
            };
            intervalSeconds = lib.mkOption {
              type = lib.types.int;
              default = 5;
              description = "Seconds between health snapshots emitted by the reporter.";
            };
          };
          runtimeStore = {
            type = lib.mkOption {
              type = lib.types.enum [ "none" "etcd" ];
              default = "none";
              description = "Runtime state backend used for cross-node health aggregation.";
            };
            endpoint = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "HTTP endpoint for the runtime store, for example http://192.168.2.201:2379.";
            };
            keyPrefix = lib.mkOption {
              type = lib.types.str;
              default = "/nix-cluster/health";
              description = "Prefix used for service health keys in the runtime store.";
            };
            inventoryPrefix = lib.mkOption {
              type = lib.types.str;
              default = "/nix-cluster/inventory";
              description = "Prefix used for node inventory records in the runtime store.";
            };
            joinPrefix = lib.mkOption {
              type = lib.types.str;
              default = "/nix-cluster/join";
              description = "Prefix used for controller-driven join and provisioning state in the runtime store.";
            };
            staleAfterSeconds = lib.mkOption {
              type = lib.types.int;
              default = 15;
              description = "A report older than this is treated as stale by the controller monitor.";
            };
            localServer = {
              enable = lib.mkEnableOption "a local etcd runtime store on this node";
              name = lib.mkOption {
                type = lib.types.str;
                default = config.networking.hostName;
                description = "Member name for the local etcd runtime store.";
              };
              listenClientUrls = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ "http://0.0.0.0:2379" ];
                description = "Client listen URLs for the local etcd runtime store.";
              };
              advertiseClientUrls = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ "http://${config.networking.hostName}:2379" ];
                description = "Advertised client URLs for the local etcd runtime store.";
              };
              listenPeerUrls = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ "http://0.0.0.0:2380" ];
                description = "Peer listen URLs for the local etcd runtime store.";
              };
              initialAdvertisePeerUrls = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ "http://${config.networking.hostName}:2380" ];
                description = "Advertised peer URLs for the local etcd runtime store.";
              };
              initialCluster = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
                description = "Optional explicit etcd initial cluster entries in name=url form.";
              };
              initialClusterState = lib.mkOption {
                type = lib.types.enum [ "new" "existing" ];
                default = "new";
                description = "Initial cluster state used when starting the local etcd runtime store.";
              };
            };
          };
          scheduler = {
            enable = lib.mkEnableOption "controller-side health aggregation and failover planning";
            intervalSeconds = lib.mkOption {
              type = lib.types.int;
              default = 5;
              description = "Seconds between controller runtime-store aggregation passes.";
            };
          };
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
            authorizedKeys = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "SSH public keys baked into the PXE live environment for key-only installer access.";
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
          triggerKeywords = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "push" "commit" "update" ];
            description = "Case-insensitive message fragments that trigger updates from the Matrix listener.";
          };
        };
        webhook = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable the Webhook listener (Forgejo/GitLab/GitHub).";
          };
          bindAddress = lib.mkOption {
            type = lib.types.str;
            default = "0.0.0.0";
            description = "Address for the webhook listener to bind to.";
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
          skipCommitMarker = lib.mkOption {
            type = lib.types.str;
            default = "[skip nix-cluster]";
            description = "Commit message marker that causes webhook-triggered updates to be ignored.";
          };
        };
      };

      config = lib.mkIf cfg.enable {
        services."nix-cluster".placement = {
          nodeRole = lib.mkDefault (if cfg.isController then "controller" else "worker");
          haRole = lib.mkDefault (
            if cfg.placement.nodeRole == "controller" then "active"
            else if cfg.placement.nodeRole == "spare" then "spare"
            else "passive"
          );
          keepalivedRole = lib.mkDefault (
            if !cfg.modules.keepalived.enable then "disabled"
            else if cfg.modules.keepalived.priority >= 150 then "master"
            else "backup"
          );
        };
        assertions = [
          {
            assertion = lib.hasPrefix "/etc/" cfg.paths.runtimeConfigPath;
            message = "services.nix-cluster.paths.runtimeConfigPath must live under /etc so it can be generated declaratively.";
          }
        ];
        networking.firewall.allowedTCPPorts =
          lib.optionals cfg.webhook.enable [ cfg.webhook.port ]
          ++ lib.optionals cfg.ha.runtimeStore.localServer.enable [ 2379 2380 ]
          ++ lib.optionals cfg.observability.prometheus.enable [ cfg.observability.prometheus.port ];
        users.users.${serviceUser} = {
          isNormalUser = true;
          description = "nix-cluster Service Daemon Account";
          group = serviceGroup;
          extraGroups = [ "wheel" "docker" ];
          home = serviceHome;
          createHome = true;
          shell = pkgs.bash;
        };
        users.groups.${serviceGroup} = {};
        environment.systemPackages = [ 
          self.packages.${system}.default 
          pkgs.git 
          pkgs.curl
          pkgs.sops 
          pkgs.inetutils
          pkgs.iputils
          pkgs.openssh
          pkgs.jq
          pkgs.sshpass
          pkgs.mkpasswd
        ] ++ lib.optionals cfg.ha.runtimeStore.localServer.enable [ pkgs.etcd ];
        system.activationScripts.nix-cluster-account-migration.text = ''
          install -d -m 0755 ${serviceHome}
          if [ -d ${legacyServiceHome} ] && [ ! -L ${legacyServiceHome} ]; then
            cp -a ${legacyServiceHome}/. ${serviceHome}/ 2>/dev/null || true
          fi
          ${lib.optionalString (legacyRepoPath != "") ''
          if [ ! -e ${repoPathString} ] && [ -e ${legacyRepoPath} ]; then
            install -d -m 0755 "$(dirname ${repoPathString})"
            cp -a ${legacyRepoPath} ${repoPathString}
          fi
          ''}
          chown -R ${serviceUser}:${serviceGroup} ${serviceHome} 2>/dev/null || true
          if [ -e ${repoPathString} ]; then
            chown -R ${serviceUser}:${serviceGroup} ${repoPathString} 2>/dev/null || true
          fi
        '';
        environment.etc.${runtimeConfigEtcPath}.source = nixClusterConfig;
        systemd.tmpfiles.rules = [
          "d ${cfg.paths.logDir} 0755 ${serviceUser} ${serviceGroup} -"
          "d ${cfg.paths.stateDir} 0755 ${serviceUser} ${serviceGroup} -"
          "d ${cfg.paths.stateDir}/ha 0755 ${serviceUser} ${serviceGroup} -"
          "d ${cfg.paths.metricsDir} 0755 ${serviceUser} ${serviceGroup} -"
          "d ${cfg.paths.heartbeatStateDir} 0755 ${serviceUser} ${serviceGroup} -"
          "d ${cfg.paths.controllerScriptDir} 0755 ${serviceUser} ${serviceGroup} -"
        ] ++ lib.optionals cfg.ha.runtimeStore.localServer.enable [
          "d ${cfg.paths.stateDir}/etcd 0755 ${serviceUser} ${serviceGroup} -"
        ] ++ lib.optionals (cfg.observability.loki.enable && cfg.observability.loki.url != "") [
          "d /var/lib/promtail 0755 promtail promtail -"
        ];

        services.prometheus.exporters.node = lib.mkIf cfg.observability.prometheus.enable {
          enable = true;
          port = cfg.observability.prometheus.port;
          listenAddress = "0.0.0.0";
          enabledCollectors = [ "systemd" "textfile" ];
          extraFlags = [ "--collector.textfile.directory=${cfg.paths.metricsDir}" ];
        };

        services.promtail = lib.mkIf (cfg.observability.loki.enable && cfg.observability.loki.url != "") {
          enable = true;
          configuration = {
            server = {
              http_listen_port = 9080;
              grpc_listen_port = 0;
            };
            positions = {
              filename = "/var/lib/promtail/positions.yaml";
            };
            clients = [{
              url = cfg.observability.loki.url;
            }];
            scrape_configs = [{
              job_name = "journal";
              journal = {
                max_age = "24h";
                labels = {
                  job = "systemd-journal";
                  host = config.networking.hostName;
                  cluster_service = "nix-cluster";
                };
              };
              relabel_configs = [
                {
                  source_labels = [ "__journal__systemd_unit" ];
                  target_label = "unit";
                }
                {
                  source_labels = [ "__journal_priority" ];
                  target_label = "priority";
                }
              ];
            }];
          };
        };

        systemd.services.promtail = lib.mkIf (cfg.observability.loki.enable && cfg.observability.loki.url != "") {
          serviceConfig.SupplementaryGroups = [ "systemd-journal" ];
        };

        systemd.services."nix-cluster-runtime-store" = lib.mkIf cfg.ha.runtimeStore.localServer.enable {
          description = "nix-cluster runtime state store (etcd)";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            User = serviceUser;
            Group = serviceGroup;
            Restart = "always";
            RestartSec = "10s";
            WorkingDirectory = "${cfg.paths.stateDir}/etcd";
          };
          script = ''
            exec ${pkgs.etcd}/bin/etcd \
              --name=${lib.escapeShellArg storeCfg.name} \
              --data-dir=${lib.escapeShellArg "${cfg.paths.stateDir}/etcd"} \
              --listen-client-urls=${lib.escapeShellArg (lib.concatStringsSep "," storeCfg.listenClientUrls)} \
              --advertise-client-urls=${lib.escapeShellArg (lib.concatStringsSep "," storeCfg.advertiseClientUrls)} \
              --listen-peer-urls=${lib.escapeShellArg (lib.concatStringsSep "," storeCfg.listenPeerUrls)} \
              --initial-advertise-peer-urls=${lib.escapeShellArg (lib.concatStringsSep "," storeCfg.initialAdvertisePeerUrls)} \
              --initial-cluster=${lib.escapeShellArg storeInitialCluster} \
              --initial-cluster-state=${lib.escapeShellArg storeCfg.initialClusterState}
          '';
        };
        
        # Runs the nix-cluster listener(s) as the nix-cluster user. Spawns the Matrix daemon and/or webhook server based on enabled options.
        systemd.services."nix-cluster" = {
          description = "nix-cluster Operations Listener Daemon";
          aliases = [ "nops.service" ];
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          path = [ pkgs.git pkgs.curl pkgs.nixos-rebuild pkgs.inetutils pkgs.systemd pkgs.bash pkgs.openssl pkgs.sops pkgs.age pkgs.openssh pkgs.jq pkgs.sshpass pkgs.mkpasswd ]
            ++ lib.optionals cfg.isController [ pkgs.terraform ];
          serviceConfig = {
            User = serviceUser;
            Restart = "always";
            RestartSec = "10s";
            WorkingDirectory = cfg.repoPath;
          };
          
          environment = {
            NIX_CLUSTER_CONFIG_PATH = cfg.paths.runtimeConfigPath;
            NIX_CLUSTER_LOG_PATH = serviceLogFile;
            NOPS_CONFIG_PATH = cfg.paths.runtimeConfigPath;
            NOPS_LOG_PATH = serviceLogFile;
            MATRIX_BOT_TOKEN_FILE = config.sops.secrets.matrix_bot_token.path;
            MATRIX_ROOM_ID_FILE = config.sops.secrets.matrix_room_id.path;
            MATRIX_HOMESERVER_FILE = config.sops.secrets.matrix_homeserver.path;
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
               ${self.packages.${system}.default}/bin/nix-cluster-daemon &
             fi

             if [ "${builtins.toString cfg.webhook.enable}" = "1" ]; then
               ${self.packages.${system}.default}/bin/nix-cluster-webhook &
             fi

             if [ "${builtins.toString (cfg.ha.enable && cfg.ha.reporting.enable)}" = "1" ]; then
               ${self.packages.${system}.default}/bin/nix-cluster-reporter &
             fi

             if [ "${builtins.toString (cfg.isController && cfg.ha.enable && cfg.ha.scheduler.enable && cfg.ha.runtimeStore.type == "etcd" && cfg.ha.runtimeStore.endpoint != "")}" = "1" ]; then
               ${self.packages.${system}.default}/bin/nix-cluster-monitor &
             fi
             
             wait -n
          '';
        };

        systemd.services."nix-cluster-controller-heartbeat" = lib.mkIf (!cfg.isController && cfg.controller.monitor.enable && cfg.controller.monitor.targets != []) {
          description = "nix-cluster controller heartbeat monitor";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            User = serviceUser;
            Group = serviceGroup;
          };
          environment = {
            NIX_CLUSTER_RUNTIME_CONFIG_PATH = cfg.paths.runtimeConfigPath;
            NIX_CLUSTER_HEARTBEAT_STATE_DIR = cfg.paths.heartbeatStateDir;
            NOPS_RUNTIME_CONFIG_PATH = cfg.paths.runtimeConfigPath;
            NOPS_HEARTBEAT_STATE_DIR = cfg.paths.heartbeatStateDir;
          };
          script = ''
            exec ${self.packages.${system}.default}/bin/nix-cluster-controller-heartbeat
          '';
        };

        systemd.timers."nix-cluster-controller-heartbeat" = lib.mkIf (!cfg.isController && cfg.controller.monitor.enable && cfg.controller.monitor.targets != []) {
          description = "nix-cluster controller heartbeat monitor timer";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitActiveSec = "${toString cfg.controller.monitor.intervalSeconds}s";
            Unit = "nix-cluster-controller-heartbeat.service";
          };
        };
      };
    };

    # Exposes nix-cluster commands as runnable Nix apps.
    apps.${system} = {
      install = { 
        type = "app"; 
        program = "${self.packages.${system}.install}/bin/nix-cluster-install"; 
      };
    };
  };
}