# Runs the Cloudflare tunnel daemon via Docker using a SOPS-decrypted token provisioned by the controller.
{ config, pkgs, lib, ... }:

lib.mkIf config.services."nix-cluster".modules.cloudflare.enable {
  sops.secrets.cloudflare_tunnel_token = {};

  virtualisation.docker.enable = true;

  systemd.services.cloudflared = {
    description = "Cloudflare Tunnel (Docker)";

    wants = [ "network-online.target" ];
    after = [ "network-online.target" "docker.service" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];

    preStart = ''
      ${pkgs.docker}/bin/docker pull cloudflare/cloudflared:latest
      ${pkgs.docker}/bin/docker rm -f cloudflared-tunnel || true
    '';

    script = ''
      if [ ! -s ${config.sops.secrets.cloudflare_tunnel_token.path} ]; then
        echo "Cloudflare tunnel token not provisioned yet. Skipping startup."
        exit 0
      fi

      TOKEN_VALUE=$(cat ${config.sops.secrets.cloudflare_tunnel_token.path})
      exec ${pkgs.docker}/bin/docker run --rm --network host --name cloudflared-tunnel \
        cloudflare/cloudflared:latest tunnel --no-autoupdate run --token "$TOKEN_VALUE"
    '';

    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "10s";
      TimeoutStartSec = "5min";
    };
  };
}
