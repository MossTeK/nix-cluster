# Provides a small PXE helper stack for the controller: HTTP boot script hosting,
# optional dnsmasq DHCP/TFTP, and TFTP assets from the iPXE package.
{ config, pkgs, lib, ... }:

let
  pxeCfg = config.services."nix-cluster".modules.pxe;
  bootScript = if pxeCfg.bootUrl != "" then ''
    #!ipxe
    echo nix-cluster PXE bootstrap
    dhcp
    chain ${pxeCfg.bootUrl} || shell
  '' else ''
    #!ipxe
    echo nix-cluster PXE bootstrap
    dhcp
    shell
  '';
in
lib.mkIf (pxeCfg.enable && config.services."nix-cluster".isController) {
  services."nix-cluster".observability.monitoredServices = lib.mkAfter (
    [ "caddy.service" ] ++ lib.optionals pxeCfg.dhcpEnable [ "dnsmasq.service" ]
  );

  environment.etc."pxe/tftp".source = "${pkgs.ipxe}/share/ipxe";
  environment.etc."pxe/http/boot.ipxe".text = bootScript;

  services.caddy.enable = lib.mkDefault true;

  services.caddy.virtualHosts."http://:${toString pxeCfg.httpPort}" = {
    extraConfig = ''
      root * /etc/pxe/http
      file_server
    '';
  };

  networking.firewall.allowedTCPPorts = [ pxeCfg.httpPort ];
  networking.firewall.allowedUDPPorts = [ 69 ] ++ lib.optionals pxeCfg.dhcpEnable [ 67 68 ];

} // lib.optionalAttrs pxeCfg.dhcpEnable {
  services.dnsmasq.enable = true;
  services.dnsmasq.extraConfig = ''
    interface=${pxeCfg.interface}
    bind-interfaces
    log-dhcp
    enable-tftp
    tftp-root=/etc/pxe/tftp
    port=0
    dhcp-match=set:efi64,option:client-arch,7
    dhcp-boot=tag:efi64,ipxe.efi
    dhcp-boot=undionly.kpxe
  '';
}