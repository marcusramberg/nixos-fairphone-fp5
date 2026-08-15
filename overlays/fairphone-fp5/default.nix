# Nixpkgs overlay to add custom Fairphone 5 packages.
final: prev: {
  # Qualcomm firmware squasher to convert split `.mdt` (meta data table) firmware files
  # to monolithic `.mbn` (multi-binary) format. Note: This is a build-time tool that
  # runs during firmware preparation (not on the device).
  pil-squasher = final.callPackage ../../packages/pil-squasher { };

  # ALSA UCM2 profiles for Fairphone 5 sound card.
  # Separate from upstream alsa-ucm-conf to avoid busting the cache
  # for packages that depend on alsa-lib (e.g. firefox).
  alsa-ucm-conf-fairphone-fp5 = final.callPackage ../../packages/alsa-ucm-conf-fairphone-fp5 { };

  # WirePlumber configuration for Qualcomm audio on Fairphone 5.
  wireplumber-qcom = final.callPackage ../../packages/wireplumber-qcom { };

  # Firmware package for Fairphone 5.
  firmware-fairphone-fp5 = final.callPackage ../../packages/firmware { };

  # Custom kernel package for Fairphone 5.
  kernel-fairphone-fp5 = final.callPackage ../../packages/kernel { };

  # Mainline U-Boot for Fairphone 5; flashed to the `boot` partition wrapped
  # in an Android boot image, provides a UEFI environment for systemd-boot.
  uboot-fairphone-fp5 = final.callPackage ../../packages/uboot { };

  # iio-sensor-proxy with the Qualcomm SSC backend enabled. The Fairphone 5's
  # sensors (accelerometer etc.) hang off the ADSP sensors PD and are reached
  # via libssc over FastRPC, not via kernel IIO drivers. nixpkgs builds
  # iio-sensor-proxy without libssc, so the SSC backend is compiled out.
  iio-sensor-proxy = prev.iio-sensor-proxy.overrideAttrs (old: {
    buildInputs = (old.buildInputs or [ ]) ++ [ final.libssc ];
    mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dssc-support=enabled" ];
  });

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

  # Bring-up client for the FP5 fingerprint trusted application, over the
  # QSEECOM TEE driver (see modules/fingerprint).
  ftharness = final.callPackage ../../packages/ftharness { };

  # Serves QSEECOM listener services, which is how a trusted application
  # reaches its secure storage: RPMB for authenticated frames, and the
  # GlobalPlatform file service for the sealed objects it persists. Without it
  # no template can be written, so nothing can be enrolled.
  ffsupplicant = final.callPackage ../../packages/ffsupplicant { };

  # Reads TrustZone's diagnostic and application logs. A debugging aid: without
  # the application log, a trusted application that faults says nothing Linux
  # can see.
  qcom-tzlog = final.callPackage ../../packages/tzlog {
    kernel = final.kernel-fairphone-fp5;
  };

  # The fingerprint sensor's trusted application, in the split form the
  # QSEECOM TEE driver loads. Kept out of firmware-fairphone-fp5 because that
  # package squashes every .mdt it finds into a monolithic .mbn.
  focal32-firmware = final.callPackage ../../packages/focal32-firmware { };

  # libfprint carrying the FocalTech QSEE driver, so fprintd can see the
  # sensor. Overridden rather than added, so fprintd and GNOME get it without
  # knowing anything about this device.
  libfprint = final.callPackage ../../packages/libfprint {
    libfprint = prev.libfprint;
  };

  # USB gadget daemon: composes the configfs gadget itself and switches modes
  # at runtime over usb-moded's D-Bus interface (see modules/usb-signaller).
  usb-signaller = final.callPackage ../../packages/usb-signaller { };

  # libcamera 0.7.2 with FP5 sensor tuning files from pmaports.
  # Based on https://github.com/NixOS/nixpkgs/pull/530557 (0.7.0 -> 0.7.2).
  # Adds calibrated simple-IPA profiles for:
  #   s5kjn1.yaml  - Front: Samsung S5KJN1SQ03 (Giantec GT24P128F, D-PHY)
  #   imx858.yaml  - Wide:  Sony IMX858 (Giantec GT24P128F, Dongwoon DW9800K, D-PHY)
  libcamera-fp5 = final.callPackage ../../packages/libcamera { };
}
