# Fingerprint sensor support for Fairphone 5.
#
# The FP5 carries a FocalTech sensor in the power button. It reports device id
# 0x9395 and is driven by the application's `ft93xx` chip module -- not the
# `ft9362` one the device tree node's name suggests. The sensor is not driven
# from Linux at all: it hangs off spi14 (QUP wrapper 1 SE 6, gpio56-59), and
# that bus belongs to the secure world. Imaging, templating and matching happen
# inside a signed TrustZone application ("focal32") that owns the bus, and the
# normal world's only job is to load that application, send it commands, and
# drive the GPIOs it does not own.
#
# What this module provides is the reach: the QSEECOM TEE driver (see
# packages/kernel, patch `tee-qseecom-driver`) exposing the application through
# /dev/tee*, the trusted application image in the firmware search path,
# `ftharness` to drive the sequence, and the application's configuration.
#
# Configuration is not optional. `ff_device_probe` walks its registered chips in
# order -- 0x9601, 0x9391, 0x9362 -- and `ft9601_probe_id` distinguishes a failed
# *read* from a wrong id: on this part its register 0x9e8a read fails, and that
# return value makes the probe abandon the whole candidate list before `ft93xx`
# is ever asked. `device.preferred_device_id` skips straight to the right module.
# Without it every probe returns -11 and the bus looks dead. The key is a
# *string*; an integer is rejected with "expect 'JSON_STRING' but got
# 'JSON_INTEGER'".
#
# The sensor's interrupt works, but only once finger detection is armed:
# START_SCANNING leaves the chip imaging without watching for a finger, and
# CONFIG_DEVICE_WORK_MODE(FDT_DOWN_DETECT) is what arms it -- see initSequence
# below. With that done, gpio34 goes high on finger-down and low on release,
# and the `focaltech-fp` driver reports both through poll()/read() on
# /dev/focaltech_fp once userspace arms the line with FF_IOC_ENABLE_IRQ. The
# driver requests the interrupt with IRQF_NO_AUTOEN, so nothing arrives until
# something opens the device: watching /proc/interrupts alone shows nothing no
# matter how hard the sensor is pressed.
#
# It is still not a fingerprint stack: nothing here enrols or matches. Enrolment
# additionally needs the application's secure storage, which it reaches over
# RPMB through a supplicant -- see packages/ffsupplicant.
#
# The trusted application is proprietary and ships in no public firmware set:
# FairBlobs/FP5-firmware carries adsp, cdsp, modem, wpss and the GPU zap
# shader, but no trusted applications. packages/focal32-firmware fetches a copy
# extracted from a device's stock firmware; the module stays off by default
# because that image is unfree and device-derived.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixos-fairphone-fp5.fingerprint;

  configFile = pkgs.writeText "ff_config.json" (builtins.toJSON cfg.settings);

  # The order the application's own handlers imply, and the one confirmed to
  # reach a live sensor. SYNC_CONFIG has to come first: ff_spi_init reads
  # driver.spi_bus_num out of the config tree when it opens the bus, so a
  # config that arrives later cannot be what it read.
  initSequence = lib.concatStringsSep "," [
    "0x100d@${configFile}" # sync_config
    "0x1006" # init_spi      -> qsee_spi_open(driver.spi_bus_num)
    "0x1008:2000000" # set_spi_speed
    "0x100a:1" # probe_device  -> binds a chip module
    "0x100b" # init_device
    "0x1004" # trustlet_init
    "0x1012" # start_scanning
    # config_device_work_mode(FDT_DOWN_DETECT). Scanning alone leaves the chip
    # imaging but not watching for a finger: gpio34 never moves and no event is
    # ever raised. This is the step that arms detection, and the application
    # acknowledges it with "switch to 'FDT_DOWN_DETECT' mode." (0 is SLEEP,
    # 2 is FDT_UP_DETECT).
    "0x101f:1"
  ];

  fp5-fp-init = pkgs.writeShellScriptBin "fp5-fp-init" ''
    # Bring the trusted application up to the point where the sensor is
    # calibrated, scanning, and armed for finger detection. Appends any
    # arguments to the sequence, so
    #   fp5-fp-init 0x1013
    # captures a frame on top of that.
    set -eu
    seq=${lib.escapeShellArg initSequence}
    if [ "$#" -gt 0 ]; then
      seq="$seq,$1"
      shift
    fi
    exec ${lib.getExe pkgs.ftharness} cmd --reset --rsp 0x40000 --seq "$seq" "$@"
  '';

  # The QSEECOM TEE driver loads an application with request_firmware(), asking
  # for <name>.mdt first and then each .bNN segment, and assembles them itself.
  # So these stay in split form, unlike everything in packages/firmware, which
  # pil-squasher merges into single .mbn files for drivers that want one.
  firmware =
    if cfg.firmwarePath != null then
      pkgs.runCommandLocal "focal32-firmware-local" { } ''
        install -Dm644 -t $out/lib/firmware \
          ${cfg.firmwarePath}/${cfg.appName}.mdt ${cfg.firmwarePath}/${cfg.appName}.b*
      ''
    else
      cfg.firmwarePackage;
in
{
  options.nixos-fairphone-fp5.fingerprint = {
    enable = lib.mkEnableOption ''
      reach to the Fairphone 5 fingerprint trusted application over the QSEECOM
      TEE driver. This loads the kernel driver and installs `ftharness`; it does
      not give you working fingerprint authentication, which additionally needs
      a supplicant serving the application's secure storage over RPMB
    '';

    appName = lib.mkOption {
      type = lib.types.str;
      default = "focal32";
      description = ''
        Name of the trusted application. QSEE matches a session on this string,
        and the driver derives the firmware file names from it.
      '';
    };

    firmwarePackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.focal32-firmware;
      defaultText = lib.literalExpression "pkgs.focal32-firmware";
      description = ''
        Package providing the trusted application under `lib/firmware`, in
        split form (`focal32.mdt` plus `focal32.b00` ... `focal32.b07`).

        The default fetches the image extracted from a Fairphone 5's stock
        firmware. It ships in no public firmware set: FairBlobs/FP5-firmware
        carries the DSP, modem and GPU images, but no trusted applications.
      '';
    };

    firmwarePath = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/etc/nixos/firmware/focal32";
      description = ''
        Directory holding the trusted application image, overriding
        {option}`firmwarePackage` -- for a locally extracted copy rather than
        the published one. `focal32.mdt` plus its `focal32.b00` ...
        `focal32.b07` segments, unsquashed.

        Under flakes this has to be inside the flake's source; a path
        elsewhere on the machine cannot be read during evaluation.

        The contents are copied into the Nix store, which is world-readable.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = {
        driver.spi_bus_num = 14;
        device.spi_default_bps = 2000000;
        device.preferred_device_id = "0x9391";
      };
      defaultText = lib.literalExpression ''
        {
          driver.spi_bus_num = 14;
          device.spi_default_bps = 2000000;
          device.preferred_device_id = "0x9391";
        }
      '';
      example = lib.literalExpression ''
        {
          driver.spi_bus_num = 14;
          device.preferred_device_id = "0x9391";
          diagnosis.enable_logcat_spi_data = true;
          diagnosis.enable_algorithm_log = true;
        }
      '';
      description = ''
        The trusted application's configuration, sent as JSON with SYNC_CONFIG
        (`0x100d`) before anything else. Written to `/etc/focaltech/ff_config.json`
        and used by {command}`fp5-fp-init`.

        Lookup is nested but dotted, so `{ driver.spi_bus_num = 14; }` answers
        the application's query for `driver.spi_bus_num`. It logs every key it
        consults and every one it misses, so one SYNC_CONFIG call dumps the whole
        configuration surface -- around sixty keys across `driver.*`, `device.*`,
        `chips.*`, `algorithm.*`, `diagnosis.*`, `extension.*`, `trustlet.*` and
        `notification.*`.

        The defaults are the minimum that reaches a working sensor:

        - `driver.spi_bus_num` -- the secure world's SPI instance. Defaults to 0
          inside the application, which does not open; only 12 and 14 do, and 14
          is the sensor's.
        - `device.preferred_device_id` -- which chip module to bind, as a string.
          Without it the probe never gets past `ft9601` and always returns -11.

        Everything else falls back to the application's built-in defaults. The
        vendor's own file, worth pulling from a stock device for its tuned
        algorithm thresholds, lives at `/data/vendor/focaltech/ff_config.json`.
      '';
    };

    supplicant = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run {command}`ffsupplicant`, which serves the listener services the
          trusted application uses to reach its secure storage.

          The application blocks until the normal world answers a storage
          request, so without this nothing can be enrolled: reads and writes
          fail and it reports an I/O error. The supplicant is not trusted with
          anything -- objects are encrypted and, for RPMB, authenticated by the
          secure world before they cross this boundary.
        '';
      };

      listeners = lib.mkOption {
        type = lib.types.listOf lib.types.int;
        default = [
          8192
          28672
        ];
        defaultText = lib.literalExpression "[ 8192 28672 ]";
        description = ''
          Listener services to offer, by id.

          8192 (0x2000) is RPMB, where the fingerprint application's storage
          actually goes. 28672 (0x7000) is "gpfile system services", which the
          secure world probes on the way there and which must be answered for
          the application to get as far as its storage.

          These have to be served by one process: the kernel hands requests to
          whichever context receives first, so a second supplicant would be
          refused. TrustZone also caps how many listeners exist at once, so
          offer only what is needed.
        '';
      };

      verbose = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Log every request and reply, including a hex dump of the shared
          buffer. Useful when decoding a listener protocol, noisy otherwise.
        '';
      };
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "tee";
      description = ''
        Group granted access to the TEE client device (`/dev/tee*`). Membership
        means being able to send arbitrary commands to any loaded trusted
        application, since the driver cannot validate what a command means.

        The privileged device (`/dev/teepriv0`), which loads applications and
        registers listeners, stays root-only: the driver requires
        CAP_SYS_ADMIN on it regardless of what this is set to.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Built as a module by packages/kernel (CONFIG_TEE_QSEECOM=m). Nothing
    # autoloads it: it binds to the QSEECOM platform device that qcom_scm
    # registers, and only on a machine in the SCM allowlist (see the
    # `qcom-scm-qseecom-fp5-allowlist` kernel patch).
    boot.kernelModules = [ "qseecomtee" ];

    hardware.firmware = [ firmware ];

    users.groups.${cfg.group} = { };

    # The client device is created 0600 root:root. Anything that talks to a
    # trusted application needs it; loading still needs root.
    services.udev.extraRules = ''
      SUBSYSTEM=="tee", KERNEL=="tee[0-9]*", GROUP="${cfg.group}", MODE="0660"
    '';

    environment.etc."focaltech/ff_config.json".source = configFile;

    environment.systemPackages = [
      pkgs.ftharness
      pkgs.ffsupplicant
      fp5-fp-init
    ];

    # Serves the listeners the trusted application needs to reach its secure
    # storage. Without this the application cannot read or write a template, so
    # nothing can be enrolled and there is nothing to match against; the
    # storage calls simply fail and the application reports an I/O error.
    #
    # This is the same arrangement as rmtfs and tqftpserv in modules/modem --
    # a normal-world daemon doing I/O for a peer that cannot do its own -- but
    # the peer here is TrustZone, reached by SMC through /dev/teepriv0, not a
    # remote processor over QRTR.
    systemd.services.ffsupplicant = lib.mkIf cfg.supplicant.enable {
      description = "QSEECOM listener supplicant (fingerprint secure storage)";
      wantedBy = [ "multi-user.target" ];

      # The listeners are registered through the QSEECOM TEE device, which only
      # exists once that driver has bound.
      after = [ "systemd-udev-settle.service" ];

      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.ffsupplicant} ${
          lib.concatMapStringsSep " " (id: "--listener ${toString id}")
            cfg.supplicant.listeners
        }${lib.optionalString cfg.supplicant.verbose " -v"}";
        Restart = "always";
        RestartSec = "1";

        # /dev/teepriv0 requires CAP_SYS_ADMIN, and the RPMB LUN is root-only.
        User = "root";
      };
    };
  };
}
