{
  lib,
  pkgs,
  ...
}:
let
  gsettingsSchemas = pkgs.gsettings-desktop-schemas;
  schemaDir = pkgs.glib.makeSchemaPath gsettingsSchemas gsettingsSchemas.name;
in
{
  # Import hardware-specific configuration for Fairphone 5 and DMS Mobile.
  imports = [
    ../../modules/bootmac
    ../../modules/hardware
    ../../modules/modem
    ../../modules/phrog
    ../../modules/qbootctl
  ];

  hardware.fairphone5.enable = true;

  networking.hostName = "fairphone";

  # Enable Qualcomm modem support.
  hardware.fairphone5.modem.enable = true;

  # Enable experimental Nix features (flakes).
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Disable documentation (hides desktop icon).
  documentation.nixos.enable = false;

  # DankMaterialShell as the shell, running on niri.
  programs.dms-shell = {
    enable = true;
    systemd.target = "niri.service";
  };
  systemd.user.services.dms.environment.DMS_MOBILE = "1";

  programs.niri = {
    enable = true;
    settings.outputs."DSI-1".scale = 3;
  };

  # Automatic screen rotation via the accelerometer.

  # Touch-friendly greeter.
  services.displayManager = {
    phrog.enable = true;
    defaultSession = "niri";
  };

  services = {
    # Accessibility bus, needed for the on-screen keyboard flow.
    gnome.at-spi2-core.enable = true;
    upower.enable = true;
    iio-niri.enable = true;
    logind.settings.Login.HandlePowerKey = "ignore";
  };

  environment.sessionVariables = {
    GSETTINGS_SCHEMA_DIR = schemaDir;
    NIXOS_OZONE_WL = "1";
  };
  # Bind Qt to zwp_text_input_v3 so wvkbd --auto sees text fields.
  environment.variables.QT_IM_MODULE = "wayland";

  # On-screen keyboard.
  systemd.user.services.wvkbd = {
    description = "On-screen keyboard";
    partOf = [ "graphical-session.target" ];
    wantedBy = [ "niri.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.wvkbd}/bin/wvkbd-mobintl --alpha 220 --hidden --auto";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Don't let the power button power off instantly; DMS handles it.

  # Create admin user with default password for testing.
  users = {
    mutableUsers = true;

    users.admin = {
      isNormalUser = true;
      # Default password: "admin" (insecure, for testing only).
      # Users should change this with `passwd` after first login.
      initialPassword = "admin";
      extraGroups = [
        "networkmanager" # Network configuration.
        "video" # Video device access.
        "wheel" # Sudo.
      ];
    };
  };

  system.stateVersion = "25.05";
}
