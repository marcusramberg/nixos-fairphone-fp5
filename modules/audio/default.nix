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
  cfg = config.hardware.fairphone5.audio;

  ucm = pkgs.alsa-ucm-conf-fairphone-fp5;

  # Decides which UCM tree /run/alsa-ucm2 points at, and — when the answer
  # changed — makes PipeWire's ACP re-probe it.
  #
  # The re-probe is done by re-announcing the sound card to udev (remove then
  # add), *not* by restarting WirePlumber. ACP only reads the UCM tree when it
  # creates the device, but a udev remove/add cycle recreates exactly that
  # object while the daemon keeps running: clients keep their PipeWire
  # connection and merely see a sink go away and come back, which is the same
  # thing that happens when a USB DAC is unplugged. Restarting WirePlumber
  # instead is what produced most of the trouble on this device — clients such
  # as Blanket and FreeTube end up wedged with no streams registered, and the
  # ADSP leaks buffers on every open/close cycle until nothing can play at all
  # (see docs/displayport-audio.md).
  #
  # The deciding signal is the ELD, not the connector status: a connector can
  # read "connected" while the link is still training or while its mode list is
  # the fallback set, and enabling the DP UCM tree in that window produces a
  # DisplayPort sink whose AFE port never starts ("AFE enable for port 0x6020
  # failed -110") — or, worse, one that silently keeps playing out of the
  # speaker. A populated ELD with sad_count >= 1 means the link is up *and* the
  # sink advertises audio (on the XREAL One that is its "DP audio" menu option;
  # with it off the EDID has no CEA block and no SADs at all).
  #
  # udev fires on `change` well before any of that settles — and it fires in
  # bursts (a single plug of the XREAL produced seven events in ten seconds, as
  # alt-mode negotiation flaps the connector). So: first wait for the connector
  # status to hold still, and only then wait on the ELD.
  dpAudioSwitch = pkgs.writeShellScript "fp5-dp-audio-switch" ''
    set -u
    conn=/sys/class/drm/card0-DP-1
    eld=/proc/asound/card0/eld#4
    tree=${ucm}/share/alsa/ucm2

    # Watch for up to ~30s rather than sampling once. udev fires at the start
    # of the plug, but the link may only train seconds later — and once the
    # event burst is over there is no further event to re-evaluate on. The
    # XREAL One trains well after its last udev event; a plain monitor beats
    # the window. Sampling once means the glasses are permanently misjudged as
    # "no DP audio", which is the whole bug this loop exists to avoid.
    #
    # Asymmetric on purpose:
    #   * DP wins as soon as the link is up AND the ELD lists audio;
    #   * no-DP is only concluded after the connector has read disconnected
    #     continuously for ~5s, so a mid-plug flap cannot settle the answer;
    #   * a connector that stays connected without ever producing an ELD is a
    #     video-only sink, and falls through to no-DP when the window expires.
    down=0
    for _ in $(seq 60); do
      if [ "$(cat $conn/status 2>/dev/null || true)" = "connected" ]; then
        down=0
        if grep -qE '^sad_count[[:space:]]+[1-9]' "$eld" 2>/dev/null; then
          tree=${ucm}/share/alsa/ucm2-dp
          break
        fi
      else
        down=$((down + 1))
        [ "$down" -ge 10 ] && break
      fi
      sleep 0.5
    done

    if [ "$(readlink /run/alsa-ucm2 || true)" = "$tree" ]; then
      exit 0
    fi

    # A re-probe can come up empty: the DP link is still settling (the XREAL
    # flaps xhci and the QMP PHY for seconds after the ELD appears), ACP's
    # open of hw:F5,0 fails with
    #
    #   spa.alsa: '_ucm0029.hw:F5,0': playback open failed: Invalid argument
    #
    # because MultiMedia1 has no usable backend yet, and the node is never
    # created. Nothing retries: the card object exists with no sink at all, so
    # everything lands on Dummy Output — including the speaker, since the DP
    # tree puts Speaker and HDMI on the same PCM. Recovery took another
    # hotplug. So verify that the probe actually produced an ALSA sink, and
    # re-trigger if it did not.
    #
    # The check is done against PipeWire itself rather than by test-opening the
    # PCM here: a test open would race the sink PipeWire may already have open
    # (EBUSY reads as failure), and every extra open/close cycle costs ADSP
    # buffers that are never returned.
    have_alsa_sink() {
      for rt in /run/user/*; do
        [ -S "$rt/pipewire-0" ] || continue
        if XDG_RUNTIME_DIR="$rt" pw-dump 2>/dev/null | grep -q '"alsa_output'; then
          return 0
        fi
      done
      return 1
    }

    reprobe() {
      ln -sfnT "$1" /run/alsa-ucm2
      udevadm trigger --action=remove /sys/class/sound/card0
      sleep 2
      udevadm trigger --action=add /sys/class/sound/card0
      # ACP probes every profile of the card; on this device the sink shows up
      # within ~3s of the add when it shows up at all.
      sleep 5
      have_alsa_sink
    }

    for _ in 1 2 3; do
      reprobe "$tree" && exit 0
    done

    # Still no sink. If we were reaching for DP, fall back to the no-DP tree so
    # the speaker works instead of leaving the user on Dummy Output; the next
    # hotplug will try DP again.
    if [ "$tree" != "${ucm}/share/alsa/ucm2" ]; then
      reprobe ${ucm}/share/alsa/ucm2
    fi
  '';
in
{
  options.hardware.fairphone5.audio = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.hardware.fairphone5.enable;
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
      wireplumber.configPackages = [ pkgs.wireplumber-qcom ];
    };

    # Set ALSA_CONFIG_UCM2 so that PipeWire/WirePlumber can find our
    # Fairphone 5 UCM2 config (merged with upstream alsa-ucm-conf).
    # Without this, alsa-lib uses its hardcoded datadir which doesn't
    # include our F5/ directory.
    #
    # This is the mutable /run symlink, not a store path directly: it is
    # repointed at the DisplayPort-enabled tree while DP is connected (see
    # fp5-dp-audio-switch below).
    systemd.user.services.pipewire.environment = {
      "ALSA_CONFIG_UCM2" = "/run/alsa-ucm2";
    };
    systemd.user.services.wireplumber.environment = {
      "ALSA_CONFIG_UCM2" = "/run/alsa-ucm2";
    };

    # Default to the no-DP tree; the switch unit corrects it at boot and on
    # every hotplug.
    systemd.tmpfiles.rules = [
      "L /run/alsa-ucm2 - - - - ${ucm}/share/alsa/ucm2"
    ];

    # DRM hotplug (glasses plugged/unplugged, or DP audio toggled in their
    # menu, which re-reads the EDID) re-evaluates which tree to use.
    services.udev.extraRules = ''
      ACTION=="change", SUBSYSTEM=="drm", ENV{DEVNAME}=="/dev/dri/card0", TAG+="systemd", ENV{SYSTEMD_WANTS}+="fp5-dp-audio-switch.service"
    '';

    systemd.services.fp5-dp-audio-switch = {
      description = "Select ALSA UCM tree for DisplayPort audio";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];

      # cat/seq/sleep/readlink/ln, grep, udevadm and pw-dump: units get no PATH
      # of their own.
      path = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.systemd
        pkgs.pipewire
      ];

      # A plug event arrives as a burst. Without this, systemd refuses the last
      # (and only correct) start of the burst with "start request repeated too
      # quickly" and the tree stays wrong until the next hotplug.
      startLimitIntervalSec = 0;

      serviceConfig = {
        Type = "oneshot";
        ExecStart = dpAudioSwitch;
      };
    };
  };
}
