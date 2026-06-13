# Disk image and bootloader configuration for U-Boot based booting.
#
# The Fairphone 5 boots U-Boot from the `boot` partition (see
# `packages/uboot`), which provides a UEFI environment. U-Boot's preboot maps
# the `userdata` partition as a disk, where this repart-built GPT image lives:
# an ESP with systemd-boot and the initial UKI, plus an ext4 root partition.
#
# After the initial flash, new kernels and generations are installed to the
# ESP by `nixos-rebuild` like on any UEFI system - no fastboot required.
#
# Ported from https://github.com/not-matthias/nixos-qcm6490 (devices/fairphone-fp5/repart.nix).
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  efiArch = pkgs.stdenv.hostPlatform.efiArch;

  # Nix database registration for the store paths baked into the image,
  # consumed by `boot.postBootCommands` on first boot (see `default.nix`).
  closureInfo = pkgs.closureInfo {
    rootPaths = [ config.system.build.toplevel ];
  };
in
{
  imports = [ "${modulesPath}/image/repart.nix" ];

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  # Grow the root partition and filesystem to fill the userdata partition on
  # first boot (the image is built minimized).
  systemd.repart.enable = true;
  systemd.repart.partitions."03-root".Type = "root";
  boot = {
    # systemd-boot on the ESP, chain-loaded from U-Boot's UEFI environment.
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = false;
    };
    initrd.supportedFilesystems.ext4 = true;

    # The GPT disk image lives *inside* the `userdata` partition of the phone's
    # UFS GPT. Linux does not scan partition tables nested inside partitions, so
    # the inner ESP/root partitions would never appear. Expose them by attaching
    # the userdata partition to a loop device with partition scanning, mirroring
    # what U-Boot's blkmap preboot does for the bootloader side.
    # The loop device must use 4096-byte sectors to match the image's GPT
    # (and UFS logical block size); the 512-byte default would make the nested
    # partition table unparseable.
    initrd = {
      availableKernelModules = [ "loop" ];
      # The udev rules text is not scanned for store references when building the
      # initrd, so losetup must be pulled in explicitly.
      systemd.initrdBin = [ pkgs.util-linux ];
      services.udev.rules = ''
        SUBSYSTEM=="block", ACTION=="add", ENV{ID_PART_ENTRY_NAME}=="userdata", RUN+="${pkgs.util-linux}/bin/losetup --partscan --find --nooverlap --sector-size 4096 --loop-ref userdata /dev/%k"
      '';
    };
  };

  image.repart = {
    name = "image";
    # UFS storage uses 4096-byte logical blocks.
    sectorSize = 4096;

    partitions = {
      # Padding so the ESP does not start at the very beginning of the
      # userdata partition.
      "00-padding" = {
        repartConfig = {
          Type = "linux-generic";
          SizeMinBytes = "15M";
          SizeMaxBytes = "15M";
        };
      };

      "10-esp" = {
        contents = {
          "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
            "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
          "/EFI/Linux/${config.system.boot.loader.ukiFile}".source =
            "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
          "/EFI/EDK2-UEFI-SHELL/SHELL.EFI".source = "${pkgs.edk2-uefi-shell}/shell.efi";
          "/loader/loader.conf".source = pkgs.writeText "loader.conf" ''
            timeout 5
            console-mode keep
          '';
          "/loader/entries/shell.conf".source = pkgs.writeText "shell.conf" ''
            title  EDK2 UEFI Shell
            efi    /EFI/EDK2-UEFI-SHELL/SHELL.EFI
          '';
        };
        repartConfig = {
          Type = "esp";
          Format = "vfat";
          Label = "ESP";
          FileSystemSectorSize = 4096;
          SizeMinBytes = "500M";
          GrowFileSystem = true;
        };
      };

      "20-root" = {
        storePaths = [ config.system.build.toplevel ];
        contents = {
          # Mount point for the ESP.
          "/boot".source = pkgs.runCommand "boot" { } "mkdir $out";
          "/nix-path-registration".source = "${closureInfo}/registration";
        };
        repartConfig = {
          Type = "root";
          Format = "ext4";
          # Must match `fileSystems."/".device` in `default.nix`.
          Label = "nixos";
          FileSystemSectorSize = 4096;
          Minimize = "guess";
          GrowFileSystem = true;
        };
      };
    };
  };
}
