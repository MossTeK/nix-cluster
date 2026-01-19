{ config, pkgs, ... }:

{
  imports = [
    # EG ./nix/service_name/service_name.nix /docker/container_name/container_name.nix
  ];
}