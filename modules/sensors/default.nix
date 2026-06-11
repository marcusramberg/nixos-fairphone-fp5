# Sensor (accelerometer/orientation) support for Fairphone 5.
#
# The sensors are not on a kernel-visible bus: they hang off the ADSP's
# sensors protection domain (SSC). Userspace reaches them through libssc over
# FastRPC (/dev/fastrpc-adsp), which requires:
# - hexagonrpcd-adsp-sensorspd serving the HexagonFS sensor registry
#   (see modules/audio/default.nix, enabled by default),
# - iio-sensor-proxy built with the SSC backend (see the overlay), which then
#   exposes orientation to desktops over D-Bus as usual.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixos-fairphone-fp5.sensors;
in
{
  options.nixos-fairphone-fp5.sensors = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable sensor support (accelerometer/screen rotation) for Fairphone 5
        via iio-sensor-proxy with the Qualcomm SSC backend.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Runs iio-sensor-proxy (with the SSC backend via our overlay).
    hardware.sensor.iio.enable = true;

    # If iio-sensor-proxy starts before the ADSP has booted and registered
    # the sensor service on QRTR, it exits cleanly with "No sensors or
    # missing kernel drivers". Keep restarting until the sensors are there.
    systemd.services.iio-sensor-proxy = {
      after = [ "hexagonrpcd-adsp-sensorspd.service" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;
      };
    };

    # iio-sensor-proxy's own udev rules only tag the fastrpc device with
    # "ssc-light ssc-compass"; without the ssc-accel tag the accelerometer
    # driver is never probed (HasAccelerometer stays false, orientation
    # "undefined"). Add the accelerometer and proximity types, plus the
    # accelerometer mount matrix ported from postmarketOS
    # (device-fairphone-fp5, 81-libssc-fairphone-fp5.rules).
    services.udev.extraRules = ''
      SUBSYSTEM=="misc", KERNEL=="fastrpc-adsp*", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-accel ssc-proximity"
      SUBSYSTEM=="misc", KERNEL=="fastrpc-*", ENV{ACCEL_MOUNT_MATRIX}+="-1, 0, 0; 0, -1, 0; 0, 0, -1"
    '';
  };
}
