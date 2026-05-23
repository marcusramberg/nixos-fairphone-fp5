{
  lib,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "wireplumber-qcom";
  version = "1.0";

  src = ./.;

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/wireplumber/wireplumber.conf.d"
    cp 51-qcom.conf 52-fairphone-fp5.conf "$out/share/wireplumber/wireplumber.conf.d/"
    runHook postInstall
  '';

  meta = {
    description = "WirePlumber configuration for Qualcomm audio on Fairphone 5";
    longDescription = ''
      WirePlumber configuration files for Qualcomm audio platforms.
      51-qcom.conf sets audio format, rate, and period parameters for all QCOM ALSA nodes.
      52-fairphone-fp5.conf overrides audio format to S32LE for Fairphone 5 sinks.
    '';
    license = lib.licenses.mit;
    maintainers = [];
    platforms = lib.platforms.linux;
  };
}
