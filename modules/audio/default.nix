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
    # hexagonrpcd: FastRPC server attached to the ADSP sensors protection
    # domain (sensorspd), serving HexagonFS files (sensor registry, socinfo)
    # to the DSP. The ADSP audio firmware itself is loaded by the kernel
    # remoteproc from /lib/firmware. pmaports runs this same single service
    # for the FP5. The -R flag must point at the full device directory
    # (<root>/<chipset>/<vendor>/<device>), not the share root: hexagonrpcd
    # normally guesses /usr/share/qcom/qcm6490/Fairphone/fp5 from the
    # devicetree compatible string, but that path does not exist on NixOS.
    systemd.services.hexagonrpcd-adsp-sensorspd = {
      description = "Qualcomm ADSP FastRPC server (sensorspd)";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.hexagonrpc}/bin/hexagonrpcd -f /dev/fastrpc-adsp -d adsp -s -R ${pkgs.firmware-fairphone-fp5}/usr/share/qcom/qcm6490/Fairphone/fp5";

        Restart = "on-failure";
        RestartSec = "3";
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

      # WirePlumber config for Qualcomm audio.
      # 51-qcom.conf: Sets S16LE format, 48kHz rate, period parameters for all QCOM nodes.
      # 52-fairphone-fp5.conf: Overrides to S32LE and enables ACP/UCM2 for the
      # Fairphone 5 card, so the UCM HiFi verb and device EnableSequences set
      # up the DPCM routing (BE DAI mixer switches) and mic codec routing.
      wireplumber.configPackages = [ pkgs.wireplumber-qcom ];
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

    # Workaround for a probe race: the LPASS LPI pinctrl's clocks are provided
    # by the ADSP (via q6prm over GLINK). If the pinctrl probes before the
    # ADSP remoteproc has booted, clock enable fails with -ETIMEDOUT, the
    # probe fails permanently (not deferred), and the whole sound card stays
    # stuck in deferred probe. Wait for the ADSP and rebind the pinctrl if it
    # is not bound; the deferred sound card probe then cascades automatically.
    systemd.services.lpass-pinctrl-rebind = {
      description = "Rebind LPASS LPI pinctrl after ADSP is up";
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        driver=/sys/bus/platform/drivers/qcom-sc7280-lpass-lpi-pinctrl
        device=33c0000.pinctrl

        # Wait up to 60s for the ADSP remoteproc to be running.
        for i in $(seq 1 60); do
          for rp in /sys/class/remoteproc/remoteproc*; do
            [ "$(cat "$rp/name" 2>/dev/null)" = "adsp" ] || continue
            if [ "$(cat "$rp/state" 2>/dev/null)" = "running" ]; then
              if [ ! -e "$driver/$device" ]; then
                echo "ADSP up, rebinding LPASS LPI pinctrl..."
                echo "$device" > "$driver/bind"
              else
                echo "LPASS LPI pinctrl already bound, nothing to do."
              fi
              exit 0
            fi
          done
          sleep 1
        done

        echo "ADSP did not come up within 60s; not rebinding." >&2
        exit 1
      '';
    };
  };
}
