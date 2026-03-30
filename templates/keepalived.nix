# Assigns a VRRP-managed ingress VIP so the active node can answer tunnel traffic on the configured address.
{ config, pkgs, ... }:

{
  services.keepalived = {
    enable = true;
    vrrpInstances."ingress_vip" = {
      interface = "KEEPALIVED_INTERFACE_PLACEHOLDER";
      state = "KEEPALIVED_STATE_PLACEHOLDER";
      priority = KEEPALIVED_PRIORITY_PLACEHOLDER;
      virtualRouterId = KEEPALIVED_ROUTER_ID_PLACEHOLDER;
      virtualIps = [
        { addr = "KEEPALIVED_VIP_CIDR_PLACEHOLDER"; }
      ];
    };
  };

  networking.firewall.extraCommands = ''
    ${pkgs.iptables}/bin/iptables -D INPUT -p vrrp -j ACCEPT 2>/dev/null || true
    ${pkgs.iptables}/bin/iptables -A INPUT -p vrrp -j ACCEPT
  '';
}