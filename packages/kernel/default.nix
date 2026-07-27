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
  #   USB_G_SERIAL:         USB serial gadget console for debugging.
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
  nixosConfig = {
    DMIID = "y";
    U_SERIAL_CONSOLE = "y";
    USB_G_SERIAL = "y";
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
    EFI = "y";
    EFI_STUB = "y";
    EFI_ZBOOT = "y";
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
