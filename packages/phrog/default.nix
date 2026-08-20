{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  glib,
  atk,
  cairo,
  gdk-pixbuf,
  gtk3,
  libhandy,
  pango,
  wayland,
  phosh,
  gsettings-desktop-schemas,
  wrapGAppsHook3,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "phrog";
  version = "0.53.0";

  src = fetchFromGitHub {
    owner = "samcday";
    repo = "phrog";
    tag = finalAttrs.version;
    hash = "sha256-ojr5k6eYONMNDk/DwWU6RxCDv9TrnUskFqL+2X0DIT0=";
  };

  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [
    pkg-config
    wrapGAppsHook3
    glib
  ];

  buildInputs = [
    atk
    cairo
    gdk-pixbuf
    glib
    gtk3
    libhandy
    pango
    wayland
    # libphosh-0.45.pc, from phosh's -Dbindings-lib=true. The pkg-config name
    # is pinned to the stable libphosh API version, not phosh's own version.
    phosh
    gsettings-desktop-schemas
  ];

  # build.rs writes the compiled schema under $HOME, which the sandbox lacks.
  preBuild = ''
    export HOME="$(mktemp -d)"
  '';

  # The suite needs a live phoc, a session bus and accountsservice.
  doCheck = false;

  postInstall = ''
    install -Dm644 -t "$out/share/glib-2.0/schemas" \
      data/mobi.phosh.phrog.gschema.xml
    glib-compile-schemas "$out/share/glib-2.0/schemas"

    install -Dm644 -t "$out/share/applications" data/mobi.phosh.Phrog.desktop
    install -Dm644 -t "$out/share/gnome-session/sessions" data/phrog.session
    install -Dm644 -t "$out/share/systemd/user" \
      data/mobi.phosh.Phrog.service \
      data/mobi.phosh.Phrog.target
    install -Dm644 data/systemd-session.conf \
      "$out/share/systemd/user/gnome-session@phrog.target.d/session.conf"
  '';

  meta = {
    description = "Mobile-friendly greeter for greetd, built on Phosh";
    homepage = "https://github.com/samcday/phrog";
    changelog = "https://github.com/samcday/phrog/releases/tag/${finalAttrs.version}";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "phrog";
  };
})
