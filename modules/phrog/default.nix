# phrog, a touch-friendly greeter for greetd built on Phosh.
#
# Upstream ships a `phrog-greetd-session` wrapper that starts
# `phoc -E 'gnome-session --session=phrog'`. That route does not survive the
# move to NixOS, for three reasons, all of which this module works around:
#
#   1. gnome-session on NixOS runs its systemd path: it starts
#      `gnome-session@phrog.target`, which needs phrog's user units and the
#      `gnome-session@phrog.target.d` drop-in installed into the *greeter's*
#      systemd --user manager. greetd's greeter is a system user, so those
#      units are not where gnome-session looks, and the session never reaches
#      `gnome-session-initialized.target` -- the greeter sits on a blank/
#      loading screen forever.
#   2. The wrapper points GNOME_SESSION_AUTOSTART_DIR at /usr/share/phrog and
#      /etc/phrog, which do not exist here, so the non-systemd fallback cannot
#      resolve `phrog.session`'s RequiredComponents either.
#   3. phrog enumerates sessions from XDG_DATA_DIRS (falling back to
#      /usr/local/share:/usr/share). A systemd system service inherits neither
#      NixOS' session variables nor a useful XDG_DATA_DIRS, so the greeter
#      comes up with an empty session list and cannot log anyone in.
#
# So this module skips gnome-session entirely and runs phrog directly under
# phoc, starting the on-screen keyboard alongside it on the same session bus.
# What is lost with gnome-session is gsd-power and gsd-media-keys in the
# greeter -- phoc handles the display itself, so that is a fair trade for a
# greeter that actually starts.
#
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.displayManager.phrog;

  phocConfig = pkgs.writeText "phoc.ini" cfg.phocConfig;

  # Runs inside phoc, on the bus dbus-run-session created. phosh drives the
  # OSK over `sm.puri.OSK0` on that same bus, so squeekboard has to be started
  # here rather than as a separate service.
  greeterShell = pkgs.writeShellScript "phrog-shell" ''
    ${lib.optionalString cfg.osk.enable ''
      ${lib.getExe' cfg.osk.package "squeekboard"} &
    ''}
    exec ${lib.getExe cfg.package}
  '';

  greetdSession = pkgs.writeShellScript "phrog-greetd-session" ''
    # gnome-session is out of the picture, but phosh's own desktop files (and
    # squeekboard's) carry OnlyShowIn=Phosh, so the desktop name still matters.
    export XDG_CURRENT_DESKTOP=Phrog:Phosh:GNOME

    # phrog globs $XDG_DATA_DIRS/{wayland-sessions,xsessions} for the sessions
    # it offers. greetd.service is a system unit and inherits nothing useful.
    export XDG_DATA_DIRS=${config.services.displayManager.sessionData.desktops}/share:/run/current-system/sw/share

    # greetd swallows its greeter's stdio; keep the logs.
    exec > >(${config.systemd.package}/bin/systemd-cat --identifier=phrog) 2>&1

    # phoc needs a session bus to initialise at all.
    exec ${pkgs.dbus}/bin/dbus-run-session -- \
      ${lib.getExe cfg.phocPackage} -S -C ${phocConfig} -E ${greeterShell}
  '';
in
{
  options.services.displayManager.phrog = {
    enable = lib.mkEnableOption ''
      phrog, a touch-friendly greetd greeter built on Phosh. Configures greetd
      to run it under phoc, replacing the display manager
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.phrog;
      defaultText = lib.literalExpression "pkgs.phrog";
      description = "The phrog package to use.";
    };

    phocPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.phoc;
      defaultText = lib.literalExpression "pkgs.phoc";
      description = "The phoc compositor the greeter runs under.";
    };

    osk = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Start an on-screen keyboard next to the greeter. Without it there is
          no way to type a password on a device with no hardware keyboard.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.squeekboard;
        defaultText = lib.literalExpression "pkgs.squeekboard";
        description = "Package providing the `squeekboard` OSK binary.";
      };
    };

    phocConfig = lib.mkOption {
      type = lib.types.lines;
      default = ''
        [core]
        xwayland=false

        [output:DSI-1]
        scale = 3
      '';
      description = ''
        Contents of the `phoc.ini` the greeter's compositor is started with.
        The default sets suitable scale for a phone and assumes output is DSI-1
      '';
    };

    home = lib.mkOption {
      type = lib.types.path;
      default = "/run/phrog";
      description = ''
        Home directory for greetd's `greeter` user. phrog persists its
        `last-user` and `last-session` settings through dconf, which needs a
        writable home; the default `greeter` account has none.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.greetd = {
      enable = true;
      settings.default_session.command = "${greetdSession}";
    };

    # phrog's user list comes from org.freedesktop.Accounts; it never leaves
    # its loading state if the daemon is not on the system bus.
    services.accounts-daemon.enable = true;

    users.users.greeter.home = cfg.home;

    systemd.tmpfiles.rules = [
      "d ${cfg.home} 0700 greeter greeter -"
    ];

    environment.systemPackages = [
      cfg.package
      cfg.phocPackage
    ]
    ++ lib.optional cfg.osk.enable cfg.osk.package;
  };
}
