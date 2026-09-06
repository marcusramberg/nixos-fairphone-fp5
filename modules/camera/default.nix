# NixOS module for camera support on Fairphone 5.
#
# The camss sensors run through libcamera's soft ISP, which loads per-sensor
# tuning from <IPA config dir>/simple/<sensor model>.yaml. IPAProxy searches
# the colon-separated LIBCAMERA_IPA_CONFIG_PATH before the installed
# share/libcamera/ipa, so the FP5 profiles are injected as plain data instead
# of by overriding pkgs.libcamera — which would rebuild PipeWire, GStreamer
# and everything else linked against it.
#
# Not covered by this: the CameraSensorHelper and CameraSensorProperties
# entries (packages/libcamera patches 0001/0002) are compiled into libcamera.
# Without them the IPA logs "Failed to create camera sensor helper" and feeds
# AGC raw gain codes instead of gain multipliers.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.fairphone5.camera;

  tuning = pkgs.runCommand "libcamera-fp5-tuning" { } ''
    mkdir -p $out
    ln -s ${../../packages/libcamera/tuning} $out/simple
  '';
in
{
  options.hardware.fairphone5.camera = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.hardware.fairphone5.enable;
      description = ''
        Enable camera support for Fairphone 5.

        Points libcamera's soft ISP at the FP5 sensor tuning profiles.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # WirePlumber enumerates the libcamera device, PipeWire's spa-libcamera
    # plugin streams from it; both resolve the tuning file themselves.
    systemd.user.services.pipewire.environment = {
      "LIBCAMERA_IPA_CONFIG_PATH" = "${tuning}";
    };
    systemd.user.services.wireplumber.environment = {
      "LIBCAMERA_IPA_CONFIG_PATH" = "${tuning}";
    };

    # For apps that open libcamera directly (cam, qcam, gstreamer pipelines).
    environment.sessionVariables = {
      "LIBCAMERA_IPA_CONFIG_PATH" = "${tuning}";
    };
  };
}
