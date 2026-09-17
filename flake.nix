{
  description = "nix-cluster - Nix Cluster Controller";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
  };

  # Everything this flake exposes lives under one Linux system target for now.
  outputs = { self, nixpkgs, sops-nix, ... }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    
    # These are the Python libraries the runtime daemons import directly.
    pythonDeps = ps: with ps; [ matrix-nio pyyaml aiohttp ];
    # The wrappers below call this Python with src/ added to PYTHONPATH.
    pythonEnv = pkgs.python3.withPackages pythonDeps;
    # Shared NFS mounts should block until storage is truly reachable, not fail
    # open through automount behavior that can hide broken app data paths.
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
    # Build outputs: one runtime package and one installer package.
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
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.inetutils pkgs.nixos-rebuild pkgs.systemd pkgs.procps pkgs.bash pkgs.sops pkgs.age pkgs.jq pkgs.openssh pkgs.sshpass pkgs.mkpasswd pkgs.util-linux ]}

          # Wraps the Webhook server with required binaries for fleet operations.
          # Injects git, nixos-rebuild, and secret management tools into the execution environment.
          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster-webhook \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.webhook" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.inetutils pkgs.nixos-rebuild pkgs.systemd pkgs.procps pkgs.bash pkgs.sops pkgs.age pkgs.jq pkgs.openssh pkgs.sshpass pkgs.mkpasswd pkgs.util-linux ]}

          # Local status/journal helper. This is for looking at the current node.
          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nix-cluster-observe \
            --add-flags "$out/lib/scripts/observe.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.jq pkgs.bash ]}

          # Remote status/journal helper. This shells into another node and
          # asks that node to run nix-cluster-observe.
          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nix-cluster-node \
            --add-flags "$out/lib/scripts/node-observe.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.openssh pkgs.sshpass pkgs.sops pkgs.age pkgs.jq pkgs.bash ]}

          # Fleet summary helper. It fans out through nix-cluster-node and
          # returns either readable text or JSON.
          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nix-cluster-fleet-status \
            --add-flags "$out/lib/scripts/fleet-status.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.sops pkgs.age pkgs.jq pkgs.openssh pkgs.bash ]}

          # Polling view over fleet-status, useful while enrollments or
          # failovers are moving.
          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nix-cluster-fleet-watch \
            --add-flags "$out/lib/scripts/fleet-watch.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.jq pkgs.coreutils pkgs.bash ]}

          # Secret reconciler used by the controller before rebuilds. It creates
          # missing generated SOPS values and can commit them back to Git.
          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nix-cluster-secret-ensure \
            --add-flags "$out/lib/scripts/secret-ensure.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.sops pkgs.age pkgs.openssl pkgs.jq pkgs.coreutils pkgs.bash ]}

          # Worker-side heartbeat helper. It only records controller reachability;
          # it does not deploy or rebuild anything.
          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nix-cluster-controller-heartbeat \
            --add-flags "$out/lib/scripts/controller-heartbeat.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.iputils pkgs.inetutils pkgs.systemd pkgs.jq pkgs.coreutils pkgs.bash ]}

          # HA reporter: samples local systemd units and publishes health.
          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster-reporter \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.ha reporter" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.coreutils pkgs.bash ]}

          # Controller HA monitor: reads health reports and publishes desired owners.
          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster-monitor \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.ha monitor" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.coreutils pkgs.bash ]}

          # Worker reconciler: starts/stops scheduler-managed units locally.
          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster-reconciler \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.ha reconciler" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.coreutils pkgs.bash ]}

          # Local recovery loop: keeps critical local units alive regardless of HA.
          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster-recovery \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.ha recovery" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.coreutils pkgs.bash ]}

          # Dynamic ingress router: turns scheduler placement into Caddy snippets.
          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster-ingress-router \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.ingress" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.coreutils pkgs.bash ]}

          # Operator CLI: reads scheduler/app state and submits safe move requests.
          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nix-cluster \
            --prefix PYTHONPATH : "$out/lib" \
            --add-flags "-m nix_cluster.cli" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.bash ]}

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
          ln -s nix-cluster-ingress-router $out/bin/nops-ingress-router
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

          # The installer is a Bash state machine plus templates. Environment
          # variables point it at the files copied into the Nix store above.
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
      # `cfg` is the user-facing module config at services.nix-cluster.*.
      cfg = config.services."nix-cluster";
      # Shared home and app storage are split so a fleet can share /home,
      # app data, both, or neither.
      sharedHomes = cfg.identity.sharedHomes;
      sharedStorage = cfg.storage;
      # Runtime services always run as this account. The old nops home is kept
      # below only for upgrade/migration compatibility.
      serviceUser = "nix-cluster";
      serviceGroup = serviceUser;
      serviceHome = "/home/${serviceUser}";
      legacyServiceHome = "/home/nops";
      # environment.etc wants a path relative to /etc, while the Python code
      # wants the full absolute path in its environment.
      runtimeConfigEtcPath = lib.removePrefix "/etc/" cfg.paths.runtimeConfigPath;
      serviceLogFile = "${cfg.paths.logDir}/main.log";
      repoPathString = toString cfg.repoPath;
      # Per-route schema for dynamic ingress. Python later turns these records
      # into Caddy snippets when the scheduler has picked a healthy owner.
      ingressRouteType = lib.types.submodule ({ name, ... }: {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable this dynamic ingress route.";
          };
          domain = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Primary HTTP hostname served by this dynamic ingress route.";
          };
          aliases = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Additional hostnames that should import the same generated route.";
          };
          unit = lib.mkOption {
            type = lib.types.str;
            description = "Scheduler-managed systemd unit whose desired owner receives traffic.";
          };
          scheme = lib.mkOption {
            type = lib.types.enum [ "http" "https" ];
            default = "http";
            description = "Scheme used between Caddy and the selected backend node.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            description = "Backend port on the scheduler-selected owner node.";
          };
          healthPath = lib.mkOption {
            type = lib.types.str;
            default = "/";
            description = "Caddy active health-check path for this backend.";
          };
          auth = lib.mkOption {
            type = lib.types.enum [ "none" "authentik" ];
            default = "none";
            description = "Optional generated ingress auth wrapper.";
          };
          authentikHost = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Authentik outpost upstream host used when auth is authentik.";
          };
          authentikPort = lib.mkOption {
            type = lib.types.port;
            default = 9000;
            description = "Authentik outpost upstream port used when auth is authentik.";
          };
          extraConfig = lib.mkOption {
            type = lib.types.lines;
            default = "";
            description = "Additional Caddy directives appended inside the generated reverse_proxy block.";
          };
        };
      });
      appContractType = lib.types.submodule ({ name, ... }: {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable this reusable app runtime contract.";
          };
          units = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Systemd service units that make up the app.";
          };
          primaryUnit = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Primary systemd unit used for routing and app status.";
          };
          port = lib.mkOption {
            type = lib.types.nullOr lib.types.port;
            default = null;
            description = "Backend port for generated ingress routing.";
          };
          domain = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Hostname for generated ingress routing; null disables route generation.";
          };
          aliases = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Additional hostnames for generated ingress routing.";
          };
          routeName = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Stable generated ingress route name.";
          };
          scheme = lib.mkOption {
            type = lib.types.enum [ "http" "https" ];
            default = "http";
            description = "Scheme used between Caddy and the selected backend node.";
          };
          healthPath = lib.mkOption {
            type = lib.types.str;
            default = "/";
            description = "Caddy active health-check path for the backend.";
          };
          auth = lib.mkOption {
            type = lib.types.enum [ "none" "authentik" ];
            default = "none";
            description = "Generated ingress auth wrapper.";
          };
          authentikHost = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Authentik outpost upstream host used when auth is authentik.";
          };
          authentikPort = lib.mkOption {
            type = lib.types.port;
            default = 9000;
            description = "Authentik outpost upstream port used when auth is authentik.";
          };
          extraConfig = lib.mkOption {
            type = lib.types.lines;
            default = "";
            description = "Additional Caddy directives appended inside the generated reverse_proxy block.";
          };
          sharedState = {
            required = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Require healthy shared state storage before this app can run.";
            };
            root = lib.mkOption {
              type = lib.types.str;
              default = "/srv/nix-cluster/apps/${name}";
              description = "Shared app state root.";
            };
            mounts = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "/srv/nix-cluster" ];
              description = "Mount points that must be healthy for this app.";
            };
          };
          placement = {
            ha = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Let the nix-cluster HA scheduler own this app.";
            };
            preferredNodes = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Preferred scheduler nodes for this app.";
            };
            requireHealthyStateStorage = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Require healthy state storage for scheduler placement.";
            };
          };
        };
      });
      schedulerUnitPolicyType = lib.types.submodule ({ ... }: {
        options = {
          preferredNodes = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
          minimumMemoryAvailableBytes = lib.mkOption { type = lib.types.int; default = 0; };
          maximumLoadPerCpu = lib.mkOption { type = lib.types.float; default = 0.0; };
          estimatedMemoryBytes = lib.mkOption { type = lib.types.int; default = 0; };
          estimatedCpu = lib.mkOption { type = lib.types.float; default = 0.0; };
          automaticRebalance = lib.mkOption { type = lib.types.bool; default = false; };
          rebalanceObservationThreshold = lib.mkOption { type = lib.types.int; default = 3; };
          minimumMemoryAdvantageBytes = lib.mkOption { type = lib.types.int; default = 0; };
          minimumLoadAdvantagePercent = lib.mkOption { type = lib.types.float; default = 30.0; };
          requireHealthyStateStorage = lib.mkOption { type = lib.types.bool; default = true; };
        };
      });
      schedulerWorkloadType = lib.types.submodule ({ name, ... }: {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Include this application workload in scheduler desired state.";
          };
          units = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Systemd service units that make up this application workload.";
          };
          group = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional operator move group name. Defaults to the workload name.";
          };
        };
      });
      schedulerDeniedUnits = [
        "NetworkManager.service"
        "caddy.service"
        "etcd.service"
        "keepalived.service"
        "nix-cluster-runtime-store.service"
        "nix-cluster.service"
        "ssh.service"
        "sshd.service"
      ];
      schedulerWorkloadUnits = lib.unique (lib.concatLists (lib.mapAttrsToList (_: workload:
        lib.optionals workload.enable workload.units
      ) effectiveSchedulerWorkloads));
      schedulerRequestedUnits = lib.unique (cfg.ha.scheduler.managedUnits ++ schedulerWorkloadUnits);
      schedulerManagedUnits = lib.filter (unit: !(lib.elem unit schedulerDeniedUnits)) schedulerRequestedUnits;
      schedulerRejectedUnits = lib.filter (unit: lib.elem unit schedulerDeniedUnits) schedulerRequestedUnits;
      effectiveAppContracts = lib.recursiveUpdate cfg.appContracts cfg.clusterAppContracts;
      enabledAppContracts = lib.filterAttrs (_: contract: contract.enable) effectiveAppContracts;
      contractWorkloads = lib.mapAttrs (_: contract: {
        enable = contract.placement.ha;
        units = contract.units;
        group = contract.routeName;
      }) enabledAppContracts;
      contractRoutes = lib.listToAttrs (lib.filter (entry: entry != null) (lib.mapAttrsToList (_: contract:
        if contract.enable && contract.placement.ha && contract.domain != null && contract.port != null then {
          name = contract.routeName;
          value = {
            enable = true;
            domain = contract.domain;
            aliases = contract.aliases;
            unit = contract.primaryUnit;
            scheme = contract.scheme;
            port = contract.port;
            healthPath = contract.healthPath;
            auth = contract.auth;
            authentikHost = contract.authentikHost;
            authentikPort = contract.authentikPort;
            extraConfig = contract.extraConfig;
          };
        } else null
      ) enabledAppContracts));
      contractUnitPolicies = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (_: contract:
        lib.optionals (contract.enable && contract.placement.ha) (map (unit: {
          name = unit;
          value = {
            preferredNodes = contract.placement.preferredNodes;
            minimumMemoryAvailableBytes = 0;
            maximumLoadPerCpu = 0.0;
            estimatedMemoryBytes = 0;
            estimatedCpu = 0.0;
            automaticRebalance = false;
            rebalanceObservationThreshold = 3;
            minimumMemoryAdvantageBytes = 0;
            minimumLoadAdvantagePercent = 30.0;
            requireHealthyStateStorage = contract.sharedState.required && contract.placement.requireHealthyStateStorage;
          };
        }) contract.units)
      ) enabledAppContracts));
      effectiveSchedulerWorkloads = lib.recursiveUpdate contractWorkloads cfg.ha.scheduler.workloads;
      effectiveUnitPolicies = lib.recursiveUpdate contractUnitPolicies cfg.ha.scheduler.unitPolicies;
      effectiveIngressRoutes = lib.recursiveUpdate contractRoutes cfg.ingressRouter.routes;
      contractTrackedUnits = lib.unique (lib.concatLists (lib.mapAttrsToList (_: contract:
        lib.optionals contract.enable contract.units
      ) enabledAppContracts));
      contractUnitLabels = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (appId: contract:
        lib.optionals contract.enable (map (unit: {
          name = unit;
          value = {
            app_id = appId;
            route_name = contract.routeName;
            primary = unit == contract.primaryUnit;
          };
        }) contract.units)
      ) enabledAppContracts));
      monitoringTargets = lib.mapAttrs (host: address: {
        address = address;
        node_exporter = "${address}:${toString cfg.observability.prometheus.port}";
      }) cfg.ingressRouter.nodeAddresses;
      # Emergency users deliberately live outside shared /home so an NFS/home
      # outage does not lock operators out of recovery.
      recoverySshUserType = lib.types.submodule ({ name, ... }: {
        options = {
          uid = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "Optional fixed numeric UID for the local recovery SSH user.";
          };
          authorizedKeys = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "SSH public keys authorized for this local recovery user.";
          };
          extraGroups = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "wheel" ];
            description = "Extra local groups for this recovery user.";
          };
        };
      });
      # If an older install used /home/nops, copy it forward during activation.
      legacyRepoPath = if lib.hasPrefix "${serviceHome}/" repoPathString then "${legacyServiceHome}/${lib.removePrefix "${serviceHome}/" repoPathString}" else "";
      # Local etcd startup needs a single comma-separated initial-cluster value.
      # If the user does not provide one, this node starts as a one-member store.
      storeCfg = cfg.ha.runtimeStore.localServer;
      storeAdvertisePeerUrl = if storeCfg.initialAdvertisePeerUrls != [] then builtins.elemAt storeCfg.initialAdvertisePeerUrls 0 else "http://${config.networking.hostName}:2380";
      storeInitialCluster = if storeCfg.initialCluster != [] then lib.concatStringsSep "," storeCfg.initialCluster else "${storeCfg.name}=${storeAdvertisePeerUrl}";
      # These booleans decide whether this node exports storage or mounts it.
      isSharedHomeNode = config.networking.hostName == sharedHomes.homeNode;
      sharedHomeClient = sharedHomes.enable && !isSharedHomeNode && !(builtins.elem config.networking.hostName sharedHomes.skipClientNodes);
      sharedStorageClient = sharedStorage.enable && !isSharedHomeNode;
      # The observability list is intentionally assembled here so apps can add
      # their units without the Python reporter hard-coding every app.
      trackedUnits = lib.unique (
        [ "nix-cluster.service" ]
        ++ lib.optionals cfg.localRecovery.enable cfg.localRecovery.criticalUnits
        ++ lib.optionals cfg.ha.runtimeStore.localServer.enable [ "nix-cluster-runtime-store.service" ]
        ++ lib.optionals cfg.observability.prometheus.enable [ "prometheus-node-exporter.service" ]
        ++ lib.optionals (cfg.observability.loki.enable && cfg.observability.loki.url != "") [ "alloy.service" ]
        ++ contractTrackedUnits
        ++ cfg.observability.monitoredServices
        ++ cfg.observability.extraTrackedUnits
      );
      appCfg = cfg.apps;
      # Keep only the fields the Python secret reconciler needs at runtime.
      secretGenerationRequests = lib.mapAttrs (_: request: {
        generator = request.generator;
        length = request.length;
      }) cfg.secretGeneration.requests;
      # Caddy gets placeholder snippets at boot, then ingress.py replaces them
      # once scheduler placement and health records exist.
      enabledIngressRoutes = lib.filterAttrs (_: route: route.enable) effectiveIngressRoutes;
      ingressRouteNames = lib.attrNames enabledIngressRoutes;
      ingressRoutePlaceholderRules = map (routeName:
        "f ${cfg.ingressRouter.outputDir}/${routeName}.caddy 0644 ${serviceUser} ${serviceGroup} - respond\\x20\\\"nix-cluster\\x20route\\x20unavailable:\\x20router\\x20not\\x20ready\\\"\\x20503"
      ) ingressRouteNames;
      # The static NixOS Caddy config imports per-route files. The route body is
      # runtime data, but the virtual host names stay declarative.
      ingressRouteVirtualHosts = lib.listToAttrs (lib.concatMap (routeName:
        let
          route = enabledIngressRoutes.${routeName};
          domains = [ route.domain ] ++ route.aliases;
        in
          map (domain: {
            name = "http://${domain}:80";
            value.extraConfig = ''
              bind 0.0.0.0
              import ${cfg.ingressRouter.outputDir}/${routeName}.caddy
            '';
          }) domains
      ) ingressRouteNames);
      # Controller-driven enrollment serializes worker relationships into the
      # runtime JSON so shell/Python helpers do not need to evaluate Nix live.
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
      # Serializes module options into the JSON file read by every Python daemon.
      # This is the bridge from declarative Nix config into runtime behavior.
    nixClusterConfig = pkgs.writeText "nix-cluster-config.json" (builtins.toJSON {
      # Top-level identity and role of this node.
      is_controller = cfg.isController;
      hostname = config.networking.hostName;
      # AUTOMATIC SANITIZATION: Strip \r from the controller script
      controller_script = builtins.replaceStrings [ "\r" ] [ "" ] cfg.controllerScript;
      # Paths the runtime code uses for Git state, logs, metrics, and scripts.
      directories = {
        repo = cfg.repoPath;
        log = cfg.paths.logDir;
        state = cfg.paths.stateDir;
        metrics = cfg.paths.metricsDir;
        heartbeat = cfg.paths.heartbeatStateDir;
        runtime_config = cfg.paths.runtimeConfigPath;
        controller_script_dir = cfg.paths.controllerScriptDir;
      };
      # Legacy shape kept for older code that looked under `commands.update`.
      commands = {
        # AUTOMATIC SANITIZATION: Strip \r from every command in the update list
        update = builtins.map (cmd: builtins.replaceStrings [ "\r" ] [ "" ] cmd) cfg.afterPush;
      };
      # Current update-manager shape: Git remote/ref, rebuild commands, and path filters.
      update = {
        update = builtins.map (cmd: builtins.replaceStrings [ "\r" ] [ "" ] cmd) cfg.afterPush;
        remote_name = cfg.update.remoteName;
        branch_ref = cfg.update.branchRef;
        relevant_paths = cfg.update.relevantPaths;
        worker_wait_seconds = cfg.update.workerWaitSeconds;
        controller_switch_cooldown_seconds = cfg.update.controllerSwitchCooldownSeconds;
      };
      post_update_refresh = {
        enable = cfg.postUpdateRefresh.enable;
        units = map (unitConfig: {
          unit = unitConfig.unit;
          restart = unitConfig.restart;
          verify_paths = unitConfig.verifyPaths;
          required_paths = unitConfig.requiredPaths;
        }) cfg.postUpdateRefresh.units;
      };
      # Controller timing and worker heartbeat settings.
      controller = {
        reconcile_interval_seconds = cfg.controller.reconcileIntervalSeconds;
        monitor = {
          enable = cfg.controller.monitor.enable;
          interval_seconds = cfg.controller.monitor.intervalSeconds;
          targets = cfg.controller.monitor.targets;
        };
      };
      # Static node role labels consumed by templates, apps, and runtime policy.
      placement = {
        node_role = cfg.placement.nodeRole;
        ha_role = cfg.placement.haRole;
        keepalived_role = cfg.placement.keepalivedRole;
      };
      # Critical local units should be recovered even when HA scheduling is disabled.
      local_recovery = {
        enable = cfg.localRecovery.enable;
        critical_units = cfg.localRecovery.criticalUnits;
        interval_seconds = cfg.localRecovery.intervalSeconds;
        dry_run = cfg.localRecovery.dryRun;
      };
      # Enrollment/provisioning inventory for controller-driven workers.
      workers = workerInventory;
      # App settings are included for installer/runtime helpers that need the
      # deployment knobs without parsing the Nix module directly.
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
          allowed_node_roles = appCfg.keepalived.allowedNodeRoles;
          allowed_ha_roles = appCfg.keepalived.allowedHaRoles;
          fail_when_ineligible = appCfg.keepalived.failWhenIneligible;
        };
        cloudflare = {
          enable = appCfg.cloudflare.enable;
          tunnel = appCfg.cloudflare.tunnel;
          tunnel_name = appCfg.cloudflare.tunnelName;
          tunnel_domain = appCfg.cloudflare.tunnelDomain;
          tunnel_vip = appCfg.cloudflare.vip;
          ingress_origin = appCfg.cloudflare.ingressOrigin;
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
      # Units and integrations that feed local status, Prometheus, and logs.
      observability = {
        tracked_units = trackedUnits;
        unit_labels = contractUnitLabels;
        prometheus = {
          enable = cfg.observability.prometheus.enable;
          port = cfg.observability.prometheus.port;
          targets = monitoringTargets;
        };
        loki = {
          enable = cfg.observability.loki.enable;
          url = cfg.observability.loki.url;
          tracked_units = trackedUnits;
        };
      };
      # App-declared generated secrets that the controller reconciles into SOPS.
      secret_generation = {
        enable = cfg.secretGeneration.enable;
        sops_file = cfg.secretGeneration.sopsFile;
        requests = secretGenerationRequests;
      };
      # HA runtime-store and scheduler settings consumed by ha.py.
      ha = {
        enable = cfg.ha.enable;
        reporting = {
          enable = cfg.ha.reporting.enable;
          mode = cfg.ha.reporting.mode;
          services = cfg.ha.reporting.services;
          include_tracked_units = cfg.ha.reporting.includeTrackedUnits;
          interval_seconds = cfg.ha.reporting.intervalSeconds;
          collection_deadline_seconds = cfg.ha.reporting.collectionDeadlineSeconds;
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
            request_prefix = cfg.ha.scheduler.requestPrefix;
            lease_ttl_seconds = cfg.ha.scheduler.leaseTtlSeconds;
            lease_renewal_seconds = cfg.ha.scheduler.leaseRenewalSeconds;
            default_strategy = cfg.ha.scheduler.defaultStrategy;
          managed_units = schedulerManagedUnits;
          rejected_managed_units = schedulerRejectedUnits;
          workloads = lib.mapAttrs (_: workload: {
            enable = workload.enable;
            units = workload.units;
            group = if workload.group == null then "" else workload.group;
          }) effectiveSchedulerWorkloads;
          app_groups = cfg.ha.scheduler.appGroups;
          reconciler_enable = cfg.ha.scheduler.reconcilerEnable;
          reconciler_interval_seconds = cfg.ha.scheduler.reconcilerIntervalSeconds;
          reconciler_dry_run = cfg.ha.scheduler.reconcilerDryRun;
          resource_prefix = cfg.ha.scheduler.resourcePrefix;
          resource_interval_seconds = cfg.ha.scheduler.resourceIntervalSeconds;
          node_schedulable = cfg.ha.scheduler.nodeSchedulable;
          storage_health = {
            enable = cfg.ha.scheduler.storageHealth.enable;
            command = cfg.ha.scheduler.storageHealth.command;
            required_mounts = cfg.ha.scheduler.storageHealth.requiredMounts;
            probe_path = cfg.ha.scheduler.storageHealth.probePath;
            timeout_seconds = cfg.ha.scheduler.storageHealth.timeoutSeconds;
            healthy_observation_threshold = cfg.ha.scheduler.storageHealth.healthyObservationThreshold;
          };
          ownership_prefix = cfg.ha.scheduler.ownershipPrefix;
          failure_threshold = cfg.ha.scheduler.failureThreshold;
          recovery_threshold = cfg.ha.scheduler.recoveryThreshold;
          minimum_owner_seconds = cfg.ha.scheduler.minimumOwnerSeconds;
          transition_timeout_seconds = cfg.ha.scheduler.transitionTimeoutSeconds;
          target_cooldown_seconds = cfg.ha.scheduler.targetCooldownSeconds;
          ownership_lease_enable = cfg.ha.scheduler.ownershipLeaseEnable;
          unit_policies = lib.mapAttrs (_: policy: {
            preferred_nodes = policy.preferredNodes;
            minimum_memory_available_bytes = policy.minimumMemoryAvailableBytes;
            maximum_load_per_cpu = policy.maximumLoadPerCpu;
            estimated_memory_bytes = policy.estimatedMemoryBytes;
            estimated_cpu = policy.estimatedCpu;
            automatic_rebalance = policy.automaticRebalance;
            rebalance_observation_threshold = policy.rebalanceObservationThreshold;
            minimum_memory_advantage_bytes = policy.minimumMemoryAdvantageBytes;
            minimum_load_advantage_percent = policy.minimumLoadAdvantagePercent;
            require_healthy_state_storage = policy.requireHealthyStateStorage;
          }) effectiveUnitPolicies;
        };
      };
      # Dynamic ingress settings consumed by ingress.py.
      ingress_router = {
        enable = cfg.ingressRouter.enable;
        interval_seconds = cfg.ingressRouter.intervalSeconds;
        stale_after_seconds = cfg.ingressRouter.staleAfterSeconds;
        output_dir = cfg.ingressRouter.outputDir;
        caddy_config_path = cfg.ingressRouter.caddyConfigPath;
        reload_timeout_seconds = cfg.ingressRouter.reloadTimeoutSeconds;
        reload_backoff_seconds = cfg.ingressRouter.reloadBackoffSeconds;
        reload_lock_path = cfg.ingressRouter.reloadLockPath;
        node_addresses = cfg.ingressRouter.nodeAddresses;
        routes = lib.mapAttrs (_: route: {
          enable = route.enable;
          domain = route.domain;
          aliases = route.aliases;
          unit = route.unit;
          scheme = route.scheme;
          port = route.port;
          health_path = route.healthPath;
          auth = route.auth;
          authentik_host = route.authentikHost;
          authentik_port = route.authentikPort;
          extra_config = route.extraConfig;
        }) effectiveIngressRoutes;
      };
      app_contracts = lib.mapAttrs (name: contract: {
        enable = contract.enable;
        units = contract.units;
        primary_unit = contract.primaryUnit;
        port = if contract.port == null then 0 else contract.port;
        domain = if contract.domain == null then "" else contract.domain;
        route_name = contract.routeName;
        shared_state = {
          required = contract.sharedState.required;
          root = contract.sharedState.root;
          mounts = contract.sharedState.mounts;
        };
        placement = {
          ha = contract.placement.ha;
          preferred_nodes = contract.placement.preferredNodes;
          require_healthy_state_storage = contract.placement.requireHealthyStateStorage;
        };
        }) effectiveAppContracts;
      # Deprecated alias of `apps`; kept so older helpers do not break during upgrades.
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
          allowed_node_roles = appCfg.keepalived.allowedNodeRoles;
          allowed_ha_roles = appCfg.keepalived.allowedHaRoles;
          fail_when_ineligible = appCfg.keepalived.failWhenIneligible;
        };
        cloudflare = {
          enable = appCfg.cloudflare.enable;
          tunnel = appCfg.cloudflare.tunnel;
          tunnel_name = appCfg.cloudflare.tunnelName;
          tunnel_domain = appCfg.cloudflare.tunnelDomain;
          tunnel_vip = appCfg.cloudflare.vip;
          ingress_origin = appCfg.cloudflare.ingressOrigin;
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
      # Trigger listener settings.
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
      # Bring in SOPS and keep old option names usable during the nops -> nix-cluster rename.
      imports = [
        sops-nix.nixosModules.sops
        (lib.mkRenamedOptionModule [ "services" "nops" ] [ "services" "nix-cluster" ])
        (lib.mkRenamedOptionModule [ "services" "nix-cluster" "modules" ] [ "services" "nix-cluster" "apps" ])
      ];
      # Public module API. These options are what fleet repos set under
      # services.nix-cluster.*.
      options.services."nix-cluster" = {
        enable = lib.mkEnableOption "nix-cluster - Nix Cluster Controller";
        # Core GitOps/update identity.
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
        serviceAccount.uid = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          description = "Fixed numeric UID for the nix-cluster service account. Required when shared homes are enabled.";
        };
        serviceAccount.gid = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          description = "Fixed numeric GID for the nix-cluster service group. Required when shared homes are enabled.";
        };
        recoverySshUsers = lib.mkOption {
          type = lib.types.attrsOf recoverySshUserType;
          default = {};
          description = "Local emergency SSH users with homes outside shared /home so operators can recover shared-home or NFS failures.";
        };
        # Optional shared /home support. The home node exports, other nodes mount.
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
          localAuthorizedKeysOnly = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "When shared homes are enabled, keep SSH key lookup in local /etc instead of reading authorized_keys from NFS-backed home directories.";
          };
        };
        # Optional shared app storage. This is intended for app data, not
        # multi-writer databases unless the database explicitly supports it.
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
        # Paths written into runtime JSON and used by systemd tmpfiles.
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
        # Git comparison and rebuild behavior for UpdateManager.
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
          controllerSwitchCooldownSeconds = lib.mkOption {
            type = lib.types.int;
            default = 300;
            description = "Minimum seconds between controller-triggered NixOS switches. Prevents queued webhooks or recovery loops from stacking rebuilds on the ingress/controller node.";
          };
        };
        postUpdateRefresh = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Restart and verify local services whose bind-mounted inputs may become stale after nix-cluster replaces the fleet checkout.";
          };
          units = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                unit = lib.mkOption {
                  type = lib.types.str;
                  description = "Systemd unit to refresh after a successful nix-cluster update.";
                };
                restart = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Restart the unit before verification so systemd recreates bind mounts against the current filesystem paths.";
                };
                verifyPaths = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [];
                  description = "Mount paths to inspect inside the unit namespace; any source containing '(deleted)' fails the update.";
                };
                requiredPaths = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [];
                  description = "Paths that must exist inside the unit namespace after refresh.";
                };
              };
            });
            default = [];
            description = "Services that should be refreshed and checked after the fleet checkout changes.";
          };
        };
        afterPush = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "/run/wrappers/bin/sudo /run/current-system/sw/bin/systemd-run --wait --collect --pipe --working-directory=${config.services."nix-cluster".repoPath} --service-type=oneshot --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin -- /run/current-system/sw/bin/nixos-rebuild switch --flake ${config.services."nix-cluster".repoPath}#${config.networking.hostName} --impure"
          ];
          description = "Array of shell commands to execute after a push is received.";
        };
        # Controller reconciliation and worker reachability monitoring.
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
        # Static scheduling roles for this node.
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
        # Small local safety net for units like NetworkManager.
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
        # Dynamic Caddy routing from scheduler placement to healthy backend nodes.
        ingressRouter = {
          enable = lib.mkEnableOption "dynamic Caddy routing from nix-cluster scheduler placement";
          intervalSeconds = lib.mkOption {
            type = lib.types.int;
            default = 5;
            description = "Seconds between ingress route reconciliation passes.";
          };
          staleAfterSeconds = lib.mkOption {
            type = lib.types.int;
            default = cfg.ha.runtimeStore.staleAfterSeconds;
            description = "Maximum age for placement and health records before a route fails closed.";
          };
          outputDir = lib.mkOption {
            type = lib.types.str;
            default = "/run/nix-cluster/ingress/caddy.d";
            description = "Runtime directory where generated Caddy snippets are written.";
          };
          caddyConfigPath = lib.mkOption {
            type = lib.types.str;
            default = "/etc/caddy/caddy_config";
            description = "Caddy config path used when reloading generated routes.";
          };
          reloadTimeoutSeconds = lib.mkOption {
            type = lib.types.int;
            default = 20;
            description = "Hard timeout for each Caddy reload triggered by dynamic route changes.";
          };
          reloadBackoffSeconds = lib.mkOption {
            type = lib.types.int;
            default = 30;
            description = "Minimum delay before retrying Caddy reload after a timeout or reload failure.";
          };
          reloadLockPath = lib.mkOption {
            type = lib.types.str;
            default = "/run/nix-cluster/ingress/caddy.reload.lock";
            description = "Lock file used to serialize dynamic ingress Caddy reloads.";
          };
          nodeAddresses = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = "Backend addresses keyed by node hostname. These are consumed only by the runtime router.";
          };
          routes = lib.mkOption {
            type = lib.types.attrsOf ingressRouteType;
            default = {};
            description = "Dynamic ingress routes keyed by stable route name.";
          };
        };
        # Observability settings shared by local tools, HA reporter, Prometheus, and Loki.
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
        # Secret generation lets apps ask for generated SOPS values without
        # shipping plaintext defaults.
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
        # HA is split into three jobs: reporters publish node state, controllers
        # aggregate/schedule, and workers reconcile local service ownership.
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
            collectionDeadlineSeconds = lib.mkOption {
              type = lib.types.int;
              default = 30;
              description = "Maximum expected duration of one service-health collection pass.";
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
                default = 1073741824;
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
            requestPrefix = lib.mkOption {
              type = lib.types.str;
              default = "/nix-cluster/scheduler/requests";
              description = "Runtime store prefix where operator move requests are submitted for controller-mediated handoff.";
            };
            leaseTtlSeconds = lib.mkOption {
              type = lib.types.int;
              default = 90;
              description = "Lease TTL used for scheduler leadership and exclusive service ownership records.";
            };
            leaseRenewalSeconds = lib.mkOption {
              type = lib.types.int;
              default = 15;
              description = "Maximum interval between ownership lease renewals.";
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
            workloads = lib.mkOption {
              type = lib.types.attrsOf schedulerWorkloadType;
              default = {};
              description = "Explicit application workloads that may be owned by the HA scheduler. Control-plane and host infrastructure units are refused.";
            };
            appGroups = lib.mkOption {
              type = lib.types.attrsOf (lib.types.listOf lib.types.str);
              default = {};
              description = "Named application groups that should be listed and moved together by the nix-cluster operator CLI.";
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
            nodeSchedulable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Administrative node-wide scheduling gate. Set false to quarantine a node while it continues reporting health.";
            };
            storageHealth = {
              enable = lib.mkEnableOption "state-storage eligibility probing";
              command = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
                description = "Argument vector for an optional bounded state-storage health command. A nonzero exit marks storage unhealthy.";
              };
              requiredMounts = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
                description = "Mount points that must be mounted before the node is storage-healthy.";
              };
              probePath = lib.mkOption {
                type = lib.types.str;
                default = "/var/lib/nix-cluster";
                description = "Directory used for the bounded fsync and read-back storage probe.";
              };
              timeoutSeconds = lib.mkOption {
                type = lib.types.int;
                default = 10;
                description = "Timeout for the optional storage health command.";
              };
              healthyObservationThreshold = lib.mkOption {
                type = lib.types.int;
                default = 3;
                description = "Consecutive successful probes required before storage becomes schedulable.";
              };
            };
            ownershipPrefix = lib.mkOption {
              type = lib.types.str;
              default = "/nix-cluster/scheduler/ownership";
              description = "Runtime-store prefix for exclusive per-service ownership leases.";
            };
            failureThreshold = lib.mkOption {
              type = lib.types.int;
              default = 3;
              description = "Consecutive confirmed failure observations required before handoff.";
            };
            recoveryThreshold = lib.mkOption {
              type = lib.types.int;
              default = 2;
              description = "Consecutive healthy observations required before committing a target.";
            };
            minimumOwnerSeconds = lib.mkOption {
              type = lib.types.int;
              default = 300;
              description = "Minimum stable ownership dwell time outside confirmed failure handling.";
            };
            transitionTimeoutSeconds = lib.mkOption {
              type = lib.types.int;
              default = 30;
              description = "Maximum time allowed for activation and verification phases.";
            };
            targetCooldownSeconds = lib.mkOption {
              type = lib.types.int;
              default = 300;
              description = "Cooldown applied to a target after a failed transition.";
            };
            ownershipLeaseEnable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Require an exclusive etcd lease before a managed service may run.";
            };
            unitPolicies = lib.mkOption {
              type = lib.types.attrsOf schedulerUnitPolicyType;
              default = {};
              description = "Per-unit placement preferences, eligibility thresholds, reservations, and rebalance policy.";
            };
          };
        };
        appContracts = lib.mkOption {
          type = lib.types.attrsOf appContractType;
          default = {};
          description = "Compatibility app runtime contracts. Prefer clusterAppContracts for fleet-wide HA routes.";
        };
        clusterAppContracts = lib.mkOption {
          type = lib.types.attrsOf appContractType;
          default = {};
          description = "Fleet-wide app runtime contracts that generate scheduler workloads, ingress routes, and observability tracking on every node.";
        };
        # Built-in app knobs used by templates and fleet module composition.
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
            allowedNodeRoles = lib.mkOption {
              type = lib.types.listOf (lib.types.enum [ "controller" "worker" "service" "backup" "spare" ]);
              default = [ "controller" "worker" "service" "backup" "spare" ];
              description = "Node placement roles that may advertise this VIP. Narrow this for app VIPs so ingress-only controllers cannot capture app traffic.";
            };
            allowedHaRoles = lib.mkOption {
              type = lib.types.listOf (lib.types.enum [ "active" "passive" "spare" ]);
              default = [ "active" "passive" "spare" ];
              description = "HA roles that may advertise this VIP. App VIPs usually restrict this to active-capable workers.";
            };
            failWhenIneligible = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Fail evaluation instead of silently omitting Keepalived when this node's placement role is not allowed to own the VIP.";
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
            ingressOrigin = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Origin address cloudflared should send tunnel traffic to. Leave empty to use the VIP for compatibility; set to a connector-local ingress address when the VIP represents app backends.";
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
        # Worker declarations give the controller enough information to probe
        # live installers and enroll/reinstall machines.
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
        # Matrix and webhook are the two supported update triggers.
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

      # Actual NixOS configuration emitted when services.nix-cluster.enable = true.
      config = lib.mkIf cfg.enable {
        # Fill in role defaults from other high-level choices unless the fleet
        # explicitly overrides them.
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
        # Assertions fail evaluation early for states that would be dangerous or
        # internally inconsistent at runtime.
        warnings = lib.optionals (schedulerRejectedUnits != []) [
          "nix-cluster HA scheduler refused unsafe units: ${lib.concatStringsSep ", " schedulerRejectedUnits}"
        ];
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
            assertion = !sharedHomes.enable || (cfg.serviceAccount.uid != null && cfg.serviceAccount.gid != null);
            message = "Shared homes require fixed services.nix-cluster.serviceAccount.uid and .gid so NFS ownership is stable across nodes.";
          }
          {
            assertion = lib.all (user: user.authorizedKeys != []) (lib.attrValues cfg.recoverySshUsers);
            message = "Every services.nix-cluster.recoverySshUsers entry must declare at least one authorized key.";
          }
          {
            assertion = !sharedStorage.enable || (sharedHomes.enable && sharedStorage.appRoot != "" && lib.hasPrefix "/srv/nix-cluster/" (toString sharedStorage.appRoot));
            message = "Shared application storage requires shared homes and an appRoot below /srv/nix-cluster/.";
          }
          {
            assertion = (!cfg.ha.scheduler.enable) || cfg.ha.scheduler.controllerMode != "elected" || cfg.ha.scheduler.leaseTtlSeconds > cfg.ha.scheduler.intervalSeconds;
            message = "services.nix-cluster.ha.scheduler.leaseTtlSeconds must be greater than intervalSeconds when elected scheduler leadership is enabled.";
          }
          {
            assertion = (!cfg.ha.scheduler.ownershipLeaseEnable) || cfg.ha.scheduler.leaseTtlSeconds >= (3 * cfg.ha.scheduler.leaseRenewalSeconds);
            message = "services.nix-cluster.ha.scheduler.leaseTtlSeconds must be at least three leaseRenewalSeconds when ownership leases are enabled.";
          }
          {
            assertion = (!cfg.ha.reporting.enable) || cfg.ha.runtimeStore.staleAfterSeconds >= ((3 * cfg.ha.reporting.intervalSeconds) + cfg.ha.reporting.collectionDeadlineSeconds);
            message = "services.nix-cluster.ha.runtimeStore.staleAfterSeconds must be at least three reporting intervals plus collectionDeadlineSeconds.";
          }
          {
            assertion = lib.all (contract: (!contract.enable) || contract.units != []) (lib.attrValues effectiveAppContracts);
            message = "Every enabled services.nix-cluster app contract entry must declare at least one unit.";
          }
          {
            assertion = lib.all (contract: (!contract.enable) || contract.primaryUnit == "" || lib.elem contract.primaryUnit contract.units) (lib.attrValues effectiveAppContracts);
            message = "Every services.nix-cluster app contract primaryUnit must be present in units.";
          }
          {
            assertion = lib.all (contract: (!contract.enable) || contract.domain == null || (contract.primaryUnit != "" && contract.port != null)) (lib.attrValues effectiveAppContracts);
            message = "Every routed services.nix-cluster app contract entry must declare primaryUnit and port.";
          }
          {
            assertion =
              (!cfg.apps.keepalived.enable)
              || (!cfg.apps.keepalived.failWhenIneligible)
              || (
                lib.elem cfg.placement.nodeRole cfg.apps.keepalived.allowedNodeRoles
                && lib.elem cfg.placement.haRole cfg.apps.keepalived.allowedHaRoles
              );
            message = "services.nix-cluster.apps.keepalived is enabled on a node whose placement role is not allowed to own this VIP.";
          }
        ];
        # Cluster timestamps are compared across nodes, so time sync is part of
        # the module's base contract.
        services.timesyncd.enable = true;
        # The shared-home node exports /home and app storage over NFS.
        services.nfs.server = lib.mkIf (sharedHomes.enable && isSharedHomeNode) {
          enable = true;
          exports = ''
            / ${sharedHomes.exportNetwork}(rw,sync,no_subtree_check,fsid=0,crossmnt,root_squash)
            ${sharedHomes.mountPath} ${sharedHomes.exportNetwork}(${lib.concatStringsSep "," sharedHomes.exportOptions})
            ${sharedStorage.exportPath} ${sharedHomes.exportNetwork}(rw,sync,no_subtree_check,no_root_squash,fsid=1,crossmnt)
          '';
        };
        # Non-home nodes mount shared /home and/or app storage when enabled.
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
        # App units can depend on this guard so they fail closed if shared
        # storage is missing or mounted from the wrong place.
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
        # Open only the ports for components this node actually runs.
        networking.firewall.allowedTCPPorts =
          lib.optionals cfg.webhook.enable [ cfg.webhook.port ]
          ++ lib.optionals cfg.ha.runtimeStore.localServer.enable [ 2379 2380 ]
          ++ lib.optionals cfg.observability.prometheus.enable [ cfg.observability.prometheus.port ]
          ++ lib.optionals (sharedHomes.enable && isSharedHomeNode) [ 2049 ];
        services.openssh.authorizedKeysFiles = lib.mkIf (sharedHomes.enable && sharedHomes.localAuthorizedKeysOnly) (
          lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ]
        );
        # Main service account plus optional break-glass recovery users.
        users.users = {
          ${serviceUser} = {
            isNormalUser = true;
            description = "nix-cluster Service Daemon Account";
            group = serviceGroup;
            extraGroups = [ "wheel" "docker" ];
            home = serviceHome;
            createHome = true;
            shell = pkgs.bash;
            openssh.authorizedKeys.keys = cfg.serviceAccount.authorizedKeys;
          } // lib.optionalAttrs (cfg.serviceAccount.uid != null) {
            uid = cfg.serviceAccount.uid;
          };
        } // lib.mapAttrs (name: userCfg: {
          isNormalUser = true;
          description = "nix-cluster local recovery SSH user";
          extraGroups = userCfg.extraGroups;
          home = "/var/lib/nix-cluster-recovery/${name}";
          createHome = true;
          shell = pkgs.bash;
          openssh.authorizedKeys.keys = userCfg.authorizedKeys;
        } // lib.optionalAttrs (userCfg.uid != null) {
          uid = userCfg.uid;
        }) cfg.recoverySshUsers;
        users.groups.${serviceGroup} = {} // lib.optionalAttrs (cfg.serviceAccount.gid != null) {
          gid = cfg.serviceAccount.gid;
        };
        # Put the wrapped tools and core diagnostics on the host PATH.
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
        # One-way migration from the old nops account/home to nix-cluster.
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
        # This is the concrete /etc file that config.py loads at runtime.
        environment.etc.${runtimeConfigEtcPath}.source = nixClusterConfig;
        # Create writable runtime directories owned by the service account.
        systemd.tmpfiles.rules = [
          "d ${cfg.paths.logDir} 0755 ${serviceUser} ${serviceGroup} -"
          "d ${cfg.paths.stateDir} 0755 ${serviceUser} ${serviceGroup} -"
          "d ${cfg.paths.stateDir}/ha 0755 ${serviceUser} ${serviceGroup} -"
          "d ${cfg.paths.metricsDir} 0755 ${serviceUser} ${serviceGroup} -"
          "d ${cfg.paths.heartbeatStateDir} 0755 ${serviceUser} ${serviceGroup} -"
          "d ${cfg.paths.controllerScriptDir} 0755 ${serviceUser} ${serviceGroup} -"
        ] ++ lib.optionals (cfg.ingressRouter.enable && cfg.apps.caddy.enable) ([
          "d /run/nix-cluster 0755 ${serviceUser} ${serviceGroup} -"
          "d /run/nix-cluster/ingress 0755 ${serviceUser} ${serviceGroup} -"
          "d ${cfg.ingressRouter.outputDir} 0755 ${serviceUser} ${serviceGroup} -"
        ] ++ ingressRoutePlaceholderRules) ++ lib.optionals cfg.ha.runtimeStore.localServer.enable [
          "d ${cfg.paths.stateDir}/etcd 0700 ${serviceUser} ${serviceGroup} -"
        ] ++ lib.optionals (sharedHomes.enable && isSharedHomeNode) [
          "d ${sharedStorage.exportPath} 0755 root root -"
          "d ${sharedStorage.appRoot} 0755 root root -"
          "f ${sharedHomes.mountPath}/.nix-cluster-shared-root 0644 root root -"
          "f ${sharedStorage.appRoot}/.nix-cluster-shared-root 0644 root root -"
        ];

        # Optional node-exporter textfile collector for nix-cluster metrics.
        services.prometheus.exporters.node = lib.mkIf cfg.observability.prometheus.enable {
          enable = true;
          port = cfg.observability.prometheus.port;
          listenAddress = "0.0.0.0";
          enabledCollectors = [ "systemd" "textfile" ];
          extraFlags = [ "--collector.textfile.directory=${cfg.paths.metricsDir}" ];
        };

        # Optional journal shipping through Grafana Alloy.
        services.alloy = lib.mkIf (cfg.observability.loki.enable && cfg.observability.loki.url != "") {
          enable = true;
          configPath = pkgs.writeText "nix-cluster.alloy" ''
            loki.relabel "journal" {
              rule {
                source_labels = ["__journal__systemd_unit"]
                regex = "${lib.concatStringsSep "|" (map (unit: lib.replaceStrings [ "." ] [ "\\." ] unit) trackedUnits)}"
                action = "keep"
              }
              rule {
                source_labels = ["__journal__systemd_unit"]
                target_label = "unit"
              }
              rule {
                source_labels = ["__journal_priority"]
                target_label = "priority"
              }
            }

            loki.source.journal "systemd" {
              max_age = "24h"
              labels = {
                job = "systemd-journal",
                host = "${config.networking.hostName}",
                cluster_service = "nix-cluster",
              }
              relabel_rules = loki.relabel.journal.rules
              forward_to = [loki.write.default.receiver]
            }

            loki.write "default" {
              endpoint {
                url = "${cfg.observability.loki.url}"
              }
            }
          '';
        };

        systemd.services.alloy = lib.mkIf (cfg.observability.loki.enable && cfg.observability.loki.url != "") {
          serviceConfig.SupplementaryGroups = [ "systemd-journal" ];
        };

        # Caddy owns the virtual hosts; ingress.py owns the imported snippets.
        services.caddy.virtualHosts = lib.mkIf (cfg.ingressRouter.enable && cfg.apps.caddy.enable) ingressRouteVirtualHosts;

        # Optional local etcd. This is the runtime-state store used by HA.
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
            OOMPolicy = "continue";
            OOMScoreAdjust = "-700";
            MemoryHigh = "768M";
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

        # Maintenance keeps etcd from growing until NOSPACE blocks writes.
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

        # Timer for local etcd compaction/defrag/alarm cleanup.
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
          path = [ pkgs.git pkgs.curl pkgs.nixos-rebuild pkgs.inetutils pkgs.systemd pkgs.procps pkgs.bash pkgs.openssl pkgs.sops pkgs.age pkgs.openssh pkgs.jq pkgs.sshpass pkgs.mkpasswd pkgs.util-linux ]
            ++ lib.optionals cfg.isController [ pkgs.terraform ];
          serviceConfig = {
            User = serviceUser;
            Restart = "always";
            RestartSec = "10s";
            TimeoutStopSec = "20s";
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
             pids=()

             cleanup() {
               trap - TERM INT EXIT
               if [ ''${#pids[@]} -gt 0 ]; then
                 kill "''${pids[@]}" 2>/dev/null || true
                 deadline=$((SECONDS + 10))
                 while [ "$SECONDS" -lt "$deadline" ]; do
                   alive=0
                   for pid in "''${pids[@]}"; do
                     if kill -0 "$pid" 2>/dev/null; then
                       alive=1
                       break
                     fi
                   done
                   [ "$alive" -eq 0 ] && break
                   sleep 0.1
                 done
                 for pid in "''${pids[@]}"; do
                   if kill -0 "$pid" 2>/dev/null; then
                     kill -KILL "$pid" 2>/dev/null || true
                   fi
                 done
                 wait "''${pids[@]}" 2>/dev/null || true
               fi
             }

             trap cleanup TERM INT EXIT
             
             if [ "${builtins.toString cfg.matrix.enable}" = "1" ]; then
               export MATRIX_BOT_TOKEN=$(cat $MATRIX_BOT_TOKEN_FILE)
               export MATRIX_ROOM_ID=$(cat $MATRIX_ROOM_ID_FILE)
               export MATRIX_HOMESERVER=$(cat $MATRIX_HOMESERVER_FILE)
               ${self.packages.${system}.default}/bin/nix-cluster-daemon &
               pids+=("$!")
             fi

             if [ "${builtins.toString cfg.webhook.enable}" = "1" ]; then
               ${self.packages.${system}.default}/bin/nix-cluster-webhook &
               pids+=("$!")
             fi

             if [ "${builtins.toString (cfg.ha.enable && cfg.ha.reporting.enable)}" = "1" ]; then
               ${self.packages.${system}.default}/bin/nix-cluster-reporter &
               pids+=("$!")
             fi

             if [ "${builtins.toString (cfg.isController && cfg.ha.enable && cfg.ha.scheduler.enable && cfg.ha.runtimeStore.type == "etcd" && cfg.ha.runtimeStore.endpoint != "")}" = "1" ]; then
               ${self.packages.${system}.default}/bin/nix-cluster-monitor &
               pids+=("$!")
             fi

             if [ "${builtins.toString (cfg.ha.enable && cfg.ha.scheduler.enable && cfg.ha.scheduler.reconcilerEnable && cfg.ha.runtimeStore.type == "etcd" && cfg.ha.runtimeStore.endpoint != "")}" = "1" ]; then
               ${self.packages.${system}.default}/bin/nix-cluster-reconciler &
               pids+=("$!")
             fi

             if [ "${builtins.toString cfg.localRecovery.enable}" = "1" ]; then
               ${self.packages.${system}.default}/bin/nix-cluster-recovery &
               pids+=("$!")
             fi

             if [ "${builtins.toString (cfg.ingressRouter.enable && cfg.ha.runtimeStore.type == "etcd" && cfg.ha.runtimeStore.endpoint != "")}" = "1" ]; then
               ${self.packages.${system}.default}/bin/nix-cluster-ingress-router &
               pids+=("$!")
             fi

             if [ ''${#pids[@]} -eq 0 ]; then
               echo "No nix-cluster components enabled."
               exit 0
             fi

             wait -n "''${pids[@]}"
             status=$?
             cleanup
             exit "$status"
          '';
        };

        # Worker timer job that records whether a controller target is reachable.
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

        # Schedule the worker heartbeat loop through systemd timers instead of
        # keeping another always-running process around.
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
    # Guardrail: shared storage must fail closed, so automount is intentionally
    # not allowed in the default NFS client options.
    checks.${system}.shared-storage-client-options = assert !(builtins.elem "x-systemd.automount" sharedStorageClientOptions); pkgs.runCommand "shared-storage-client-options" {} ''
      touch $out
    '';
  };
}
