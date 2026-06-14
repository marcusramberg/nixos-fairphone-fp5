{
  description = "NixOS on Fairphone 5";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      # Builds the U-Boot boot image that is flashed to the `boot` partition
      # once using fastboot. U-Boot then provides a UEFI environment that
      # chain-loads systemd-boot from the ESP inside the disk image on the
      # `userdata` partition; kernel/generation updates afterwards happen via
      # `nixos-rebuild`, not fastboot.
      mkUbootImage =
        pkgs:
        let
          uboot = pkgs.uboot-fairphone-fp5 or (pkgs.callPackage ./packages/uboot { });
        in
        pkgs.runCommand "uboot.img"
          {
            nativeBuildInputs = with pkgs; [ android-tools ];
          }
          ''
            # Package U-Boot as the "kernel" of an Android boot image, which is
            # what the Fairphone 5's stock (aboot) bootloader expects to load.
            cp ${uboot}/u-boot-nodtb.bin ./u-boot-nodtb.bin
            cp ${uboot}/qcm6490-fairphone-fp5.dtb ./qcm6490-fairphone-fp5.dtb
            gzip ./u-boot-nodtb.bin

            mkbootimg \
              --header_version 2 \
              --kernel ./u-boot-nodtb.bin.gz \
              --dtb ./qcm6490-fairphone-fp5.dtb \
              --base 0x00000000 \
              --kernel_offset 0x00008000 \
              --ramdisk_offset 0x01000000 \
              --second_offset 0x00000000 \
              --tags_offset 0x00000100 \
              --pagesize 4096 \
              -o "$out"
          '';

      # Builds the GPT disk image (ESP + root) that is flashed to the
      # `userdata` partition using fastboot. Built by systemd-repart via the
      # configuration in `modules/hardware/disk-image.nix`.
      mkDiskImage = nixosConfig: nixosConfig.config.system.build.image;
    in
    flake-utils.lib.eachSystem [ "aarch64-linux" ] (
      system:
      let
        # Nixpkgs for building test images.
        exampleConfigPkgs = import nixpkgs {
          inherit system;

          config = {
            allowUnfree = true;
            # FIXME: This is needed because of `chatty`, which supports Matrix and therefore
            # unfortunately includes a dependency on `olm`, which is currently marked as
            # insecure. This should be removed or fixed ASAP.
            permittedInsecurePackages = [
              "olm-3.2.16"
            ];
          };
        };

        # NixOS configurations for building example images for testing.
        exampleNixosConfigurations = {
          gnome-mobile = nixpkgs.lib.nixosSystem {
            inherit system;

            modules = [ ./hosts/gnome-mobile ];
            pkgs = exampleConfigPkgs;
          };
          minimal = nixpkgs.lib.nixosSystem {
            inherit system;

            modules = [ ./hosts/minimal ];
            pkgs = exampleConfigPkgs;
          };
        };
      in
      {
        # Example images built from internal host configs for testing.
        packages =
          nixpkgs.lib.foldlAttrs (
            acc: name: nixosConfig:
            acc
            // {
              "disk-image-${name}" = mkDiskImage nixosConfig;
            }
          ) { } exampleNixosConfigurations
          // {
            # U-Boot boot image; configuration-independent, flashed once.
            uboot-image = mkUbootImage exampleConfigPkgs;
          };
      }
    )
    // {
      # Reusable library functions.
      lib = {
        inherit mkUbootImage mkDiskImage;
      };

      # NixOS modules for external consumption.
      nixosModules = {
        minimal = {
          imports = [
            ./modules/bootmac
            ./modules/hardware
            ./modules/modem
            ./modules/qbootctl
          ];
        };

        gnome-mobile = {
          imports = [
            ./modules/bootmac
            ./modules/hardware
            ./modules/modem
            ./modules/gnome-mobile
            ./modules/qbootctl
          ];
        };

        # Export `gnome-mobile` as the default module.
        default = {
          imports = [
            ./modules/bootmac
            ./modules/hardware
            ./modules/modem
            ./modules/gnome-mobile
            ./modules/qbootctl
          ];
        };
      };

      # Separate overlays for more custom use cases.
      overlays =
        let
          fairphone-fp5 = import ./overlays/fairphone-fp5;
        in
        {
          inherit fairphone-fp5;

          # Export `fairphone-fp5` as the default overlay.
          default = fairphone-fp5;
        };
    };
}
