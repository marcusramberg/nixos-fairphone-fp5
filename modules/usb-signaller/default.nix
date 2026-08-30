# USB gadget management for Fairphone 5, via usb-signaller.
#
# The FP5's USB-C port is a device port as far as Linux is concerned: to be
# anything other than a charger it needs a configfs gadget composed and bound
# to the UDC (a600000.usb). usb-signaller does that composition itself and
# switches between modes at runtime, exposing usb-moded's
# `com.meego.usb_moded` D-Bus interface so a shell or `dbus-send` can ask for
# a mode change:
#
#   busctl call com.meego.usb_moded /com/meego/usb_moded com.meego.usb_moded \
#     set_mode s developer_mode
#
# A mode is two halves: the gadget, which the daemon builds, and the userspace
# that makes it useful -- an IP address and a DHCP server for the NCM ethernet
# modes. The daemon delegates that second half to per-mode services it starts
# and stops by name (`usb-signaller-developer-mode`,
# `usb-signaller-tethering-mode`, `usb-signaller-mtp-mode`). Upstream ships
# pmOS-tailored ones; the units below are the NixOS equivalents, driving
# NetworkManager rather than `unudhcpd`.
#
# Note that developer mode is what puts ssh on 172.16.42.1 over USB, which is
# how the device is usually reached when WiFi is not up.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.fairphone5.usb-signaller;

  settingsFormat = pkgs.formats.toml { };
  configFile = settingsFormat.generate "usb-signaller.toml" cfg.settings;

  # The gadget's configfs directory, from which the scripts read the interface
  # name the kernel picked for the NCM function -- it is not always `usb0`.
  configfsGadget = name: "/sys/kernel/config/usb_gadget/${name}";

  mkNcmModeScript =
    {
      name,
      gadget,
      fallbackConnection,
      ipv4Args,
    }:
    pkgs.writeShellScript name ''
      set -u
      PATH=${
        lib.makeBinPath [
          pkgs.networkmanager
          pkgs.iproute2
          pkgs.coreutils
        ]
      }:$PATH

      gadget=${lib.escapeShellArg (configfsGadget gadget)}

      iface=$(cat "$gadget"/functions/ncm.*/ifname 2>/dev/null || true)
      iface=''${iface:-usb0}

      connection=$(cat "$gadget"/configs/*/strings/0x409/configuration 2>/dev/null || true)
      connection=''${connection:-${lib.escapeShellArg fallbackConnection}}

      case "''${1-}" in
        up)
          # Drop any leftover from a previous cable, which would otherwise
          # collide on the connection name.
          nmcli connection delete "$connection" >/dev/null 2>&1 || true

          nmcli connection add con-name "$connection" type ethernet \
            ifname "$iface" ${ipv4Args} save no
          nmcli connection up "$connection"
          ;;
        down)
          nmcli connection down "$connection" >/dev/null 2>&1 || true
          nmcli connection delete "$connection" >/dev/null 2>&1 || true

          # NetworkManager brings the interface up on its own but does not put
          # it back down, and the gadget is about to be torn out from under it.
          ip link set "$iface" down 2>/dev/null || true
          ;;
        *)
          echo "usage: $0 (up|down)" >&2
          exit 1
          ;;
      esac
    '';

  developerModeScript = mkNcmModeScript {
    name = "usb-signaller-developer-mode";
    gadget = "usb-signaller-developer";
    fallbackConnection = "Developer Mode";
    # A static address on the device end plus NetworkManager's shared mode,
    # which runs the DHCP server that hands the host the other end. Upstream
    # uses `ipv4.method manual` and a separate `unudhcpd`; NetworkManager can
    # do both, so there is no second daemon here.
    ipv4Args = "ipv4.method shared ipv4.addresses ${cfg.developerMode.address}/${toString cfg.developerMode.prefixLength}";
  };

  tetheringModeScript = mkNcmModeScript {
    name = "usb-signaller-tethering-mode";
    gadget = "usb-signaller-tethering";
    fallbackConnection = "Tethering Mode";
    ipv4Args = "ipv4.method shared";
  };

  # A mode's userspace half. Oneshot with RemainAfterExit, because the daemon
  # starts it when it binds the gadget and stops it before it unbinds; the
  # stop is what runs `down`.
  mkModeUnit = description: script: {
    inherit description;

    # Deliberately not `wantedBy` anything: these are started by
    # usb-signaller when the corresponding mode is entered, not at boot.
    after = [ "network.target" ];
    wants = [ "network.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${script} up";
      ExecStop = "${script} down";
    };
  };
in
{
  options.hardware.fairphone5.usb-signaller = {
    enable = lib.mkEnableOption ''
      usb-signaller, which composes and switches the USB gadget: NCM ethernet
      for developer and tethering modes, mass storage, MTP and charging-only,
      switchable at runtime over usb-moded's `com.meego.usb_moded` D-Bus
      interface
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.usb-signaller;
      defaultText = lib.literalExpression "pkgs.usb-signaller";
      description = "The usb-signaller package to use.";
    };

    settings = lib.mkOption {
      inherit (settingsFormat) type;
      default = { };
      example = lib.literalExpression ''
        {
          main.default_mode = "charging_only";
          mass_storage.storage_path = "/var/lib/usb-signaller/storage.img";
        }
      '';
      description = ''
        Contents of `/etc/usb-signaller/usb-signaller.toml`, which the daemon
        reads through the UAPI configuration file search path.

        `main.default_mode` is the mode applied when a cable appears and is
        set from {option}`defaultMode`; anything else set here is merged on
        top. `mass_storage.storage_path` points at the image served in
        `mass_storage_mode` and `cdrom_mode`, and has no default -- those two
        modes do nothing without it.

        The daemon refuses to start if it finds no configuration file at all,
        so this file is always written when the module is enabled.
      '';
    };

    defaultMode = lib.mkOption {
      type = lib.types.enum [
        "charging_only"
        "developer_mode"
        "tethering_mode"
        "mtp_mode"
        "mass_storage_mode"
        "cdrom_mode"
        "accessory"
      ];
      default = "developer_mode";
      description = ''
        The mode entered when a USB cable is plugged in.

        `developer_mode` is the default because it is what puts the device on
        172.16.42.1 over USB, reachable by ssh without any network. It shares
        no internet connection; `tethering_mode` is the one that does.
      '';
    };

    developerMode = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Install the service usb-signaller starts for `developer_mode`, which
          addresses the NCM interface and serves DHCP to the host through
          NetworkManager.

          Without it the gadget still binds and the host still sees an
          ethernet device, but neither end has an address.
        '';
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = "172.16.42.1";
        description = ''
          Address given to the device's end of the USB ethernet link. The host
          gets an address on the same subnet by DHCP.

          The default matches what postmarketOS and usb-moded use, so tooling
          that hardcodes it keeps working.
        '';
      };

      prefixLength = lib.mkOption {
        type = lib.types.int;
        default = 16;
        description = "Prefix length of the USB ethernet subnet.";
      };
    };

    tetheringMode.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install the service usb-signaller starts for `tethering_mode`, which
        shares the device's internet connection over the USB ethernet link:
        NetworkManager assigns the subnet, serves DHCP, and NATs out through
        whatever route the device has (WiFi or the modem).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          (cfg.developerMode.enable || cfg.tetheringMode.enable) -> config.networking.networkmanager.enable;
        message = ''
          hardware.fairphone5.usb-signaller: the developer and tethering mode
          services configure the USB ethernet interface through NetworkManager,
          so networking.networkmanager.enable must be on. Turn off
          hardware.fairphone5.usb-signaller.developerMode.enable and
          .tetheringMode.enable to use the gadget without them.
        '';
      }
    ];

    # The daemon builds the gadget in configfs, which needs the function
    # drivers loaded before it can compose anything.
    boot.kernelModules = [
      "libcomposite"
      "usb_f_ncm"
    ];

    hardware.fairphone5.usb-signaller.settings.main.default_mode = lib.mkDefault cfg.defaultMode;

    # The UAPI search looks for the main file at <root>/<project>/<name>, so
    # this is /etc/usb-signaller/usb-signaller.toml and not
    # /etc/usb-signaller.toml -- the latter is never read and the daemon
    # reports "No configuration file found". Drop-ins, if any, go in
    # /etc/usb-signaller/usb-signaller.toml.d/ or /etc/usb-signaller.d/.
    environment.etc."usb-signaller/usb-signaller.toml".source = configFile;

    environment.systemPackages = [ cfg.package ];

    # The system bus policy allowing the daemon to own `com.meego.usb_moded`,
    # and users to ask it for a mode change.
    services.dbus.packages = [ cfg.package ];

    systemd.services = {
      usb-signaller = {
        description = "USB gadget signaller";
        wantedBy = [ "multi-user.target" ];

        # configfs is where the gadget is built, and libcomposite is what makes
        # the usb_gadget directory exist inside it.
        after = [
          "sys-kernel-config.mount"
          "dbus.service"
        ];
        requires = [ "sys-kernel-config.mount" ];

        serviceConfig = {
          ExecStart = lib.getExe cfg.package;
          Restart = "always";
          RestartSec = "1";

          # Writes configfs, binds the UDC, and starts the per-mode units.
          User = "root";
        };
      };

      usb-signaller-developer-mode = lib.mkIf cfg.developerMode.enable (
        mkModeUnit "USB developer mode (NCM ethernet, ${cfg.developerMode.address})" developerModeScript
      );

      usb-signaller-tethering-mode = lib.mkIf cfg.tetheringMode.enable (
        mkModeUnit "USB tethering mode (NCM ethernet, shared connection)" tetheringModeScript
      );
    };
  };
}
