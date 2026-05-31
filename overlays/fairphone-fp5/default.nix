# Nixpkgs overlay to add custom Fairphone 5 packages.
final: prev: {
  # Qualcomm firmware squasher to convert split `.mdt` (meta data table) firmware files
  # to monolithic `.mbn` (multi-binary) format. Note: This is a build-time tool that
  # runs during firmware preparation (not on the device).
  pil-squasher = final.callPackage ../../packages/pil-squasher { };

  # ALSA UCM2 profiles for Fairphone 5 sound card.
  # Separate from upstream alsa-ucm-conf to avoid busting the cache
  # for packages that depend on alsa-lib (e.g. firefox).
  alsa-ucm-conf-fairphone-fp5 = final.callPackage ../../packages/alsa-ucm-conf-fairphone-fp5 {};

  # WirePlumber configuration for Qualcomm audio on Fairphone 5.
  wireplumber-qcom = final.callPackage ../../packages/wireplumber-qcom {};

  # Firmware package for Fairphone 5.
  firmware-fairphone-fp5 = final.callPackage ../../packages/firmware { };

  # Custom kernel package for Fairphone 5.
  kernel-fairphone-fp5 = final.callPackage ../../packages/kernel { };

  # Protection domain mapper for Qualcomm modems.
  pd-mapper = final.callPackage ../../packages/qrtr/pd-mapper.nix { };

  # QMI IDL compiler (build dependency for rmtfs).
  qmic = final.callPackage ../../packages/qrtr/qmic.nix { };

  # QRTR (Qualcomm IPC Router) userspace tools.
  qrtr = final.callPackage ../../packages/qrtr/qrtr.nix { };

  # Remote filesystem service for Qualcomm modems.
  rmtfs = final.callPackage ../../packages/qrtr/rmtfs.nix { };

  # TFTP server over QRTR for Qualcomm modems.
  tqftpserv = final.callPackage ../../packages/qrtr/tqftpserv.nix { };

  # Configure MAC addresses at boot for WiFi and Bluetooth.
  bootmac = final.callPackage ../../packages/bootmac { };
}
