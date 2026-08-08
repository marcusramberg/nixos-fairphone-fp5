{
  fetchgit,
  lib,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "focal32-firmware";
  # No versioned releases; the image is whatever the device shipped with.
  version = "2.5.3.0-cdf0f80-230614";

  src = fetchgit {
    url = "https://code.bas.es/marcus/fp5-fingerprint-firmware";
    rev = "6eecceae7b314d15006d211713806de507368cab";
    hash = "sha256-zmQ7YCtTM/2L9DkyQqFlsB9Iqszuu7i92k3EZzDn8Jg=";
  };

  dontConfigure = true;
  dontBuild = true;

  # Deliberately *not* squashed with pil-squasher, unlike everything in
  # packages/firmware. The QSEECOM TEE driver loads a trusted application by
  # asking request_firmware() for <name>.mdt and then each .bNN segment, and
  # assembles them itself; a single .mbn is not what it looks for.
  installPhase = ''
    runHook preInstall
    install -Dm644 -t $out/lib/firmware focal32.mdt focal32.b0[0-7]
    runHook postInstall
  '';

  meta = {
    description = "FocalTech FT9362 fingerprint trusted application for the Fairphone 5";
    longDescription = ''
      The signed TrustZone application ("focal32") that owns the Fairphone 5's
      fingerprint sensor: it drives the SPI bus, captures images, and does the
      templating and matching inside the secure world. Extracted from the
      device's stock firmware, since it ships in no public firmware set --
      FairBlobs/FP5-firmware carries the DSP, modem and GPU images but no
      trusted applications.

      Split form (.mdt plus .b00 ... .b07), which is what the QSEECOM TEE
      driver expects to load.
    '';
    homepage = "https://code.bas.es/marcus/fp5-fingerprint-firmware";
    license = lib.licenses.unfree;
    platforms = [ "aarch64-linux" ];
  };
}
