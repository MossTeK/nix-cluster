{
  # core metadata
  description = "NAD Core - Nix Automation Daemon Library";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
  };

  # output generation
  outputs = { self, nixpkgs, sops-nix, ... }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    packages.${system} = {
      # main python app
      default = pkgs.python3.pkgs.buildPythonApplication {
        pname = "nad-core";
        version = "1.2.6"; 
        format = "other";
        src = ./.; 
        propagatedBuildInputs = [ 
          pkgs.python3.pkgs.flask 
          pkgs.python3.pkgs.pyyaml 
          pkgs.git 
          pkgs.python3.pkgs.waitress 
        ];
        # move files to out
        installPhase = ''
          mkdir -p $out/bin $out/lib $out/share/nad
          cp -r src/* $out/lib/
          cp -r config $out/share/nad/config
          cp -r src $out/share/nad/src
          makeWrapper ${pkgs.python3}/bin/python3 $out/bin/nad-webhook \
            --add-flags "$out/lib/webhook.py" \
            --prefix PYTHONPATH : "$PYTHONPATH"
        '';
      };

      # installer script
      install = pkgs.stdenv.mkDerivation {
        name = "nad-install";
        src = ./.;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        # wrap setup.sh
        installPhase = ''
          mkdir -p $out/share/nad/src
          cp src/setup.sh $out/share/nad/src/setup.sh
          chmod +x $out/share/nad/src/setup.sh
          cp src/ops.yaml $out/share/nad/src/ops.yaml
          cp -r config $out/share/nad/config
          mkdir -p $out/bin
          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nad-install \
            --add-flags "$out/share/nad/src/setup.sh" \
            --set NAD_CONFIG_DIR "$out/share/nad/config" \
            --set NAD_SRC_DIR "$out/share/nad/src" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.sops pkgs.age pkgs.vim pkgs.nano pkgs.util-linux pkgs.nixos-rebuild ]}
        '';
      };
    };

    # nixos module
    nixosModules.default = { config, lib, pkgs, ... }: {
      imports = [ sops-nix.nixosModules.sops ];
      options.services.nad = {
        enable = lib.mkEnableOption "Nix Auto Deploy";
        repoPath = lib.mkOption {
          type = lib.types.path;
          description = "Path to the private configuration repository";
        };
      };
      # service config
      config = lib.mkIf config.services.nad.enable {
        environment.systemPackages = [ self.packages.${system}.default pkgs.git pkgs.sops ];
        systemd.services.nad-webhook = {
          description = "NAD Webhook Listener";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          path = [ pkgs.git pkgs.nixos-rebuild pkgs.sudo ];
          serviceConfig = {
            User = "nad";
            Restart = "always";
            WorkingDirectory = config.services.nad.repoPath;
          };
          environment = {
            NAD_CONFIG_PATH = "${config.services.nad.repoPath}/src/ops.yaml";
            NAD_LOG_PATH = "${config.services.nad.repoPath}/log/main.log";
            FORGEJO_WEBHOOK_SECRET_FILE = config.sops.secrets.forgejo_webhook_secret.path;
          };
          # launch script
          script = ''
             export PATH=/run/wrappers/bin:$PATH
             export FORGEJO_WEBHOOK_SECRET=$(cat $FORGEJO_WEBHOOK_SECRET_FILE)
             ${self.packages.${system}.default}/bin/nad-webhook
          '';
        };
      };
    };
    # flake apps
    apps.${system}.install = { type = "app"; program = "${self.packages.${system}.install}/bin/nad-install"; };
  };
}