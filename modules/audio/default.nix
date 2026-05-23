# NixOS module for audio support on Fairphone 5.
#
# This module enables audio playback and capture on the Fairphone 5 using the
# Qualcomm QCM6490 audio subsystem. It sets up:
# - hexagonrpcd: FastRPC server for ADSP (audio DSP) firmware loading.
# - PipeWire + WirePlumber: Audio server with Qualcomm-specific configuration.
# - alsa-ucm-conf-fairphone-fp5: UCM2 profiles for Fairphone 5 sound card.
# - wireplumber-qcom: WirePlumber config for QCOM audio format/rate settings.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixos-fairphone-fp5.audio;
in
{
  options.nixos-fairphone-fp5.audio = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable audio support for Fairphone 5.

        This sets up the necessary services for audio playback and capture:
        hexagonrpcd (ADSP firmware server), PipeWire, and WirePlumber with
        Qualcomm-specific configuration.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Install audio packages.
    environment.systemPackages = with pkgs; [
      alsa-ucm-conf-fairphone-fp5 # UCM2 profiles for Fairphone 5 (includes upstream alsa-ucm-conf).
      wireplumber-qcom # WirePlumber config for QCOM audio.
    ];

    # hexagonrpcd: FastRPC server for ADSP (audio DSP).
    # Required for the Qualcomm audio DSP to load and run firmware.
    systemd.services.hexagonrpcd-adsp-sensorspd = {
      description = "Qualcomm ADSP FastRPC server (sensorspd)";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.hexagonrpc}/bin/hexagonrpcd -f /dev/fastrpc-adsp -d adsp -s";

        Restart = "on-failure";
        RestartSec = "3";
      };
    };

    # WirePlumber config: install Qualcomm audio configuration files.
    # 51-qcom.conf: Sets S16LE format, 48kHz rate, period parameters for all QCOM nodes.
    # 52-fairphone-fp5.conf: Overrides to S32LE for Fairphone 5 sinks.
    environment.etc = {
      "wireplumber/wireplumber.conf.d/51-qcom.conf" = {
        source = "${pkgs.wireplumber-qcom}/share/wireplumber/wireplumber.conf.d/51-qcom.conf";
      };
      "wireplumber/wireplumber.conf.d/52-fairphone-fp5.conf" = {
        source = "${pkgs.wireplumber-qcom}/share/wireplumber/wireplumber.conf.d/52-fairphone-fp5.conf";
      };
    };

    # Enable PipeWire for audio.
    services.pulseaudio.enable = lib.mkForce false;
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;

      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    # Set ALSA_CONFIG_UCM2 so that PipeWire/WirePlumber can find our
    # Fairphone 5 UCM2 config (merged with upstream alsa-ucm-conf).
    # Without this, alsa-lib uses its hardcoded datadir which doesn't
    # include our F5/ directory.
    systemd.user.services.pipewire.environment = {
      "ALSA_CONFIG_UCM2" = "${pkgs.alsa-ucm-conf-fairphone-fp5}/share/alsa/ucm2";
    };
    systemd.user.services.wireplumber.environment = {
      "ALSA_CONFIG_UCM2" = "${pkgs.alsa-ucm-conf-fairphone-fp5}/share/alsa/ucm2";
    };
  };
}
