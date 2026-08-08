{
  lib,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "ffsupplicant";
  version = "0.1.0";

  src = ./.;

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -o ffsupplicant ffsupplicant.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 ffsupplicant $out/bin/ffsupplicant
    runHook postInstall
  '';

  meta = {
    description = "QSEECOM listener supplicant, so trusted applications can reach their secure storage";
    longDescription = ''
      A QSEE application that needs to read or write a secure object blocks
      until the normal world answers it. The focal32 fingerprint application
      does this for everything it persists -- templates, calibration, its
      serial id -- so with nothing serving those requests it cannot enrol a
      finger at all.

      This registers listener services on /dev/teepriv0 and answers their
      requests. It is not trusted with anything: objects are encrypted,
      integrity-protected and, for RPMB, authenticated by the secure world
      before they ever cross this boundary, which is why the I/O can be
      delegated to an ordinary process.

      Work in progress. The fingerprint application's storage turns out to go
      to RPMB (listener 0x2000) rather than to a file service: the path in its
      error messages names an object inside TrustZone's own filesystem layer,
      not a file the normal world is asked to open. Serving RPMB means relaying
      512-byte frames -- which the secure world builds and MACs itself -- to
      the UFS RPMB well-known LUN, reachable at /dev/bsg/0:0:0:49476. That
      relay is not implemented yet; today this registers services, answers the
      gpfile probe, and dumps whatever else arrives.

      Needs root, for /dev/teepriv0.
    '';
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
    mainProgram = "ffsupplicant";
  };
}
