# Mainline U-Boot for the Fairphone 5 (Qualcomm QCM6490).
#
# Built from the generic Qualcomm phone config, see:
# https://docs.u-boot.org/en/latest/board/qualcomm/board.html
#
# U-Boot is flashed (wrapped in an Android boot image, see `mkUbootImage` in
# the flake) to the `boot` partition once. It then exposes a UEFI environment:
# the patched preboot command maps the `userdata` partition with blkmap so the
# GPT disk image we flash there (ESP + root, see `modules/hardware/disk-image.nix`)
# is discovered by standard boot, which chain-loads systemd-boot from the ESP.
#
# Ported from https://github.com/not-matthias/nixos-qcm6490 (common/uboot-qcm6490.nix).
{
  buildUBoot,
  fetchFromGitHub,
  xxd,
  bison,
  flex,
  openssl,
  gnutls,
}:
buildUBoot {
  version = "2026.04-unstable";

  src = fetchFromGitHub {
    owner = "u-boot";
    repo = "u-boot";
    rev = "987c93fc68a641cc735c9828872511a947e54191";
    hash = "sha256-5282c4RTo5cr3mtCnnECd5boQo79vnG21T8EHR+F5PM=";
  };

  defconfig = "qcom_defconfig qcom-phone.config";
  extraMakeFlags = [ "DEVICE_TREE=qcom/qcm6490-fairphone-fp5" ];

  extraConfig = ''
    CONFIG_CMD_HASH=y
    CONFIG_CMD_BLKMAP=y
    CONFIG_BLKMAP=y
    CONFIG_CMD_UFETCH=y
    CONFIG_CMD_SELECT_FONT=y
    CONFIG_VIDEO_FONT_8X16=n
    CONFIG_VIDEO_FONT_16X32=y
    CONFIG_VIDEO_FONT_16X32_VGA=y
  '';

  # Make the userdata partition (where our GPT disk image lives) visible as a
  # blkmap device, so U-Boot's standard boot finds the ESP inside it.
  prePatch = ''
    substituteInPlace board/qualcomm/qcom-phone.env \
      --replace-fail 'preboot=scsi scan' \
      'preboot=scsi scan; part start scsi 0 userdata ustart; part size scsi 0 userdata usize; blkmap create root; blkmap map root 0 0x''${usize} linear scsi 0 0x''${ustart}'
  '';

  filesToInstall = [
    "u-boot*"
    "dts/upstream/src/arm64/qcom/qcm6490-fairphone-fp5.dtb"
  ];

  extraMeta.platforms = [ "aarch64-linux" ];

  nativeBuildInputs = [
    xxd
    bison
    flex
    openssl
    gnutls
  ];
}
