# Provides a small PXE helper stack for the controller: HTTP boot script hosting,
# optional dnsmasq DHCP/TFTP, and TFTP assets from the iPXE package.
{ config, pkgs, lib, ... }:

{
  environment.etc."pxe/tftp".source = "${pkgs.ipxe}/share/ipxe";
  environment.etc."pxe/http/boot.ipxe".text = ''
    #!ipxe
    echo nops PXE bootstrap
    dhcp
    chain PXE_BOOT_URL_PLACEHOLDER || shell
  '';

  services.caddy.virtualHosts."http://:${toString PXE_HTTP_PORT_PLACEHOLDER}" = {
    extraConfig = ''
      root * /etc/pxe/http
      file_server
    '';
  };

  networking.firewall.allowedTCPPorts = [ PXE_HTTP_PORT_PLACEHOLDER ];
  networking.firewall.allowedUDPPorts = [ 69 ] ++ lib.optionals PXE_DHCP_ENABLE_PLACEHOLDER [ 67 68 ];

} // lib.optionalAttrs PXE_DHCP_ENABLE_PLACEHOLDER {
  services.dnsmasq.enable = true;
  services.dnsmasq.extraConfig = ''
    interface=PXE_INTERFACE_PLACEHOLDER
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