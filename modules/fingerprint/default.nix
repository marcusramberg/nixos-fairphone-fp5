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

        trustlet.enable_trusted_enrollment = false;

        common.image_processing_cols = 36;
        common.image_processing_rows = 144;
        common.max_enrolling_fingers = 5;
        common.max_enrolling_samples = 8;

        algorithm.min_enrolling_quality_threshold = 30;
        algorithm.min_enrolling_coverage_threshold = 30;
        algorithm.min_identify_quality_threshold = 30;
        algorithm.min_identify_coverage_threshold = 30;
      };
      defaultText = lib.literalExpression ''
        {
          driver.spi_bus_num = 14;
          device.spi_default_bps = 2000000;
          device.preferred_device_id = "0x9391";

          trustlet.enable_trusted_enrollment = false;

          common.image_processing_cols = 36;
          common.image_processing_rows = 144;
          common.max_enrolling_fingers = 5;
          common.max_enrolling_samples = 8;

          algorithm.min_enrolling_quality_threshold = 30;
          algorithm.min_enrolling_coverage_threshold = 30;
          algorithm.min_identify_quality_threshold = 30;
          algorithm.min_identify_coverage_threshold = 30;
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
        - `common.image_processing_cols` and `_rows` -- the sensor's geometry,
          36 x 144. Read with a default of zero, and zero sizes an allocation
          to nothing, which the application then dereferences.
        - `common.max_enrolling_fingers` -- also zero by default, which refuses
          every enrolment and leaves no template slots to load.
        - `common.max_enrolling_samples` -- how many counted samples an
          enrolment needs. Deliberately small: the counter only falls for a
          touch that adds new coverage while the sample cap counts every
          accepted one, so a large value can exhaust the cap before the counter
          reaches zero and the enrolment can never finish.
        - `algorithm.min_*_threshold` -- quality and coverage floors. Zero
          accepts nothing.
        - `trustlet.enable_trusted_enrollment` -- left on, the application
          refuses every enrolment with -208 unless it is given a credential
          token signed by Android's Gatekeeper, which nothing on a Linux system
          can produce. Turning it off means the application no longer requires
          proof that a user authenticated before a finger is added, so whatever
          can reach the application can enrol one. That check has to come from
          above it -- polkit, in front of fprintd.

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

      store = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/ffsupplicant";
        description = ''
          Where the sealed objects the trusted application persists are kept:
          its templates, its chip calibration and its serial id.

          The application asks for Android paths under `/data/vendor_de`, which
          mean nothing here, so every name is rooted under this directory. The
          contents are sealed by the secure world before they arrive and are
          useless without the device that sealed them, but they are still the
          enrolled fingerprints -- delete this directory and the fingers are
          gone.
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

    fprintd = lib.mkEnableOption ''
      {command}`fprintd`, which is what turns the reach this module provides
      into fingerprint authentication: enrolment with {command}`fprintd-enroll`,
      and unlocking through the `fprintd` PAM module wherever
      {option}`security.pam.services.<name>.fprintAuth` is set.

      This pulls in a libfprint carrying the FocalTech QSEE driver (see
      packages/libfprint); nixpkgs' own libfprint has no driver that can see
      this sensor, and would find no device at all.

      Enrolment reaches the trusted application directly, so it needs the
      supplicant running and the application present -- the same requirements
      {command}`ftharness` has
    '';

    tzlog = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Build and load {command}`qcom_tzlog`, which exposes TrustZone's
        diagnostic area at `/sys/kernel/debug/tzlog/raw` and QSEE's application
        log at `/sys/kernel/debug/tzlog/qsee`.

        The application log is the useful one: it stays empty until a buffer is
        registered with QSEE, so a trusted application that faults is otherwise
        invisible from Linux -- the SCM call returns an error the kernel has no
        name for and nothing else is recorded anywhere. With it, the
        application names the last function it entered.

        Off by default. It maps memory the secure world owns and hands it to
        user space, which is a reasonable thing to do while working on a
        trusted application and not otherwise.
      '';
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
    boot.kernelModules = [ "qseecomtee" ] ++ lib.optional cfg.tzlog "qcom_tzlog";

    hardware.firmware = [ firmware ];

    users.groups.${cfg.group} = { };

    # The client device is created 0600 root:root. Anything that talks to a
    # trusted application needs it; loading still needs root.
    services.udev.extraRules = ''
      SUBSYSTEM=="tee", KERNEL=="tee[0-9]*", GROUP="${cfg.group}", MODE="0660"
    '';

    environment.etc."focaltech/ff_config.json".source = configFile;

    boot.extraModulePackages = lib.optional cfg.tzlog pkgs.qcom-tzlog;

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
        ExecStart = "${lib.getExe pkgs.ffsupplicant} --store ${cfg.supplicant.store} ${
          lib.concatMapStringsSep " " (id: "--listener ${toString id}") cfg.supplicant.listeners
        }${lib.optionalString cfg.supplicant.verbose " -v"}";
        Restart = "always";
        RestartSec = "1";

        # /dev/teepriv0 requires CAP_SYS_ADMIN, and the RPMB LUN is root-only.
        User = "root";

        # Create the store if it is the default location under /var/lib, so a
        # first boot has somewhere to put the objects. A store elsewhere is the
        # administrator's to create.
        StateDirectory = lib.mkIf (cfg.supplicant.store == "/var/lib/ffsupplicant") "ffsupplicant";
        StateDirectoryMode = "0700";
      };
    };

    # fprintd owns enrolment and matching; the driver in packages/libfprint is
    # what lets it see this sensor at all.
    services.fprintd.enable = cfg.fprintd;

    # fprintd's unit ships a device whitelist covering the buses fingerprint
    # readers usually hang off -- USB, SPI, hidraw -- and this sensor is on
    # none of them. It is reached through the misc node the kernel driver
    # registers and the TEE client device, and without both the daemon opens
    # neither: the sensor node fails with EPERM and the device looks broken
    # rather than forbidden. DeviceAllow appends, so this widens the list
    # rather than replacing it.
    systemd.services.fprintd.serviceConfig.DeviceAllow = lib.mkIf cfg.fprintd [
      "/dev/focaltech_fp rw"
      "char-tee rw"
    ];

    # The trusted application has to be resident before anything opens a
    # session on it, and it stays loaded only while the session that loaded it
    # is open -- the driver unloads it the moment that closes. So one process
    # loads it and holds it, and everything else attaches to what it holds.
    #
    # Loading needs /dev/teepriv0 and so needs root; the clients that follow do
    # not. Keeping the load here rather than in fprintd is also what lets
    # `ftharness` and fprintd coexist: the application is loaded once, by
    # neither of them.
    systemd.services.focal32-load = lib.mkIf cfg.fprintd {
      description = "Hold the fingerprint trusted application loaded";
      wantedBy = [ "multi-user.target" ];

      # The application reaches its storage through the supplicant's listeners
      # as soon as it initialises, so the supplicant has to be there first.
      after = [
        "systemd-udev-settle.service"
      ]
      ++ lib.optional cfg.supplicant.enable "ffsupplicant.service";
      wants = lib.optional cfg.supplicant.enable "ffsupplicant.service";

      # fprintd is activated on demand by D-Bus, so it is not ordered after
      # this; what makes the ordering hold is that the application is loaded
      # before anything can ask for a finger.
      before = [ "fprintd.service" ];

      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.ftharness} load --app ${cfg.appName}";

        # /dev/teepriv0 requires CAP_SYS_ADMIN.
        User = "root";

        # The process does nothing but hold the session open, so a restart is
        # an unload and a reload -- which is also the only way to recover if
        # the application faults.
        Restart = "always";
        RestartSec = "1";

        # ExecStart blocks on a signal rather than exiting, so a clean stop is
        # SIGTERM, and exiting is what closes the session.
        KillSignal = "SIGTERM";

        StandardInput = "null";
      };
    };
  };
}
