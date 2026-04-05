# Adds a simple scheduled PostgreSQL backup job for the Forgejo database.
{ config, pkgs, lib, ... }:

lib.mkIf (config.services."nix-cluster".modules.postgresBackup.enable && (config.services.forgejo.enable or false)) {
  services."nix-cluster".observability.monitoredServices = lib.mkAfter [
    "postgresqlBackup.timer"
  ];

  services.postgresqlBackup = {
    enable = true;
    backupAll = false;
    databases = [ "forgejo" ];
    location = "/var/lib/postgresql/backups";
    startAt = "03:15";
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/postgresql/backups 0750 postgres postgres -"
  ];
}