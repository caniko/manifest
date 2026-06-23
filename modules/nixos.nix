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

  # Static env — no secrets. The BETTER_AUTH_SECRET env file is
  # generated at runtime by a systemd oneshot that reads the agenix
  # decrypt and writes it as a podman-compatible env file.
  staticEnvFile = pkgs.writeText "manifest-static.env" (
    lib.concatStringsSep "\n" [
      "PORT=${toString manifestPort}"
      "DATABASE_URL=postgresql://manifest:manifest@127.0.0.1:${toString postgresPort}/manifest"
      "NODE_ENV=production"
      "MANIFEST_MODE=selfhosted"
      "SEED_DATA=false"
      "BIND_ADDRESS=0.0.0.0"
      "OLLAMA_HOST=http://127.0.0.1:11434"
    ]
  );

  postgresEnvFile = pkgs.writeText "postgres.env" ''
    POSTGRES_USER=manifest
    POSTGRES_PASSWORD=manifest
    POSTGRES_DB=manifest
  '';

  runtimeEnvDir = "/run/manifest-env";
  runtimeEnvFile = "${runtimeEnvDir}/manifest-dynamic.env";
in {
  options.services.manifest = {
    enable = mkEnableOption "Manifest AI model router";

    betterAuthSecretFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to a file containing the BETTER_AUTH_SECRET value. Required on first boot.";
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
        message = "services.manifest.betterAuthSecretFile must be set to a file containing BETTER_AUTH_SECRET.";
      }
    ];

    virtualisation.oci-containers.containers = {
      manifest-postgres = {
        image = "postgres:16-alpine";
        ports = ["127.0.0.1:${toString postgresPort}:${toString postgresPort}"];
        environmentFiles = [postgresEnvFile];
        volumes = ["manifest-pgdata:/var/lib/postgresql/data"];
        cmd = ["-p" "${toString postgresPort}"];
        log-driver = "journald";
      };

      manifest = {
        image = "manifestdotbuild/manifest:${cfg.imageTag}";
        ports = ["127.0.0.1:${toString manifestPort}:${toString manifestPort}"];
        environmentFiles = [staticEnvFile runtimeEnvFile];
        dependsOn = {
          manifest-postgres = {
            condition = "service_healthy";
          };
        };
        extraOptions = ["--add-host=host.docker.internal:host-gateway"];
        log-driver = "journald";
        cmd = ["packages/backend/dist/main.js"];
      };
    };

    # Oneshot that reads the agenix-decrypted BETTER_AUTH_SECRET and
    # writes it as an env file for the OCI container.
    systemd.services.manifest-secret-env = {
      description = "Render Manifest runtime env file (BETTER_AUTH_SECRET)";
      before = ["manifest.service" "manifest-postgres.service"];
      wantedBy = ["manifest.service" "manifest-postgres.service"];
      path = [pkgs.coreutils];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "manifest-env";
        RuntimeDirectoryMode = "0700";
      };

      script = ''
        set -eu
        umask 077
        val="$(tr -d '\n' < ${cfg.betterAuthSecretFile})"
        tmp="${runtimeEnvFile}.tmp"
        printf 'BETTER_AUTH_SECRET=%s\n' "$val" > "$tmp"
        chmod 0400 "$tmp"
        mv "$tmp" "${runtimeEnvFile}"
      '';
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
      after = ["network-online.target" "manifest-postgres.service" "manifest-secret-env.service"];
      wants = ["network-online.target"];
      requires = ["manifest-secret-env.service"];
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
