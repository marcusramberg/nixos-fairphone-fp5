{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:

stdenvNoCC.mkDerivation {
  pname = "alsa-ucm-conf-fairphone-fp5";
  version = "1.0";

  src = fetchFromGitHub {
    owner = "sc7280-mainline";
    repo = "alsa-ucm-conf";
    rev = "9d5563e6456e1a35e2d59c59130c50b2bbfe3c94";
    hash = "sha256-8OOOzG354x/qmLwQv91C/RrQdZ2L1OyI3Q27/bgmoi0=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    # Install the full ucm2 tree from sc7280-mainline fork
    # (includes Fairphone/fp5/ and conf.d/qcm6490/Fairphone 5.conf)
    mkdir -p $out/share/alsa/
    cp -r ucm2 $out/share/alsa/
    runHook postInstall
  '';

  meta = {
    description = "ALSA UCM2 profiles for Fairphone 5";
    longDescription = ''
      Device-specific ALSA Use Case Manager configuration for the
      Fairphone 5 (Qualcomm QCM6490). Provides HiFi quality playback
      and microphone capture configurations.

      Fork of alsa-ucm-conf from sc7280-mainline with Fairphone 5 support.
    '';
    homepage = "https://github.com/sc7280-mainline/alsa-ucm-conf";
    license = lib.licenses.bsd3;
    maintainers = [ ];
    platforms = lib.platforms.linux;
  };
}
