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
    sharedStorageClientOptions = [
      "rw"
      "hard"
      "timeo=600"
      "retrans=2"
      "_netdev"
      "x-systemd.requires=network-online.target"
      "x-systemd.after=network-online.target"
    ];
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
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.inetutils pkgs.nixos-rebuild pkgs.systemd pkgs.procps pkgs.bash pkgs.sops pkgs.age pkgs.jq pkgs.openssh pkgs.sshpass pkgs.mkpasswd ]}

          # Wraps the Webhook server with required binaries for fleet operations.
          # Injects git, nixos-rebuild, and secret management tools into the execution environment.
          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster-webhook \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.webhook" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.inetutils pkgs.nixos-rebuild pkgs.systemd pkgs.procps pkgs.bash pkgs.sops pkgs.age pkgs.jq pkgs.openssh pkgs.sshpass pkgs.mkpasswd ]}

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

          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nix-cluster-secret-ensure \
            --add-flags "$out/lib/scripts/secret-ensure.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.sops pkgs.age pkgs.openssl pkgs.jq pkgs.coreutils pkgs.bash ]}

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

          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster-reconciler \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.ha reconciler" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.coreutils pkgs.bash ]}

          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster-recovery \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.ha recovery" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.coreutils pkgs.bash ]}

          ln -s nix-cluster-daemon $out/bin/nops-daemon
          ln -s nix-cluster-webhook $out/bin/nops-webhook
          ln -s nix-cluster-observe $out/bin/nops-observe
          ln -s nix-cluster-node $out/bin/nops-node
          ln -s nix-cluster-fleet-status $out/bin/nops-fleet-status
          ln -s nix-cluster-fleet-watch $out/bin/nops-fleet-watch
          ln -s nix-cluster-secret-ensure $out/bin/nops-secret-ensure
          ln -s nix-cluster-controller-heartbeat $out/bin/nops-controller-heartbeat
          ln -s nix-cluster-reporter $out/bin/nops-reporter
          ln -s nix-cluster-monitor $out/bin/nops-monitor
          ln -s nix-cluster-reconciler $out/bin/nops-reconciler
          ln -s nix-cluster-recovery $out/bin/nops-recovery
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
      sharedHomes = cfg.identity.sharedHomes;
      sharedStorage = cfg.storage;
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
      isSharedHomeNode = config.networking.hostName == sharedHomes.homeNode;
      sharedHomeClient = sharedHomes.enable && !isSharedHomeNode && !(builtins.elem config.networking.hostName sharedHomes.skipClientNodes);
      sharedStorageClient = sharedStorage.enable && !isSharedHomeNode;
      trackedUnits = lib.unique (
        [ "nix-cluster.service" ]
        ++ lib.optionals cfg.localRecovery.enable cfg.localRecovery.criticalUnits
        ++ lib.optionals cfg.ha.runtimeStore.localServer.enable [ "nix-cluster-runtime-store.service" ]
        ++ lib.optionals cfg.observability.prometheus.enable [ "prometheus-node-exporter.service" ]
        ++ lib.optionals (cfg.observability.loki.enable && cfg.observability.loki.url != "") [ "promtail.service" ]
        ++ cfg.observability.monitoredServices
        ++ cfg.observability.extraTrackedUnits
      );
      appCfg = cfg.apps;
      secretGenerationRequests = lib.mapAttrs (_: request: {
        generator = request.generator;
        length = request.length;
      }) cfg.secretGeneration.requests;
      workerInventory = lib.mapAttrs (name: worker: {
        hostname = name;
        node_directory = worker.nodeDirectory;
        installer_ip = worker.installerIp;
        installer_user = worker.installerUser;
        installer_auth_mode = worker.installerAuthMode;
        installer_ssh_pub_key = worker.installerSshPubKey;
        installer_password = worker.installerPassword;
        installer_mode = worker.installerMode;
        installer_script = worker.installerScript;
        installer_pre_script = worker.installerPreScript;
        installer_post_script = worker.installerPostScript;
        reinstall = worker.reinstall;
        disk = worker.disk;
        fs = worker.fs;
        node_group = worker.nodeGroup;
        node_role = worker.nodeRole;
        keepalived_role = worker.keepalivedRole;
        node_admin = worker.nodeAdmin;
        ssh_password_auth = worker.sshPasswordAuth;
        node_admin_pass = worker.nodeAdminPass;
        node_admin_password_hash = worker.nodeAdminPasswordHash;
      }) cfg.workers;
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
      local_recovery = {
        enable = cfg.localRecovery.enable;
        critical_units = cfg.localRecovery.criticalUnits;
        interval_seconds = cfg.localRecovery.intervalSeconds;
        dry_run = cfg.localRecovery.dryRun;
      };
      workers = workerInventory;
      apps = {
        caddy = {
          enable = appCfg.caddy.enable;
        };
        keepalived = {
          enable = appCfg.keepalived.enable;
          interface = appCfg.keepalived.interface;
          virtual_router_id = appCfg.keepalived.virtualRouterId;
          priority = appCfg.keepalived.priority;
          vip_cidr = appCfg.keepalived.vipCidr;
        };
        cloudflare = {
          enable = appCfg.cloudflare.enable;
          tunnel = appCfg.cloudflare.tunnel;
          tunnel_name = appCfg.cloudflare.tunnelName;
          tunnel_domain = appCfg.cloudflare.tunnelDomain;
          tunnel_vip = appCfg.cloudflare.vip;
          zone_id = appCfg.cloudflare.zoneId;
          account_id = appCfg.cloudflare.accountId;
        };
        pxe = {
          enable = appCfg.pxe.enable;
          dhcp_enable = appCfg.pxe.dhcpEnable;
          interface = appCfg.pxe.interface;
          http_port = appCfg.pxe.httpPort;
          boot_url = appCfg.pxe.bootUrl;
        };
        postgres_backup = {
          enable = appCfg.postgresBackup.enable;
        };
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
      secret_generation = {
        enable = cfg.secretGeneration.enable;
        sops_file = cfg.secretGeneration.sopsFile;
        requests = secretGenerationRequests;
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
            controller_mode = cfg.ha.scheduler.controllerMode;
            fixed_controller_host = cfg.ha.scheduler.fixedControllerHost;
            leader_key = cfg.ha.scheduler.leaderKey;
            placement_prefix = cfg.ha.scheduler.placementPrefix;
            lease_ttl_seconds = cfg.ha.scheduler.leaseTtlSeconds;
            default_strategy = cfg.ha.scheduler.defaultStrategy;
          managed_units = cfg.ha.scheduler.managedUnits;
          reconciler_enable = cfg.ha.scheduler.reconcilerEnable;
          reconciler_interval_seconds = cfg.ha.scheduler.reconcilerIntervalSeconds;
          reconciler_dry_run = cfg.ha.scheduler.reconcilerDryRun;
          resource_prefix = cfg.ha.scheduler.resourcePrefix;
          resource_interval_seconds = cfg.ha.scheduler.resourceIntervalSeconds;
        };
      };
      modules = {
        caddy = {
          enable = appCfg.caddy.enable;
        };
        keepalived = {
          enable = appCfg.keepalived.enable;
          interface = appCfg.keepalived.interface;
          virtual_router_id = appCfg.keepalived.virtualRouterId;
          priority = appCfg.keepalived.priority;
          vip_cidr = appCfg.keepalived.vipCidr;
        };
        cloudflare = {
          enable = appCfg.cloudflare.enable;
          tunnel = appCfg.cloudflare.tunnel;
          tunnel_name = appCfg.cloudflare.tunnelName;
          tunnel_domain = appCfg.cloudflare.tunnelDomain;
          tunnel_vip = appCfg.cloudflare.vip;
          zone_id = appCfg.cloudflare.zoneId;
          account_id = appCfg.cloudflare.accountId;
        };
        pxe = {
          enable = appCfg.pxe.enable;
          dhcp_enable = appCfg.pxe.dhcpEnable;
          interface = appCfg.pxe.interface;
          http_port = appCfg.pxe.httpPort;
          boot_url = appCfg.pxe.bootUrl;
        };
        postgres_backup = {
          enable = appCfg.postgresBackup.enable;
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
        (lib.mkRenamedOptionModule [ "services" "nix-cluster" "modules" ] [ "services" "nix-cluster" "apps" ])
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
        serviceAccount.authorizedKeys = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "SSH public keys authorized for the nix-cluster service account.";
        };
        identity.sharedHomes = {
          enable = lib.mkEnableOption "controller-backed shared Unix home directories";
          homeNode = lib.mkOption {
            type = lib.types.str;
            default = "node1";
            description = "Node that owns and exports the shared home tree.";
          };
          homeAddress = lib.mkOption {
            type = lib.types.str;
            default = "192.168.2.201";
            description = "Address of the node exporting the shared home tree.";
          };
          mountPath = lib.mkOption {
            type = lib.types.path;
            default = "/home";
            description = "Mount path for shared user homes.";
          };
          exportNetwork = lib.mkOption {
            type = lib.types.str;
            default = "192.168.2.0/24";
            description = "Network allowed to mount shared homes and app storage.";
          };
          exportOptions = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "rw" "sync" "no_subtree_check" "no_root_squash" "crossmnt" ];
            description = "NFS export options for the shared home tree.";
          };
          clientOptions = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = sharedStorageClientOptions;
            description = "NFS client options for shared homes.";
          };
          skipClientNodes = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Nodes explicitly exempted from the shared-home mount.";
          };
        };
        storage = {
          enable = lib.mkEnableOption "controller-backed shared application storage";
          appRoot = lib.mkOption {
            type = lib.types.path;
            default = "/srv/nix-cluster/apps";
            description = "Shared persistent storage root for nix-cluster applications.";
          };
          exportPath = lib.mkOption {
            type = lib.types.path;
            default = "/srv/nix-cluster";
            description = "Controller path exported to worker nodes for app storage.";
          };
          clientOptions = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = sharedStorageClientOptions;
            description = "NFS client options for shared application storage.";
          };
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
              "apps/"
              "modules/"
              "secrets/"
              "scripts/"
              "flake.nix"
              "flake.lock"
            ];
            description = "Repo paths that should trigger a rebuild on this node when changed upstream. Controller-only inventory files such as deployments.json are consumed by the controller hook and do not need a local rebuild.";
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
            "/run/wrappers/bin/sudo /run/current-system/sw/bin/systemd-run --wait --collect --pipe --working-directory=${config.services."nix-cluster".repoPath} --service-type=oneshot --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin -- /run/current-system/sw/bin/nixos-rebuild switch --flake ${config.services."nix-cluster".repoPath}#${config.networking.hostName} --impure"
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
            description = "Default node placement role that apps can use for active/passive/spare decisions.";
          };
          haRole = lib.mkOption {
            type = lib.types.enum [ "active" "passive" "spare" ];
            default = "passive";
            description = "Default HA service role that apps can use to decide whether to expose, standby, or stay idle.";
          };
          keepalivedRole = lib.mkOption {
            type = lib.types.enum [ "master" "backup" "disabled" ];
            default = "disabled";
            description = "Derived Keepalived placement role for apps that need ingress/VIP awareness.";
          };
        };
        localRecovery = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable local critical-unit recovery inside nix-cluster.service on every node where nix-cluster runs.";
          };
          criticalUnits = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "NetworkManager.service" ];
            description = "Local systemd units that nix-cluster should keep active on this node, independent of scheduler placement or etcd health.";
          };
          intervalSeconds = lib.mkOption {
            type = lib.types.int;
            default = 15;
            description = "Seconds between local critical-unit recovery checks.";
          };
          dryRun = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Log local critical-unit recovery actions without starting units.";
          };
        };
        observability.extraTrackedUnits = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Additional systemd units to include in on-demand observability checks.";
        };
        observability.monitoredServices = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Systemd units appended by external or registry-backed apps so the HA reporter and diagnostics can track them without core hard-coding every app.";
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
        secretGeneration = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Allow nix-cluster to reconcile app-declared generated secrets into the fleet SOPS file before rebuilds.";
          };
          sopsFile = lib.mkOption {
            type = lib.types.str;
            default = "secrets/secrets.yaml";
            description = "Fleet-relative SOPS file where generated app secrets are stored.";
          };
          requests = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
              options = {
                generator = lib.mkOption {
                  type = lib.types.enum [ "base64" "hex" "alnum" ];
                  default = "base64";
                  description = "Generator used when nix-cluster creates the secret value.";
                };
                length = lib.mkOption {
                  type = lib.types.int;
                  default = 48;
                  description = "Generated secret length.";
                };
              };
            }));
            default = {};
            description = "App-declared generated secrets keyed by the SOPS secret name.";
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
              default = 15;
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
              quotaBackendBytes = lib.mkOption {
                type = lib.types.int;
                default = 8589934592;
                description = "Maximum etcd backend database size before NOSPACE alarms block writes.";
              };
              autoCompactionMode = lib.mkOption {
                type = lib.types.enum [ "periodic" "revision" ];
                default = "periodic";
                description = "etcd auto-compaction mode for the local runtime store.";
              };
              autoCompactionRetention = lib.mkOption {
                type = lib.types.str;
                default = "1h";
                description = "Retention window/revision passed to etcd auto-compaction.";
              };
              maintenance = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Periodically compact, defrag, and disarm cleared NOSPACE alarms for the local etcd runtime store.";
                };
                intervalSeconds = lib.mkOption {
                  type = lib.types.int;
                  default = 3600;
                  description = "Seconds between local etcd runtime-store maintenance passes.";
                };
                retainRevisions = lib.mkOption {
                  type = lib.types.int;
                  default = 1000;
                  description = "Recent revisions to keep when the maintenance job compacts etcd.";
                };
                commandTimeoutSeconds = lib.mkOption {
                  type = lib.types.int;
                  default = 120;
                  description = "Timeout for each etcdctl maintenance command.";
                };
                defrag = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Run etcd defrag after maintenance compaction.";
                };
                disarmAlarms = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Attempt to disarm etcd alarms after compaction/defrag frees space.";
                };
              };
            };
          };
          scheduler = {
            enable = lib.mkEnableOption "controller-side health aggregation and failover planning";
            intervalSeconds = lib.mkOption {
              type = lib.types.int;
              default = 15;
              description = "Seconds between controller runtime-store aggregation passes.";
            };
            controllerMode = lib.mkOption {
              type = lib.types.enum [ "fixed" "elected" ];
              default = "fixed";
              description = "How scheduler leadership is chosen. `fixed` uses fixedControllerHost when set; `elected` uses the runtime store to acquire a short-lived scheduler leadership record among controller-capable nodes.";
            };
            fixedControllerHost = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Hostname that should publish desired placement when controllerMode is `fixed`. Leave empty for single-controller deployments; set this explicitly before enabling multiple fixed-mode controllers.";
            };
            leaderKey = lib.mkOption {
              type = lib.types.str;
              default = "/nix-cluster/scheduler/leader";
              description = "Runtime store key used for scheduler leadership state.";
            };
            placementPrefix = lib.mkOption {
              type = lib.types.str;
              default = "/nix-cluster/scheduler/placement";
              description = "Runtime store prefix where the scheduler publishes desired service ownership records.";
            };
            leaseTtlSeconds = lib.mkOption {
              type = lib.types.int;
              default = 15;
              description = "Lease TTL used for elected scheduler leadership records.";
            };
            defaultStrategy = lib.mkOption {
              type = lib.types.enum [ "prefer-current-healthy" "first-healthy" ];
              default = "prefer-current-healthy";
              description = "Default service placement strategy used while app-specific placement policies are being introduced.";
            };
            managedUnits = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Systemd units that the worker-side scheduler reconciler may start or stop based on desired placement records.";
            };
            reconcilerEnable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable the local scheduler reconciler that consumes desired placement records and actuates scheduler-managed units through systemd.";
            };
            reconcilerIntervalSeconds = lib.mkOption {
              type = lib.types.int;
              default = 15;
              description = "Seconds between worker-side scheduler reconciliation passes.";
            };
            reconcilerDryRun = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "When true, log scheduler reconciliation actions without starting or stopping units.";
            };
            resourcePrefix = lib.mkOption {
              type = lib.types.str;
              default = "/nix-cluster/scheduler/resources";
              description = "Runtime store prefix where nodes publish scheduler resource and capacity records.";
            };
            resourceIntervalSeconds = lib.mkOption {
              type = lib.types.int;
              default = 15;
              description = "Seconds between local resource and capacity snapshots published for scheduler decisions.";
            };
          };
        };
        apps = {
          caddy.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable the Caddy reverse proxy app.";
          };
          keepalived = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable the Keepalived VIP app.";
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
              description = "Enable the Cloudflare tunnel app.";
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
        workers = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
            options = {
              nodeDirectory = lib.mkOption {
                type = lib.types.str;
                default = "nodes/${name}";
                description = "Repo path for the worker node's authoritative NixOS configuration.";
              };
              installerIp = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "IP address the controller should probe for the worker's live installer or installed OS.";
              };
              installerUser = lib.mkOption {
                type = lib.types.str;
                default = "nixos";
                description = "Live installer username used during PXE provisioning.";
              };
              installerAuthMode = lib.mkOption {
                type = lib.types.enum [ "ssh_key" "password" "auto" ];
                default = "ssh_key";
                description = "Authentication mode used by the controller when connecting to the live installer.";
              };
              installerSshPubKey = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "SSH public key baked into the live installer for this worker relationship.";
              };
              installerPassword = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "Optional live installer password for password-based recovery paths.";
              };
              installerMode = lib.mkOption {
                type = lib.types.enum [ "default" "replace" "hooks" ];
                default = "default";
                description = "Install strategy for this worker: default runs nixos-install, replace runs only installerScript, hooks runs installerPreScript + default install + installerPostScript.";
              };
              installerScript = lib.mkOption {
                type = lib.types.lines;
                default = "";
                description = "Custom install script body used when installerMode is set to replace.";
              };
              installerPreScript = lib.mkOption {
                type = lib.types.lines;
                default = "";
                description = "Optional pre-install hook script body used when installerMode is hooks.";
              };
              installerPostScript = lib.mkOption {
                type = lib.types.lines;
                default = "";
                description = "Optional post-install hook script body used when installerMode is hooks.";
              };
              reinstall = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Whether the controller should reprovision this worker on the next reconcile.";
              };
              disk = lib.mkOption {
                type = lib.types.str;
                default = "/dev/sda";
                description = "Target disk passed to the live installer for this worker.";
              };
              fs = lib.mkOption {
                type = lib.types.str;
                default = "zfs";
                description = "Filesystem profile passed to the live installer for this worker.";
              };
              nodeGroup = lib.mkOption {
                type = lib.types.str;
                default = "default";
                description = "Fleet group whose shared config should be applied when the worker enrolls.";
              };
              nodeRole = lib.mkOption {
                type = lib.types.enum [ "controller" "worker" "service" "backup" "spare" ];
                default = "worker";
                description = "Relationship role the controller should assign during worker enrollment.";
              };
              keepalivedRole = lib.mkOption {
                type = lib.types.enum [ "master" "backup" "disabled" ];
                default = "backup";
                description = "Keepalived role the controller should assign during worker enrollment.";
              };
              nodeAdmin = lib.mkOption {
                type = lib.types.str;
                default = "admin";
                description = "Admin username the controller should use once the worker is on a base OS.";
              };
              sshPasswordAuth = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Whether the enrolled worker should allow SSH password authentication for the declared admin user.";
              };
              nodeAdminPass = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "Optional plaintext admin password used only for bootstrap compatibility paths.";
              };
              nodeAdminPasswordHash = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "Password hash assigned to the declared admin user when the worker enrolls.";
              };
            };
          }));
          default = {};
          description = "Controller-to-worker relationship inventory used to hydrate PXE/live install behavior while each worker still owns its full system config under its node directory.";
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
            if !cfg.apps.keepalived.enable then "disabled"
            else if cfg.apps.keepalived.priority >= 150 then "master"
            else "backup"
          );
        };
        assertions = [
          {
            assertion = lib.hasPrefix "/etc/" cfg.paths.runtimeConfigPath;
            message = "services.nix-cluster.paths.runtimeConfigPath must live under /etc so it can be generated declaratively.";
          }
          {
            assertion = !sharedHomes.enable || (sharedHomes.homeNode != "" && sharedHomes.homeAddress != "" && sharedHomes.mountPath == "/home");
            message = "Shared homes require a homeNode, homeAddress, and mountPath=/home.";
          }
          {
            assertion = !sharedStorage.enable || (sharedHomes.enable && sharedStorage.appRoot != "" && lib.hasPrefix "/srv/nix-cluster/" (toString sharedStorage.appRoot));
            message = "Shared application storage requires shared homes and an appRoot below /srv/nix-cluster/.";
          }
          {
            assertion = (!cfg.ha.scheduler.enable) || cfg.ha.scheduler.controllerMode != "elected" || cfg.ha.scheduler.leaseTtlSeconds > cfg.ha.scheduler.intervalSeconds;
            message = "services.nix-cluster.ha.scheduler.leaseTtlSeconds must be greater than intervalSeconds when elected scheduler leadership is enabled.";
          }
        ];
        services.timesyncd.enable = true;
        services.nfs.server = lib.mkIf (sharedHomes.enable && isSharedHomeNode) {
          enable = true;
          exports = ''
            / ${sharedHomes.exportNetwork}(rw,sync,no_subtree_check,fsid=0,crossmnt,root_squash)
            ${sharedHomes.mountPath} ${sharedHomes.exportNetwork}(${lib.concatStringsSep "," sharedHomes.exportOptions})
            ${sharedStorage.exportPath} ${sharedHomes.exportNetwork}(rw,sync,no_subtree_check,no_root_squash,fsid=1,crossmnt)
          '';
        };
        fileSystems = lib.mkMerge [
          (lib.mkIf sharedHomeClient {
            ${sharedHomes.mountPath} = lib.mkForce {
              device = "${sharedHomes.homeAddress}:${sharedHomes.mountPath}";
              fsType = "nfs4";
              options = sharedHomes.clientOptions;
            };
          })
          (lib.mkIf sharedStorageClient {
            ${sharedStorage.exportPath} = lib.mkForce {
              # Mount the exported tree at its real path so appRoot remains
              # the expected ${sharedStorage.exportPath}/apps subtree.
              device = "${sharedHomes.homeAddress}:${sharedStorage.exportPath}";
              fsType = "nfs4";
              options = sharedStorage.clientOptions;
            };
          })
        ];
        systemd.services.nix-cluster-shared-storage-ready = lib.mkIf (sharedHomes.enable || sharedStorage.enable) {
          description = "Verify nix-cluster shared storage is mounted and authoritative";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          requires = [ ];
          wants = [ "network-online.target" ];
          unitConfig.RequiresMountsFor = [ (toString sharedHomes.mountPath) ] ++ lib.optionals sharedStorage.enable [ (toString sharedStorage.exportPath) ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -eu
            ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg (toString sharedHomes.mountPath)}
            test -f ${lib.escapeShellArg (toString sharedHomes.mountPath)}/.nix-cluster-shared-root
            ${lib.optionalString sharedStorage.enable ''
              ${lib.optionalString sharedStorageClient "${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg (toString sharedStorage.exportPath)}"}
              test -f ${lib.escapeShellArg (toString sharedStorage.appRoot)}/.nix-cluster-shared-root
            ''}
          '';
        };
        networking.firewall.allowedTCPPorts =
          lib.optionals cfg.webhook.enable [ cfg.webhook.port ]
          ++ lib.optionals cfg.ha.runtimeStore.localServer.enable [ 2379 2380 ]
          ++ lib.optionals cfg.observability.prometheus.enable [ cfg.observability.prometheus.port ]
          ++ lib.optionals (sharedHomes.enable && isSharedHomeNode) [ 2049 ];
        users.users.${serviceUser} = {
          isNormalUser = true;
          description = "nix-cluster Service Daemon Account";
          group = serviceGroup;
          extraGroups = [ "wheel" "docker" ];
          home = serviceHome;
          createHome = true;
          shell = pkgs.bash;
          openssh.authorizedKeys.keys = cfg.serviceAccount.authorizedKeys;
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
        ] ++ lib.optionals (sharedHomes.enable && isSharedHomeNode) [
          "d ${sharedStorage.exportPath} 0755 root root -"
          "d ${sharedStorage.appRoot} 0755 root root -"
          "f ${sharedHomes.mountPath}/.nix-cluster-shared-root 0644 root root -"
          "f ${sharedStorage.appRoot}/.nix-cluster-shared-root 0644 root root -"
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
              --initial-cluster-state=${lib.escapeShellArg storeCfg.initialClusterState} \
              --quota-backend-bytes=${toString storeCfg.quotaBackendBytes} \
              --auto-compaction-mode=${lib.escapeShellArg storeCfg.autoCompactionMode} \
              --auto-compaction-retention=${lib.escapeShellArg storeCfg.autoCompactionRetention}
          '';
        };

        systemd.services."nix-cluster-runtime-store-maintenance" = lib.mkIf (cfg.ha.runtimeStore.localServer.enable && storeCfg.maintenance.enable) {
          description = "nix-cluster runtime state store maintenance";
          after = [ "nix-cluster-runtime-store.service" ];
          requires = [ "nix-cluster-runtime-store.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = serviceUser;
            Group = serviceGroup;
          };
          script = ''
            set -u
            endpoint="http://127.0.0.1:2379"
            timeout="${toString storeCfg.maintenance.commandTimeoutSeconds}s"
            rev="$(${pkgs.etcd}/bin/etcdctl --endpoints="$endpoint" --command-timeout="$timeout" endpoint status -w json | ${pkgs.jq}/bin/jq -r '.[0].Status.header.revision // .[0].Status.Header.revision // 0')"
            if [ "$rev" -gt ${toString storeCfg.maintenance.retainRevisions} ]; then
              compact_rev=$((rev - ${toString storeCfg.maintenance.retainRevisions}))
              ${pkgs.etcd}/bin/etcdctl --endpoints="$endpoint" --command-timeout="$timeout" compact "$compact_rev" || true
            fi
            ${lib.optionalString storeCfg.maintenance.defrag ''
              ${pkgs.etcd}/bin/etcdctl --endpoints="$endpoint" --command-timeout="$timeout" defrag || true
            ''}
            ${lib.optionalString storeCfg.maintenance.disarmAlarms ''
              ${pkgs.etcd}/bin/etcdctl --endpoints="$endpoint" --command-timeout="$timeout" alarm disarm || true
            ''}
            ${pkgs.etcd}/bin/etcdctl --endpoints="$endpoint" --command-timeout="$timeout" endpoint status -w table || true
          '';
        };

        systemd.timers."nix-cluster-runtime-store-maintenance" = lib.mkIf (cfg.ha.runtimeStore.localServer.enable && storeCfg.maintenance.enable) {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "10min";
            OnUnitActiveSec = "${toString storeCfg.maintenance.intervalSeconds}s";
            Unit = "nix-cluster-runtime-store-maintenance.service";
          };
        };
        
        # Runs the nix-cluster listener(s) as the nix-cluster user. Spawns the Matrix daemon and/or webhook server based on enabled options.
        systemd.services."nix-cluster" = {
          description = "nix-cluster Operations Listener Daemon";
          aliases = [ "nops.service" ];
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          path = [ pkgs.git pkgs.curl pkgs.nixos-rebuild pkgs.inetutils pkgs.systemd pkgs.procps pkgs.bash pkgs.openssl pkgs.sops pkgs.age pkgs.openssh pkgs.jq pkgs.sshpass pkgs.mkpasswd ]
            ++ lib.optionals cfg.isController [ pkgs.terraform ];
          serviceConfig = {
            User = serviceUser;
            Restart = "always";
            RestartSec = "10s";
            WorkingDirectory = "/";
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

             if [ "${builtins.toString (cfg.ha.enable && cfg.ha.scheduler.enable && cfg.ha.scheduler.reconcilerEnable && cfg.ha.runtimeStore.type == "etcd" && cfg.ha.runtimeStore.endpoint != "")}" = "1" ]; then
               ${self.packages.${system}.default}/bin/nix-cluster-reconciler &
             fi

             if [ "${builtins.toString cfg.localRecovery.enable}" = "1" ]; then
               ${self.packages.${system}.default}/bin/nix-cluster-recovery &
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
    checks.${system}.shared-storage-client-options = assert !(builtins.elem "x-systemd.automount" sharedStorageClientOptions); pkgs.runCommand "shared-storage-client-options" {} ''
      touch $out
    '';
  };
}
