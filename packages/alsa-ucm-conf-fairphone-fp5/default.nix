{
  lib,
  stdenvNoCC,
  alsa-ucm-conf,
}:

stdenvNoCC.mkDerivation {
  pname = "alsa-ucm-conf-fairphone-fp5";
  version = "1.0";

  src = ./.;

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    # Copy upstream ucm2 configs (includes ucm.conf, Qualcomm/, etc.)
    cp -r ${alsa-ucm-conf}/share/alsa/ucm2/* $out/share/alsa/ucm2/
    # Overlay our Fairphone 5 F5 config on top
    cp -r ucm2/* $out/share/alsa/ucm2/
    runHook postInstall
  '';

  meta = {
    description = "ALSA UCM2 profiles for Fairphone 5";
    longDescription = ''
      Device-specific ALSA Use Case Manager configuration for the
      Fairphone 5 (Qualcomm QCM6490). Provides HiFi quality playback
      and microphone capture configurations.
    '';
    homepage = "https://github.com/sc7280-mainline/alsa-ucm-conf";
    license = lib.licenses.bsd3;
    maintainers = [];
    platforms = lib.platforms.linux;
  };
}
