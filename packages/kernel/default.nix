{
  fetchFromGitHub,
  lib,
  linuxKernel,
  runCommand,
  stdenv,
  ...
}:
let
  # Kernel source from `sc7280-mainline` repository.
  kernelSrc = fetchFromGitHub {
    owner = "sc7280-mainline";
    repo = "linux";
    rev = "sc7280-7.1.y";
    hash = "sha256-Q4mFSrRUS1+RIoPpdTxHr1lg5Ba2H9EPGJB20yOnKT0=";
  };

  # Base kernel .config from postmarketOS for the `sc7280` chipset.
  pmosConfigUrl = builtins.fetchurl {
    url = "https://gitlab.postmarketos.org/postmarketOS/pmaports/-/raw/c9dbdc23ae775aa5cea8b857c123f1696c04528f/device/community/linux-postmarketos-qcom-sc7280/config-postmarketos-qcom-sc7280.aarch64";
    sha256 = "1vjffmn4wx6b6yxp7cn80qpzm744n8h5wci5xwxrpf5f17rq9w87";
  };

  # Parse a kernel .config into an attrset { CONFIG_FOO = "y"|"m"; } for set
  # options, matching nixpkgs' own `readConfig` (full CONFIG_ keys, "is not
  # set" lines dropped). Used only to build the passthru `config`.
  parseConfig =
    content:
    let
      parseLine =
        line:
        let
          m = builtins.match "(CONFIG_[^=]+)=([ym])" line;
        in
        lib.optional (m != null) {
          name = builtins.elemAt m 0;
          value = builtins.elemAt m 1;
        };
    in
    builtins.listToAttrs (lib.concatMap parseLine (lib.splitString "\n" content));

  pmosConfig = parseConfig (builtins.readFile pmosConfigUrl);

  # NixOS-compatible overrides on top of the pmOS base config.
  #
  # Use "y" (built-in), "m" (module), or "n" (disabled). Keys omit the
  # CONFIG_ prefix. pmOS options are inherited; only deltas are listed.
  #
  # - DMIID:                NixOS asserts this is enabled.
  # - U_SERIAL_CONSOLE /
  #   USB_G_SERIAL:         USB serial gadget console for debugging. A module,
  #                         not built in: a legacy gadget driver binds the UDC
  #                         when it registers and there is no way to take it
  #                         back, so built in it owns a600000.usb from boot and
  #                         every configfs gadget fails to bind with -EBUSY
  # - ANDROID_BINDERFS:     Waydroid (Android container) support.
  # - NETFILTER_XT_*:       netfilter/iptables extensions the NixOS firewall needs.
  # - TYPEC_DP_ALTMODE:     DisplayPort Alt Mode over USB-C.
  # - WIREGUARD:            WireGuard VPN.
  # - NFC / NFC_NCI /
  #   NFC_ST21NFC_NCI:      FP5 CLF is a plain NCI controller over I2C, driven by
  #                         our st21nfc-nci driver (NCI core, not st-nci).
  # - EFI / EFI_STUB /
  #   EFI_ZBOOT:            EFI boot via U-Boot's UEFI env; systemd-repart asserts
  #                         the EFI boot stub is present.
  # - TEE_QSEECOM:          Exposes QSEE trusted applications (loaded over the
  #                         legacy QSEECOM command interface, not smcinvoke)
  #                         through the TEE subsystem. Needed to reach the FP5
  #                         fingerprint TA. Deps QCOM_QSEECOM, QCOM_MDT_LOADER
  #                         and TEE are already set in the pmOS base config.
  # - MISC_FOCALTECH_FP:     Owns the FP5 fingerprint sensor's reset, power and
  #                         interrupt pins. The sensor's SPI bus belongs to the
  #                         secure world, so this driver never touches it.
  # - PM_DEBUG / PM_SLEEP_DEBUG /
  #   PM_ADVANCED_DEBUG /
  #   GENERIC_IRQ_DEBUGFS:  Suspend diagnostics. Without these the kernel says
  #                         only "Wakeup pending. Abort CPU freeze" and never
  #                         names the culprit: PM_SLEEP_DEBUG adds
  #                         /sys/power/pm_wakeup_irq and, with
  #                         /sys/power/pm_debug_messages set to 1, the
  #                         "PM: Triggering wakeup from IRQ n (name)" line;
  #                         GENERIC_IRQ_DEBUGFS exposes /sys/kernel/debug/irq so
  #                         the wakeup-armed IRQs can be listed. Suspend on the
  #                         FP5 both aborts (BT HCI UART 99c000.serial and the
  #                         UCSI source power supply veto it) and, once those two
  #                         have their power/wakeup disabled, resumes ~6ms after
  #                         "Disabling non-boot CPUs" from an IRQ no
  #                         power/wakeup toggle accounts for.
  nixosConfig = {
    DMIID = "y";
    U_SERIAL_CONSOLE = "y";
    USB_G_SERIAL = "m";
    ANDROID_BINDERFS = "y";
    NETFILTER_XT_MATCH_PKTTYPE = "m";
    NETFILTER_XT_MATCH_LIMIT = "m";
    NETFILTER_XT_MATCH_RECENT = "m";
    NETFILTER_XT_MATCH_STATE = "m";
    NETFILTER_XT_TARGET_LOG = "m";
    NETFILTER_XT_TARGET_CONNMARK = "m";
    NETFILTER_XT_MATCH_CONNMARK = "m";
    TYPEC_DP_ALTMODE = "y";
    WIREGUARD = "m";
    NFC = "m";
    NFC_NCI = "m";
    NFC_ST21NFC_NCI = "m";
    NFT_FIB = "y";
    NFT_FIB_INET = "y";
    EFI = "y";
    EFI_STUB = "y";
    EFI_ZBOOT = "y";
    TEE_QSEECOM = "m";
    MISC_FOCALTECH_FP = "m";
    PM_DEBUG = "y";
    PM_SLEEP_DEBUG = "y";
    PM_ADVANCED_DEBUG = "y";
    GENERIC_IRQ_DEBUGFS = "y";
  };

  # Render the overrides into Kconfig lines. `make oldconfig` reads .config
  # last-value-wins, so appending these after the pmOS base overrides any
  # prior value (including "# CONFIG_X is not set").
  overrideLines = lib.mapAttrsToList (
    name: value: if value == "n" then "# CONFIG_${name} is not set" else "CONFIG_${name}=${value}"
  ) nixosConfig;

  # The actual .config the kernel is built with: pmOS base + our overrides.
  # Generated purely from Nix values, so no import-from-derivation is needed.
  configfile = runCommand "kernel-config" { } ''
    cat ${pmosConfigUrl} > $out
    cat >> $out <<'EOF'
    ${lib.concatStringsSep "\n" overrideLines}
    EOF
  '';

  # Merged config attrset for the kernel's passthru (feature queries etc.),
  # mirroring nixpkgs' readConfig format: full CONFIG_ keys, "n" dropped.
  mergedConfig =
    pmosConfig
    // lib.mapAttrs' (name: value: lib.nameValuePair "CONFIG_${name}" value) (
      lib.filterAttrs (_: v: v != "n") nixosConfig
    );

  kernelVersion.string = "7.1.2";
  modDirVersion = kernelVersion.string;
in
linuxKernel.manualConfig {
  inherit lib;

  # build.nix symlinks `configfile` to .config and runs `make oldconfig`, so
  # it must already contain our overrides (rendered above). `config` is passed
  # explicitly to avoid the import-from-derivation nixpkgs would otherwise use
  # to parse a derivation-built configfile.
  inherit configfile;
  config = mergedConfig;

  # `build.nix` (manualConfig) defaults features to {} unlike generic.nix
  # which folds efiBootStub = true. systemd-repart asserts this feature
  # exists, so set it explicitly.
  features = {
    efiBootStub = true;
  };

  inherit modDirVersion;
  kernelPatches = [
    {
      name = "hci-qca-drop-unused-event";
      patch = ./patches/hci-qca-drop-unused-event.patch;
    }
    {
      # The LPASS LPI pinctrl's clocks are provided by the ADSP (q6prm over
      # GLINK). If the pinctrl probes before the ADSP remoteproc has booted,
      # the clock enable times out and the probe fails permanently, leaving
      # the sound card stuck in deferred probe. Return -EPROBE_DEFER instead
      # so the probe is retried once the ADSP is up.
      name = "pinctrl-lpass-lpi-defer-on-clk-timeout";
      patch = ./patches/pinctrl-lpass-lpi-defer-on-clk-timeout.patch;
    }
    {
      # Raw-NCI/I2C driver for the FP5 ST21NFCD. The chip is a plain NCI
      # controller (3-byte header, IRQ-driven, no NDLC link layer), so the
      # mainline st-nci driver does not fit; this registers an nci_dev and
      # lets the kernel NCI core drive it.
      name = "nfc-st21nfc-nci-driver";
      patch = ./patches/nfc-st21nfc-nci-driver.patch;
    }
    {
      # Add the ST21NFCD NFC controller device tree node on I2C9.
      # Hardware details from Fairphone 5 Android kernel source.
      name = "dts-add-st21nfcd-nfc";
      patch = ./patches/dts-add-st21nfcd-nfc.patch;
    }
    {
      # Enable 4-lane DisplayPort via QMP Combo PHY mode-switch.
      # Adds mode-switch property to the PHY, wires data-lanes=<0 1 2 3>
      # in the SoC dtsi, and removes the now-redundant board-level override.
      name = "dts-kodiak-4lane-dp-mode-switch";
      patch = ./patches/dts-kodiak-4lane-dp-mode-switch.patch;
    }
    {
      # SC7280/QCM6490 has only one DSPP block (DSPP_0, paired with LM_0).
      # In a dual-display setup (internal DSI + external DP), when both CRTCs
      # request color management, the second CRTC cannot reserve mixers with a
      # DSPP and DP hotplug fails ("unable to find appropriate mixers", -119).
      # Retry the reservation without DSPP so the external display works
      # (without hw color management) rather than failing entirely.
      # https://github.com/sc7280-mainline/linux/pull/22
      name = "dpu-dspp-reservation-fallback";
      patch = ./patches/dpu-dspp-reservation-fallback.patch;
    }
    {
      # qmp_combo_typec_mux_set() drops a QMPPHY mode switch requested while
      # the DP PHY is still powered on -- "delaying switch" is never retried.
      # Unplugging a DP+USB3 dock leaves qmpphy_mode stuck at USB3DP; the next
      # suspend tears the PHY down, and the following plug takes the "same
      # qmpphy mode" early return, so the PHY is never reprogrammed. Both
      # DisplayPort and USB3 stay dead until reboot. Apply the deferred switch
      # from qmp_combo_dp_power_off() once the DP PHY is down.
      name = "qmp-combo-apply-deferred-mode-switch";
      patch = ./patches/qmp-combo-apply-deferred-mode-switch.patch;
    }
    {
      # qmp_combo_apply_mode() discards the result of qmp_combo_usb_power_on(), which
      # can fail: it polls PHYSTATUS with a 10 ms timeout and gives up with -ETIMEDOUT
      # if the USB3 PHY does not come out of reset.
      name = "qmp-combo-do-not-latch";
      patch = ./patches/qmp-combo-do-not-latch-unapplied-mode.patch;
    }
    {
      # msm_dp_display_send_hpd_event() used drm_helper_hpd_irq_event(), which
      # only emits a uevent when the probed connector status changed. Since
      # ->detect() is derived from link_ready and link_ready is set before the
      # call, a userspace probe racing it swallows the event. The compositor
      # then sits on a failed -ENOTCONN modeset with no retry, and the external
      # display stays dark until the DRM master is replaced. Notify the
      # connector unconditionally instead.
      name = "dp-notify-connector-unconditionally-on-hpd";
      patch = ./patches/dp-notify-connector-unconditionally-on-hpd.patch;
    }
    {
      # libcamera probes the sensor sub-device for crop/native-size selection
      # targets to derive the pixel array geometry. Neither FP5 sensor answered
      # them ("the sensor kernel driver needs to be fixed"): imx858 had no
      # .get_selection, and s5kjn1's only handled CROP/CROP_BOUNDS, reported the
      # per-mode size, and copied width into height (8160x8160 active area).
      # Report the full native array for all crop targets on both sensors.
      name = "media-fp5-sensor-crop-selection";
      patch = ./patches/media-fp5-sensor-crop-selection.patch;
    }
    {
      # imx858_power_on() released reset before enabling MCLK and waited only
      # ~1ms; Sony sensors need MCLK stable before XCLR is deasserted. Cold boot
      # worked by luck, but a runtime-PM power cycle (camera app restart) raced,
      # NAKing the first i2c and wedging the GENI bus ("Timeout resetting
      # RX_FSM"). Reorder to regulators -> MCLK -> settle -> release reset.
      name = "media-imx858-power-on-ordering";
      patch = ./patches/media-imx858-power-on-ordering.patch;
    }
    {
      # QSEECOM TEE driver: exposes QSEE trusted applications through the TEE
      # subsystem (/dev/tee*), so user space can load an application from
      # /lib/firmware, open a session to it and invoke commands, and so a
      # supplicant can answer the listener services (file service, RPMB, time)
      # that a trusted application needs the normal world to run.
      #
      # QSEE is the command-based Qualcomm interface; the in-tree qcomtee
      # driver serves the object-based smcinvoke one, and a trusted application
      # is built against one or the other. The FP5 fingerprint application
      # (focal32, FocalTech FT9362) answers only over QSEECOM.
      #
      # Squashed from the `qcom-qseecom-tee` series (42 commits, based on
      # v7.1) by Dawid Wróbel, https://github.com/wrobelda/linux — not yet
      # posted upstream. Also extends soc/qcom mdt_loader to assemble a
      # split firmware image into one contiguous blob, which the driver
      # needs to hand an application to TZ.
      name = "tee-qseecom-driver";
      patch = ./patches/tee-qseecom-driver.patch;
    }
    {
      # QSEECOM binds only on machines in an explicit allowlist in qcom_scm.
      # Add "fairphone,fp5".
      name = "qcom-scm-qseecom-fp5-allowlist";
      patch = ./patches/qcom-scm-qseecom-fp5-allowlist.patch;
    }
    {
      # TZ refuses an invoke whose request is 16 bytes or more with "invalid
      # argument", and takes the same request one byte shorter -- the boundary
      # does not move with the response size, so what it objects to is where
      # the response begins. The vendor HAL's shared buffer is a page-aligned
      # request region (0x78000) followed by a page-aligned response region
      # (0x8040), so stage the response on a page boundary too.
      #
      # The FP5 fingerprint application needs this: its command header is 16
      # bytes, so every command it accepts was one the secure world refused.
      name = "tee-qseecom-align-response";
      patch = ./patches/tee-qseecom-align-response.patch;
    }
    {
      # The fingerprint application answers in the request buffer, not the
      # response one: it writes its result into the request header at +8 and
      # sets bit 31 of the command id to say it answered. The driver stages
      # the request in its own memory and copied only the response back, so
      # that answer was dropped. Copy the request back when the client passes
      # it as an inout memref.
      name = "tee-qseecom-request-writeback";
      patch = ./patches/tee-qseecom-request-writeback.patch;
    }
    {
      # The FP5's fingerprint sensor is a FocalTech FT9362 in the power button.
      # Its SPI bus belongs to the secure world, so this driver owns only what
      # Linux is left with: the reset and power pins, and the interrupt. The
      # trusted application expects the sensor powered and out of reset before
      # it will talk to it.
      name = "misc-focaltech-fp-driver";
      patch = ./patches/misc-focaltech-fp-driver.patch;
    }
    {
      # The sensor's node and its pinctrl states: reset on GPIO35, power on
      # GPIO60, interrupt on GPIO34. Pin numbers and the pinctrl state names
      # the driver looks up both come from the Fairphone vendor kernel.
      name = "dts-fp5-fingerprint-sensor";
      patch = ./patches/dts-fp5-fingerprint-sensor.patch;
    }
    {
      # The connector change work runs on the unfreezable system_wq, so a
      # cable plug that wakes the phone is handled before the geni i2c
      # controllers resume. It reaches ->connector_status(), which writes the
      # orientation to the fsa4480 switch and the ptn36502 redriver over i2c,
      # and the transfer is refused with -ESHUTDOWN ("Transfer while
      # suspended") -- so the orientation is lost, not just warned about.
      name = "ucsi-connector-change-on-freezable-wq";
      patch = ./patches/ucsi-connector-change-on-freezable-wq.patch;
    }
    {
      # Same bug on the altmode notification path, fixed upstream by Abel
      # Vesa; not in this tree yet.
      name = "pmic-glink-altmode-freezable-wq";
      patch = ./patches/pmic-glink-altmode-freezable-wq.patch;
    }
  ];
  src = kernelSrc;

  # Build the EFI zboot image (`vmlinuz.efi`) that systemd-boot loads
  # from the ESP. For aarch64, build.nix defaults target to `Image`,
  # so pass explicitly.
  target = "vmlinuz.efi";

  # Must match `linux-kernel.target` in `nixpkgs.hostPlatform` set by
  # `modules/hardware/default.nix`.
  stdenv = stdenv.override {
    hostPlatform = stdenv.hostPlatform // {
      linux-kernel = stdenv.hostPlatform.linux-kernel // {
        target = "vmlinuz.efi";
        installTarget = "zinstall";
      };
    };
  };

  version = kernelVersion.string;
}
