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
  phoc,
  gsettings-desktop-schemas,
  gnome-settings-daemon,
  gnome-shell,
  mutter,
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

    # GSettings schemas libphosh opens at startup, and aborts without:
    #   org.gnome.desktop.*                    gsettings-desktop-schemas
    #   org.gnome.settings-daemon.plugins.power,
    #   org.gnome.settings-daemon.peripherals.touchscreen
    #                                          gnome-settings-daemon
    #   org.gnome.mutter.*                     mutter
    #   sm.puri.phoc                           phoc
    # glib's setup hook puts each one on GSETTINGS_SCHEMAS_PATH, which
    # wrapGAppsHook3 turns into the wrapper's XDG_DATA_DIRS.
    gsettings-desktop-schemas
    gnome-settings-daemon
    mutter
    phoc
  ];

  # build.rs writes the compiled schema under $HOME, which the sandbox lacks.
  preBuild = ''
    export HOME="$(mktemp -d)"
  '';

  # The suite needs a live phoc, a session bus and accountsservice.
  doCheck = false;

  # org.gnome.shell.keybindings; gnome-shell is schemas-only here, so keep it
  # out of buildInputs (this is what phosh itself does).
  preFixup = ''
    gappsWrapperArgs+=(
      --prefix XDG_DATA_DIRS : "${glib.getSchemaDataDirPath gnome-shell}"
    )
  '';

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
