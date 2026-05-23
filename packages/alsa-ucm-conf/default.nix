{
  coreutils,
  fetchFromGitHub,
  kmod,
  lib,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "alsa-ucm-conf";
  version = "9d5563e6456e1a35e2d59c59130c50b2bbfe3c94";

  # Fork of alsa-ucm-conf with Qualcomm SC7280/Fairphone 5 support.
  src = fetchFromGitHub {
    owner = "sc7280-mainline";
    repo = "alsa-ucm-conf";
    rev = "9d5563e6456e1a35e2d59c59130c50b2bbfe3c94";
    hash = "sha256-8OOOzG354x/qmLwQv91C/RrQdZ2L1OyI3Q27/bgmoi0=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    # Patch hardcoded paths to use nix store binaries.
    substituteInPlace ucm2/lib/card-init.conf \
      --replace-fail "/bin/rm" "${coreutils}/bin/rm" \
      --replace-fail "/bin/mkdir" "${coreutils}/bin/mkdir"
    substituteInPlace ucm2/common/ctl/led.conf \
      --replace-fail "/sbin/modprobe" "${kmod}/bin/modprobe"

    mkdir -p $out/share/alsa
    cp -r ucm ucm2 $out/share/alsa

    runHook postInstall
  '';

  meta = {
    description = "ALSA Use Case Manager configuration files with Qualcomm SC7280/Fairphone 5 support";
    longDescription = ''
      Fork of the upstream alsa-ucm-conf package that includes device-specific
      UCM2 profiles for Qualcomm SC7280 platforms, including the Fairphone 5.
      Provides HiFi quality playback and microphone capture configurations.
    '';
    homepage = "https://github.com/sc7280-mainline/alsa-ucm-conf";
    license = lib.licenses.gpl2Only;
    maintainers = [];
    platforms = lib.platforms.linux;
  };
}
