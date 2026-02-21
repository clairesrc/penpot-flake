{ self, testers ? null, pkgs, lib ? pkgs.lib, ... }:

let
  nixos-lib = import (pkgs.path + "/nixos/lib") { };
in
nixos-lib.runTest {
  name = "penpot-basic";
  hostPkgs = pkgs;

  nodes.machine = { config, pkgs, ... }: {
    imports = [ self.nixosModules.penpot ];

    # Provide a dummy secret key file for testing
    environment.etc."penpot-secret-key" = {
      text = "test-secret-key-for-nixos-vm-test";
      mode = "0600";
    };

    services.penpot = {
      enable = true;
      publicURI = "http://localhost:9001";
      secretKeyFile = "/etc/penpot-secret-key";
    };

    # Use podman
    virtualisation.oci-containers.backend = "podman";

    # Provide enough resources for the VM
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # Verify network creation service exists and succeeds
    machine.succeed("systemctl is-active podman-network-penpot.service")

    # Verify secrets service exists and succeeds
    machine.succeed("systemctl is-active penpot-secrets.service")

    # Verify secrets env files are created with correct permissions
    machine.succeed("test -f /run/penpot/backend.env")
    machine.succeed("test -f /run/penpot/exporter.env")
    machine.succeed("test -f /run/penpot/postgres.env")

    # Check file permissions (should be 600 due to umask 077)
    perms = machine.succeed("stat -c '%a' /run/penpot/backend.env").strip()
    assert perms == "600", f"backend.env permissions are {perms}, expected 600"

    perms = machine.succeed("stat -c '%a' /run/penpot/postgres.env").strip()
    assert perms == "600", f"postgres.env permissions are {perms}, expected 600"

    # Verify data directories exist
    machine.succeed("test -d /var/lib/penpot/assets")
    machine.succeed("test -d /var/lib/penpot/postgres")

    # Verify backend env file contains expected variables
    backend_env = machine.succeed("cat /run/penpot/backend.env")
    assert "PENPOT_SECRET_KEY=test-secret-key-for-nixos-vm-test" in backend_env, \
        "backend.env missing PENPOT_SECRET_KEY"
    assert "PENPOT_DATABASE_PASSWORD=penpot" in backend_env, \
        "backend.env missing PENPOT_DATABASE_PASSWORD"

    # Verify postgres env file contains expected variables
    postgres_env = machine.succeed("cat /run/penpot/postgres.env")
    assert "POSTGRES_PASSWORD=penpot" in postgres_env, \
        "postgres.env missing POSTGRES_PASSWORD"

    # Verify that container service units are defined
    # (they will fail to start since there are no container images in the sandbox,
    # but the units should exist)
    machine.succeed("systemctl cat podman-penpot-frontend.service")
    machine.succeed("systemctl cat podman-penpot-backend.service")
    machine.succeed("systemctl cat podman-penpot-exporter.service")
    machine.succeed("systemctl cat podman-penpot-postgres.service")
    machine.succeed("systemctl cat podman-penpot-redis.service")

    # Verify container services have correct dependencies on network and secrets
    frontend_unit = machine.succeed("systemctl show podman-penpot-frontend.service -p Requires,After")
    assert "podman-network-penpot.service" in frontend_unit, \
        "frontend missing dependency on network service"
    assert "penpot-secrets.service" in frontend_unit, \
        "frontend missing dependency on secrets service"
  '';
}
