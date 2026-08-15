{
  lib,
  rustPlatform,
  fetchFromGitea,
  pkg-config,
  systemd,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "usb-signaller";
  version = "0.4.2";

  src = fetchFromGitea {
    domain = "codeberg.org";
    owner = "DylanVanAssche";
    repo = "usb-signaller";
    tag = "v${finalAttrs.version}";
    hash = "sha256-c4wI6sHHiCad18t62dD9SEgdmoo0S+BO22wUGytIJ0Q=";
  };

  cargoLock.lockFile = ./Cargo.lock;

  patches = [
    # fix systemd detection on nixos
    ./nixos-init-detection.patch
    # survive dwc3 unregistering its UDC on a switch to host role
    ./udc-gone-is-not-attached.patch
  ];

  postPatch = ''
    substituteInPlace src/service.rs \
      --replace-fail "@systemctl@" "${systemd}/bin/systemctl"
  '';

  nativeBuildInputs = [ pkg-config ];

  # tokio-udev -> libudev
  buildInputs = [ systemd ];

  # fails under sandbox
  checkFlags = [
    "--skip=sysfs::tests::mkdir_path_already_exists"
    "--skip=sysfs::tests::symlink_destination_path_already_exists"
  ];

  postInstall = ''
    install -Dm644 com.meego.usb_moded.conf \
      -t $out/share/dbus-1/system.d
  '';

  meta = {
    description = "usb-moded-compatible USB gadget daemon for mainline Linux Mobile devices";
    homepage = "https://codeberg.org/DylanVanAssche/usb-signaller";
    license = lib.licenses.gpl3Plus;
    mainProgram = "usb-signaller";
    maintainers = [ "marcusramberg" ];
    platforms = lib.platforms.linux;
  };
})
