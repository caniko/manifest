manifestFlake: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.services.manifest;

  manifestPort = 3001;
  postgresPort = 5432;

  # Generate the .env file for the Manifest container
  envFile = pkgs.writeText "manifest.env" (
    lib.concatStringsSep "\n" (
      builtins.filter (s: s != "") [
        "PORT=${toString manifestPort}"
        "DATABASE_URL=postgresql://manifest:manifest@127.0.0.1:${toString postgresPort}/manifest"
        "NODE_ENV=production"
        "MANIFEST_MODE=selfhosted"
        "SEED_DATA=false"
        "BIND_ADDRESS=0.0.0.0"
        "OLLAMA_HOST=http://127.0.0.1:11434"
        # Allow brainrouter to reach Manifest without auth when running locally
        "MANIFEST_API_KEY_UNSECURE_ACCESS=false"
      ]
      ++ lib.optional (cfg.betterAuthSecretFile != null) "BETTER_AUTH_SECRET_FILE=${cfg.betterAuthSecretFile}"
      ++ lib.optional (cfg.encryptionKeyFile != null) "MANIFEST_ENCRYPTION_KEY_FILE=${cfg.encryptionKeyFile}"
    )
  );

  # Environment file for PostgreSQL
  postgresEnvFile = pkgs.writeText "postgres.env" ''
    POSTGRES_USER=manifest
    POSTGRES_PASSWORD=manifest
    POSTGRES_DB=manifest
  '';
in {
  options.services.manifest = {
    enable = mkEnableOption "Manifest AI model router";

    betterAuthSecretFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to a file containing the BETTER_AUTH_SECRET. Generated on first install via openssl rand -hex 32.";
    };

    encryptionKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to a file containing the MANIFEST_ENCRYPTION_KEY. Falls back to BETTER_AUTH_SECRET if unset.";
    };

    imageTag = mkOption {
      type = types.str;
      default = "latest";
      description = "Manifest Docker image tag to use.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the firewall for the Manifest HTTP port.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.betterAuthSecretFile != null;
        message = "services.manifest.betterAuthSecretFile must be set.";
      }
    ];

    virtualisation.oci-containers.containers = {
      manifest-postgres = {
        image = "postgres:16-alpine";
        ports = ["127.0.0.1:${toString postgresPort}:${toString postgresPort}"];
        environmentFile = [postgresEnvFile];
        volumes = ["manifest-pgdata:/var/lib/postgresql/data"];
        cmd = ["-p" "${toString postgresPort}"];
        log-driver = "journald";
      };

      manifest = {
        image = "manifestdotbuild/manifest:${cfg.imageTag}";
        ports = ["127.0.0.1:${toString manifestPort}:${toString manifestPort}"];
        environmentFile = [envFile];
        dependsOn = {
          manifest-postgres = {
            condition = "service_healthy";
          };
        };
        extraHosts = ["host.docker.internal:host-gateway"];
        log-driver = "journald";
        cmd = ["packages/backend/dist/main.js"];
      };
    };

    systemd.services.manifest-postgres = {
      description = "Manifest PostgreSQL database";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      requiredBy = ["manifest.service"];
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.services.manifest = {
      description = "Manifest AI model router";
      after = ["network-online.target" "manifest-postgres.service"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = 10;
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [manifestPort];
    };
  };
}
