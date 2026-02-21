{ config, lib, pkgs, ... }:

let
  cfg = config.services.penpot;
  inherit (lib) mkEnableOption mkOption mkIf mkMerge types
    optional optionals concatStringsSep literalExpression;

  # Build the flags list, auto-injecting provider flags
  effectiveFlags = cfg.flags
    ++ optional cfg.providers.google.enable "enable-login-with-google"
    ++ optional cfg.providers.github.enable "enable-login-with-github"
    ++ optional cfg.providers.gitlab.enable "enable-login-with-gitlab"
    ++ optional cfg.providers.oidc.enable "enable-login-with-oidc"
    ++ optional cfg.providers.ldap.enable "enable-login-with-ldap";

  flagsString = concatStringsSep " " effectiveFlags;

  # Common backend environment variables (non-secret)
  backendEnv = {
    PENPOT_PUBLIC_URI = cfg.publicURI;
    PENPOT_FLAGS = flagsString;
    PENPOT_TELEMETRY_ENABLED = lib.boolToString cfg.telemetryEnabled;
    PENPOT_DATABASE_URI = "postgresql://${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}";
    PENPOT_DATABASE_USERNAME = cfg.database.user;
    PENPOT_REDIS_URI = "redis://${cfg.redis.host}:${toString cfg.redis.port}/0";
    PENPOT_HTTP_SERVER_HOST = "0.0.0.0";
  } // lib.optionalAttrs (cfg.smtp.host != null) {
    PENPOT_SMTP_HOST = cfg.smtp.host;
    PENPOT_SMTP_PORT = toString cfg.smtp.port;
    PENPOT_SMTP_TLS = lib.boolToString cfg.smtp.tls;
  } // lib.optionalAttrs (cfg.smtp.defaultFrom != null) {
    PENPOT_SMTP_DEFAULT_FROM = cfg.smtp.defaultFrom;
  } // lib.optionalAttrs (cfg.smtp.defaultReplyTo != null) {
    PENPOT_SMTP_DEFAULT_REPLY_TO = cfg.smtp.defaultReplyTo;
  } // lib.optionalAttrs (cfg.smtp.username != null) {
    PENPOT_SMTP_USERNAME = cfg.smtp.username;
  } // lib.optionalAttrs (cfg.storage.backend == "s3") {
    PENPOT_ASSETS_STORAGE_BACKEND = "assets-s3";
    PENPOT_STORAGE_ASSETS_S3_REGION = cfg.storage.s3.region;
    PENPOT_STORAGE_ASSETS_S3_BUCKET = cfg.storage.s3.bucket;
  } // lib.optionalAttrs (cfg.storage.backend == "s3" && cfg.storage.s3.endpoint != null) {
    PENPOT_STORAGE_ASSETS_S3_ENDPOINT = cfg.storage.s3.endpoint;
  } // lib.optionalAttrs (cfg.storage.backend == "fs") {
    PENPOT_ASSETS_STORAGE_BACKEND = "assets-fs";
    PENPOT_STORAGE_ASSETS_FS_DIRECTORY = "/opt/data/assets";
  } // lib.optionalAttrs (cfg.httpServerMaxBodySize != null) {
    PENPOT_HTTP_SERVER_MAX_BODY_SIZE = cfg.httpServerMaxBodySize;
  } // lib.optionalAttrs (cfg.httpServerMaxMultipartBodySize != null) {
    PENPOT_HTTP_SERVER_MAX_MULTIPART_BODY_SIZE = cfg.httpServerMaxMultipartBodySize;
  } // lib.optionalAttrs cfg.providers.google.enable {
    PENPOT_GOOGLE_CLIENT_ID = cfg.providers.google.clientID;
  } // lib.optionalAttrs cfg.providers.github.enable {
    PENPOT_GITHUB_CLIENT_ID = cfg.providers.github.clientID;
  } // lib.optionalAttrs cfg.providers.gitlab.enable {
    PENPOT_GITLAB_BASE_URI = cfg.providers.gitlab.baseURI;
    PENPOT_GITLAB_CLIENT_ID = cfg.providers.gitlab.clientID;
  } // lib.optionalAttrs cfg.providers.oidc.enable ({
    PENPOT_OIDC_CLIENT_ID = cfg.providers.oidc.clientID;
  } // lib.optionalAttrs (cfg.providers.oidc.baseURI != null) {
    PENPOT_OIDC_BASE_URI = cfg.providers.oidc.baseURI;
  } // lib.optionalAttrs (cfg.providers.oidc.authURI != null) {
    PENPOT_OIDC_AUTH_URI = cfg.providers.oidc.authURI;
  } // lib.optionalAttrs (cfg.providers.oidc.tokenURI != null) {
    PENPOT_OIDC_TOKEN_URI = cfg.providers.oidc.tokenURI;
  } // lib.optionalAttrs (cfg.providers.oidc.userURI != null) {
    PENPOT_OIDC_USER_URI = cfg.providers.oidc.userURI;
  }) // lib.optionalAttrs cfg.providers.ldap.enable {
    PENPOT_LDAP_HOST = cfg.providers.ldap.host;
    PENPOT_LDAP_PORT = toString cfg.providers.ldap.port;
    PENPOT_LDAP_SSL = lib.boolToString cfg.providers.ldap.ssl;
    PENPOT_LDAP_STARTTLS = lib.boolToString cfg.providers.ldap.startTLS;
    PENPOT_LDAP_BASE_DN = cfg.providers.ldap.baseDN;
    PENPOT_LDAP_BIND_DN = cfg.providers.ldap.bindDN;
    PENPOT_LDAP_ATTRS_USERNAME = cfg.providers.ldap.attrsUsername;
    PENPOT_LDAP_ATTRS_EMAIL = cfg.providers.ldap.attrsEmail;
    PENPOT_LDAP_ATTRS_FULLNAME = cfg.providers.ldap.attrsFullname;
  };

  # Frontend environment variables
  frontendEnv = {
    PENPOT_FLAGS = flagsString;
    PENPOT_BACKEND_URI = "http://penpot-backend:6060";
    PENPOT_EXPORTER_URI = "http://penpot-exporter:6061";
  };

  # Exporter environment variables
  exporterEnv = {
    PENPOT_PUBLIC_URI = "http://penpot-frontend:8080";
    PENPOT_REDIS_URI = "redis://${cfg.redis.host}:${toString cfg.redis.port}/0";
  };

  # Script to generate env files containing secrets at runtime
  secretsScript = pkgs.writeShellScript "penpot-secrets" ''
    set -euo pipefail
    umask 077
    mkdir -p /run/penpot

    # Backend secrets
    BACKEND_ENV="/run/penpot/backend.env"
    : > "$BACKEND_ENV"

    SECRET_KEY=$(cat "${cfg.secretKeyFile}")
    echo "PENPOT_SECRET_KEY=$SECRET_KEY" >> "$BACKEND_ENV"

    ${lib.optionalString (cfg.database.passwordFile != null) ''
      DB_PASS=$(cat "${cfg.database.passwordFile}")
      echo "PENPOT_DATABASE_PASSWORD=$DB_PASS" >> "$BACKEND_ENV"
    ''}
    ${lib.optionalString (cfg.database.passwordFile == null) ''
      echo "PENPOT_DATABASE_PASSWORD=penpot" >> "$BACKEND_ENV"
    ''}

    ${lib.optionalString (cfg.smtp.passwordFile != null) ''
      SMTP_PASS=$(cat "${cfg.smtp.passwordFile}")
      echo "PENPOT_SMTP_PASSWORD=$SMTP_PASS" >> "$BACKEND_ENV"
    ''}

    ${lib.optionalString (cfg.providers.google.enable && cfg.providers.google.clientSecretFile != null) ''
      GOOGLE_SECRET=$(cat "${cfg.providers.google.clientSecretFile}")
      echo "PENPOT_GOOGLE_CLIENT_SECRET=$GOOGLE_SECRET" >> "$BACKEND_ENV"
    ''}

    ${lib.optionalString (cfg.providers.github.enable && cfg.providers.github.clientSecretFile != null) ''
      GITHUB_SECRET=$(cat "${cfg.providers.github.clientSecretFile}")
      echo "PENPOT_GITHUB_CLIENT_SECRET=$GITHUB_SECRET" >> "$BACKEND_ENV"
    ''}

    ${lib.optionalString (cfg.providers.gitlab.enable && cfg.providers.gitlab.clientSecretFile != null) ''
      GITLAB_SECRET=$(cat "${cfg.providers.gitlab.clientSecretFile}")
      echo "PENPOT_GITLAB_CLIENT_SECRET=$GITLAB_SECRET" >> "$BACKEND_ENV"
    ''}

    ${lib.optionalString (cfg.providers.oidc.enable && cfg.providers.oidc.clientSecretFile != null) ''
      OIDC_SECRET=$(cat "${cfg.providers.oidc.clientSecretFile}")
      echo "PENPOT_OIDC_CLIENT_SECRET=$OIDC_SECRET" >> "$BACKEND_ENV"
    ''}

    ${lib.optionalString (cfg.providers.ldap.enable && cfg.providers.ldap.bindPasswordFile != null) ''
      LDAP_PASS=$(cat "${cfg.providers.ldap.bindPasswordFile}")
      echo "PENPOT_LDAP_BIND_PASSWORD=$LDAP_PASS" >> "$BACKEND_ENV"
    ''}

    ${lib.optionalString (cfg.storage.backend == "s3" && cfg.storage.s3.accessKeyIDFile != null) ''
      S3_KEY=$(cat "${cfg.storage.s3.accessKeyIDFile}")
      echo "AWS_ACCESS_KEY_ID=$S3_KEY" >> "$BACKEND_ENV"
    ''}

    ${lib.optionalString (cfg.storage.backend == "s3" && cfg.storage.s3.secretAccessKeyFile != null) ''
      S3_SECRET=$(cat "${cfg.storage.s3.secretAccessKeyFile}")
      echo "AWS_SECRET_ACCESS_KEY=$S3_SECRET" >> "$BACKEND_ENV"
    ''}

    # Exporter secrets (currently just needs the public URI, no secrets - file exists for consistency)
    EXPORTER_ENV="/run/penpot/exporter.env"
    : > "$EXPORTER_ENV"

    # PostgreSQL secrets
    POSTGRES_ENV="/run/penpot/postgres.env"
    : > "$POSTGRES_ENV"
    ${lib.optionalString (cfg.database.passwordFile != null) ''
      echo "POSTGRES_PASSWORD=$DB_PASS" >> "$POSTGRES_ENV"
    ''}
    ${lib.optionalString (cfg.database.passwordFile == null) ''
      echo "POSTGRES_PASSWORD=penpot" >> "$POSTGRES_ENV"
    ''}
  '';

  containerBackend = config.virtualisation.oci-containers.backend;

  # Full path to the container runtime binary
  containerCommand =
    if containerBackend == "podman"
    then "${config.virtualisation.podman.package}/bin/podman"
    else "${config.virtualisation.docker.package}/bin/docker";
in
{
  options.services.penpot = {
    enable = mkEnableOption "Penpot design tool";

    version = mkOption {
      type = types.str;
      default = "2.6.1";
      description = "Version (Docker image tag) of Penpot to deploy.";
    };

    publicURI = mkOption {
      type = types.str;
      example = "https://penpot.example.com";
      description = "The public URI where Penpot will be accessible. Used for links, OIDC callbacks, etc.";
    };

    port = mkOption {
      type = types.port;
      default = 9001;
      description = "Host port to expose the Penpot frontend on.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to bind the frontend port on the host.";
    };

    secretKeyFile = mkOption {
      type = types.path;
      description = ''
        Path to a file containing the secret key used for signing tokens.
        This file is read at service start time and its contents are never placed in the Nix store.
      '';
    };

    flags = mkOption {
      type = types.listOf types.str;
      default = [ "disable-registration" ];
      example = [ "enable-registration" "disable-email-verification" ];
      description = ''
        List of Penpot feature flags. Provider flags (enable-login-with-*)
        are automatically added when the corresponding provider is enabled.
      '';
    };

    telemetryEnabled = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enable Penpot anonymous telemetry.";
    };

    database = {
      host = mkOption {
        type = types.str;
        default = "penpot-postgres";
        description = "PostgreSQL host. Defaults to the managed container name.";
      };

      port = mkOption {
        type = types.port;
        default = 5432;
        description = "PostgreSQL port.";
      };

      name = mkOption {
        type = types.str;
        default = "penpot";
        description = "PostgreSQL database name.";
      };

      user = mkOption {
        type = types.str;
        default = "penpot";
        description = "PostgreSQL user.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a file containing the PostgreSQL password.
          If null, defaults to "penpot" (matching the upstream default).
        '';
      };
    };

    enablePostgresql = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to manage a PostgreSQL container. Disable to use an external database.";
    };

    enableValkey = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to manage a Valkey container. Disable to use an external Redis-compatible server.";
    };

    redis = {
      host = mkOption {
        type = types.str;
        default = "penpot-redis";
        description = "Redis/Valkey host. Defaults to the managed container name.";
      };

      port = mkOption {
        type = types.port;
        default = 6379;
        description = "Redis/Valkey port.";
      };
    };

    smtp = {
      host = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "SMTP server host.";
      };

      port = mkOption {
        type = types.port;
        default = 587;
        description = "SMTP server port.";
      };

      username = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "SMTP username.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to a file containing the SMTP password.";
      };

      tls = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to use TLS for SMTP.";
      };

      defaultFrom = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "Penpot <no-reply@example.com>";
        description = "Default From header for outgoing emails.";
      };

      defaultReplyTo = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "Penpot <no-reply@example.com>";
        description = "Default Reply-To header for outgoing emails.";
      };
    };

    providers = {
      google = {
        enable = mkEnableOption "Google OAuth login";
        clientID = mkOption {
          type = types.str;
          default = "";
          description = "Google OAuth client ID.";
        };
        clientSecretFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to a file containing the Google OAuth client secret.";
        };
      };

      github = {
        enable = mkEnableOption "GitHub OAuth login";
        clientID = mkOption {
          type = types.str;
          default = "";
          description = "GitHub OAuth client ID.";
        };
        clientSecretFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to a file containing the GitHub OAuth client secret.";
        };
      };

      gitlab = {
        enable = mkEnableOption "GitLab OAuth login";
        baseURI = mkOption {
          type = types.str;
          default = "https://gitlab.com";
          description = "GitLab instance base URI.";
        };
        clientID = mkOption {
          type = types.str;
          default = "";
          description = "GitLab OAuth client ID.";
        };
        clientSecretFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to a file containing the GitLab OAuth client secret.";
        };
      };

      oidc = {
        enable = mkEnableOption "OpenID Connect login";
        baseURI = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "OIDC provider base URI (for auto-discovery).";
        };
        clientID = mkOption {
          type = types.str;
          default = "";
          description = "OIDC client ID.";
        };
        clientSecretFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to a file containing the OIDC client secret.";
        };
        authURI = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "OIDC authorization endpoint URI.";
        };
        tokenURI = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "OIDC token endpoint URI.";
        };
        userURI = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "OIDC userinfo endpoint URI.";
        };
      };

      ldap = {
        enable = mkEnableOption "LDAP login";
        host = mkOption {
          type = types.str;
          default = "localhost";
          description = "LDAP server host.";
        };
        port = mkOption {
          type = types.port;
          default = 10389;
          description = "LDAP server port.";
        };
        ssl = mkOption {
          type = types.bool;
          default = false;
          description = "Whether to use SSL for LDAP.";
        };
        startTLS = mkOption {
          type = types.bool;
          default = false;
          description = "Whether to use STARTTLS for LDAP.";
        };
        baseDN = mkOption {
          type = types.str;
          default = "ou=people,dc=planetexpress,dc=com";
          description = "LDAP base DN for user search.";
        };
        bindDN = mkOption {
          type = types.str;
          default = "cn=admin,dc=planetexpress,dc=com";
          description = "LDAP bind DN.";
        };
        bindPasswordFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to a file containing the LDAP bind password.";
        };
        attrsUsername = mkOption {
          type = types.str;
          default = "uid";
          description = "LDAP attribute for username.";
        };
        attrsEmail = mkOption {
          type = types.str;
          default = "mail";
          description = "LDAP attribute for email.";
        };
        attrsFullname = mkOption {
          type = types.str;
          default = "cn";
          description = "LDAP attribute for full name.";
        };
      };
    };

    storage = {
      backend = mkOption {
        type = types.enum [ "fs" "s3" ];
        default = "fs";
        description = "Storage backend for assets. 'fs' uses a local volume, 's3' uses S3-compatible storage.";
      };

      s3 = {
        region = mkOption {
          type = types.str;
          default = "us-east-1";
          description = "S3 region.";
        };

        bucket = mkOption {
          type = types.str;
          default = "";
          description = "S3 bucket name.";
        };

        endpoint = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "S3-compatible endpoint URL (for MinIO, etc.).";
        };

        accessKeyIDFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to a file containing the S3 access key ID.";
        };

        secretAccessKeyFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to a file containing the S3 secret access key.";
        };
      };
    };

    httpServerMaxBodySize = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "104857600";
      description = "Maximum HTTP body size in bytes for the backend.";
    };

    httpServerMaxMultipartBodySize = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "314572800";
      description = "Maximum multipart HTTP body size in bytes for the backend.";
    };
  };

  config = mkIf cfg.enable {

    # Ensure podman (or docker) is available
    virtualisation.oci-containers.backend = lib.mkDefault "podman";

    # Create persistent data directories
    systemd.tmpfiles.rules = [
      "d /var/lib/penpot 0755 root root -"
      "d /var/lib/penpot/assets 0755 root root -"
      "d /var/lib/penpot/postgres 0750 root root -"
    ];

    # OCI containers
    virtualisation.oci-containers.containers = {
      penpot-frontend = {
        image = "penpotapp/frontend:${cfg.version}";
        ports = [ "${cfg.listenAddress}:${toString cfg.port}:8080" ];
        environment = frontendEnv;
        volumes = [
          "/var/lib/penpot/assets:/opt/data/assets:rw"
        ];
        extraOptions = [ "--network=penpot" "--name=penpot-frontend" ];
        dependsOn = [ "penpot-backend" "penpot-exporter" ];
      };

      penpot-backend = {
        image = "penpotapp/backend:${cfg.version}";
        environment = backendEnv;
        environmentFiles = [ "/run/penpot/backend.env" ];
        volumes = [
          "/var/lib/penpot/assets:/opt/data/assets:rw"
        ];
        extraOptions = [ "--network=penpot" "--name=penpot-backend" ];
        dependsOn =
          optional cfg.enablePostgresql "penpot-postgres"
          ++ optional cfg.enableValkey "penpot-redis";
      };

      penpot-exporter = {
        image = "penpotapp/exporter:${cfg.version}";
        environment = exporterEnv;
        environmentFiles = [ "/run/penpot/exporter.env" ];
        extraOptions = [ "--network=penpot" "--name=penpot-exporter" ];
      };
    } // lib.optionalAttrs cfg.enablePostgresql {
      penpot-postgres = {
        image = "postgres:15";
        environment = {
          POSTGRES_INITDB_ARGS = "--data-checksums";
          POSTGRES_DB = cfg.database.name;
          POSTGRES_USER = cfg.database.user;
        };
        environmentFiles = [ "/run/penpot/postgres.env" ];
        volumes = [
          "/var/lib/penpot/postgres:/var/lib/postgresql/data:rw"
        ];
        extraOptions = [ "--network=penpot" "--name=penpot-postgres" ];
      };
    } // lib.optionalAttrs cfg.enableValkey {
      penpot-redis = {
        image = "valkey/valkey:8.1";
        extraOptions = [
          "--network=penpot"
          "--name=penpot-redis"
        ];
        cmd = [ "valkey-server" "--maxmemory" "128mb" "--maxmemory-policy" "volatile-lfu" ];
      };
    };

    # Network creation, secrets, and container dependency overrides
    systemd.services = let
      networkServiceName = "${containerBackend}-network-penpot";
      mkContainerOverride = name: {
        "${containerBackend}-${name}" = {
          requires = [ "${networkServiceName}.service" "penpot-secrets.service" ];
          after = [ "${networkServiceName}.service" "penpot-secrets.service" ];
        };
      };
      containerNames = [ "penpot-frontend" "penpot-backend" "penpot-exporter" ]
        ++ optional cfg.enablePostgresql "penpot-postgres"
        ++ optional cfg.enableValkey "penpot-redis";
    in lib.mkMerge ([
      {
        ${networkServiceName} = {
          description = "Create Penpot container network";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.bash}/bin/bash -c '${containerCommand} network exists penpot || ${containerCommand} network create penpot'";
          };
        };

        penpot-secrets = {
          description = "Generate Penpot secrets environment files";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${secretsScript}";
          };
        };
      }
    ] ++ (map mkContainerOverride containerNames));
  };
}
