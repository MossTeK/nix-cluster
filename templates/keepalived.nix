# Assigns a VRRP-managed ingress VIP so the active node can answer tunnel traffic on the configured address.
{ config, pkgs, lib, ... }:

let
  keepalivedCfg = config.services."nix-cluster".modules.keepalived;
in
lib.mkIf (keepalivedCfg.enable && keepalivedCfg.interface != "" && keepalivedCfg.vipCidr != "") {
  services.keepalived = {
    enable = true;
    vrrpInstances."ingress_vip" = {
      interface = keepalivedCfg.interface;
      state = if keepalivedCfg.priority >= 150 then "MASTER" else "BACKUP";
      priority = keepalivedCfg.priority;
      virtualRouterId = keepalivedCfg.virtualRouterId;
      virtualIps = [
        { addr = keepalivedCfg.vipCidr; }
      ];
    };
  };

  networking.firewall.extraCommands = ''
    ${pkgs.iptables}/bin/iptables -D INPUT -p vrrp -j ACCEPT 2>/dev/null || true
    ${pkgs.iptables}/bin/iptables -A INPUT -p vrrp -j ACCEPT
  '';
}