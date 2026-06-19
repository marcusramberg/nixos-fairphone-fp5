{
  fetchFromGitHub,
  fetchFromGitLab,
  lib,
  linuxKernel,
  stdenv,
  ...
}:
let
  # Kernel source from `sc7280-mainline` repository.
  kernelSrc = fetchFromGitHub {
    owner = "sc7280-mainline";
    repo = "linux";
    rev = "v7.0.8-sc7280";
    hash = "sha256-dU+UeCr8aVIg226ZnqryPlLuOPsKkKgR/KN/LkvHDGo=";
  };

  # Source of postmarketOS `pmaports` repository.
  pmaportsSrc = fetchFromGitLab {
    domain = "gitlab.postmarketos.org";
    owner = "postmarketOS";
    repo = "pmaports";
    rev = "6ff32835f458c490e008373eeaac3d2a5f82f311";
    hash = "sha256-1vrNlbwFbaJmHTAmu/vW0tIcmRYHpRx/lWHvqvhY/sk=";
  };

  # Use the kernel configuration from PostmarketOS for the `sc7280` chipset as the base.
  #
  # However, we need to override some options that are disabled in PostmarketOS config to
  # make it compatible with NixOS and enable some useful stuff:
  # - CONFIG_DMIID: NixOS asserts that this is enabled for some reason...
  # - CONFIG_U_SERIAL_CONSOLE: Enables USB serial gadget console output for debugging.
  # - CONFIG_USB_G_SERIAL: Classic USB serial gadget driver.
  # - CONFIG_ANDROID_BINDERFS: Required for Waydroid (Android container support).
  #
  # Additional netfilter/iptables extensions required by NixOS firewall:
  # - CONFIG_NETFILTER_XT_MATCH_PKTTYPE: Packet type matching.
  # - CONFIG_NETFILTER_XT_MATCH_LIMIT: Rate limiting for firewall rules.
  # - CONFIG_NETFILTER_XT_MATCH_RECENT: Recent connections tracking.
  # - CONFIG_NETFILTER_XT_MATCH_STATE: Connection state matching.
  # - CONFIG_NETFILTER_XT_TARGET_LOG: Logging target for firewall rules.
  #
  # DisplayPort output over USB-C:
  # - CONFIG_TYPEC_DP_ALTMODE: Required for DP Alt Mode over USB-C to work.
  # - CONFIG_TYPEC_UCSI: Unchanged, as upstream already uses `=y`.
  configfile = stdenv.mkDerivation {
    name = "kernel-config";
    src = "${pmaportsSrc}/device/community/linux-postmarketos-qcom-sc7280/config-postmarketos-qcom-sc7280.aarch64";
    dontUnpack = true;

    buildPhase = ''
      # Read the original config and apply our modifications.
      sed \
        -e 's/# CONFIG_DMIID is not set/CONFIG_DMIID=y/' \
        -e 's/# CONFIG_U_SERIAL_CONSOLE is not set/CONFIG_U_SERIAL_CONSOLE=y/' \
        -e 's/# CONFIG_USB_G_SERIAL is not set/CONFIG_USB_G_SERIAL=y/' \
        -e 's/# CONFIG_ANDROID_BINDERFS is not set/CONFIG_ANDROID_BINDERFS=y/' \
        -e 's/# CONFIG_NETFILTER_XT_MATCH_PKTTYPE is not set/CONFIG_NETFILTER_XT_MATCH_PKTTYPE=m/' \
        -e 's/# CONFIG_NETFILTER_XT_MATCH_LIMIT is not set/CONFIG_NETFILTER_XT_MATCH_LIMIT=m/' \
        -e 's/# CONFIG_NETFILTER_XT_MATCH_RECENT is not set/CONFIG_NETFILTER_XT_MATCH_RECENT=m/' \
        -e 's/# CONFIG_NETFILTER_XT_MATCH_STATE is not set/CONFIG_NETFILTER_XT_MATCH_STATE=m/' \
        -e 's/# CONFIG_NETFILTER_XT_TARGET_LOG is not set/CONFIG_NETFILTER_XT_TARGET_LOG=m/' \
        -e 's/# CONFIG_NETFILTER_XT_TARGET_CONNMARK is not set/CONFIG_NETFILTER_XT_TARGET_CONNMARK=m/' \
        -e 's/# CONFIG_NETFILTER_XT_MATCH_CONNMARK is not set/CONFIG_NETFILTER_XT_MATCH_CONNMARK=m/' \
        -e 's/# CONFIG_TYPEC_DP_ALTMODE is not set/CONFIG_TYPEC_DP_ALTMODE=y/' \
        -e 's/# CONFIG_WIREGUARD is not set/CONFIG_WIREGUARD=m/' \
        -e 's/# CONFIG_NFC is not set/CONFIG_NFC=m/' \
        $src > config

      # NFC sub-options are not present in pmOS config because CONFIG_NFC is
      # disabled there. Append them explicitly.
      echo 'CONFIG_NFC_NCI=m' >> config
      echo 'CONFIG_NFC_ST_NCI=m' >> config
      echo 'CONFIG_NFC_ST_NCI_I2C=m' >> config

      # EFI boot via U-Boot's UEFI environment: keep CONFIG_EFI/CONFIG_EFI_STUB
      # from the pmOS config and additionally build the EFI zboot image
      # (vmlinuz.efi) that systemd-boot loads from the ESP.
      if grep -q '^# CONFIG_EFI_ZBOOT is not set' config; then
        sed -i 's/^# CONFIG_EFI_ZBOOT is not set/CONFIG_EFI_ZBOOT=y/' config
      elif ! grep -q '^CONFIG_EFI_ZBOOT=' config; then
        echo 'CONFIG_EFI_ZBOOT=y' >> config
      fi
    '';

    installPhase = ''
      cp config $out
    '';
  };

  kernelVersion.string = "7.0.8";
  modDirVersion = kernelVersion.string;
in
linuxKernel.manualConfig {
  inherit lib;

  allowImportFromDerivation = true;
  inherit configfile modDirVersion;
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
      # Add ST21NFCD to the st-nci I2C driver device tree match table.
      # The ST21NFCD is NCI 2.0 compliant and compatible with the existing
      # st-nci driver protocol handling.
      name = "nfc-st-nci-add-st21nfcd";
      patch = ./patches/nfc-st-nci-add-st21nfcd.patch;
    }
    {
      # Add the ST21NFCD NFC controller device tree node on I2C9.
      # Hardware details from Fairphone 5 Android kernel source.
      name = "dts-add-st21nfcd-nfc";
      patch = ./patches/dts-add-st21nfcd-nfc.patch;
    }
  ];
  src = kernelSrc;
  stdenv =
    # Override `stdenv` to produce the EFI zboot image (`vmlinuz.efi`) that
    # systemd-boot loads from the ESP. Must match `linux-kernel.target` in
    # `nixpkgs.hostPlatform` set by `modules/hardware/default.nix`.
    stdenv.override {
      hostPlatform = stdenv.hostPlatform // {
        linux-kernel = stdenv.hostPlatform.linux-kernel // {
          target = "vmlinuz.efi";
          installTarget = "zinstall";
        };
      };
    };
  version = kernelVersion.string;
}
