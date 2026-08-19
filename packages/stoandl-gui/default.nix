{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  blueprint-compiler,
  glib,
  gtk4,
  libadwaita,
  wrapGAppsHook4,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "stoandl-gui-gtk";
  version = "0.3.0-unstable-2026-07-28";

  src = fetchFromGitHub {
    owner = "yoxcu";
    repo = "stoandl-gui";
    rev = "af630a8b24bbbc2f450f311dcb110d43d4ff98b3";
    hash = "sha256-akLlnRK+pKEz1oHqHqnTaq5MwSa6KHozx9CtES9+wUg=";
  };

  # The crate is in gtk/, but postInstall reaches back up to the shared data/
  # tree, which is still unpacked next to it.
  sourceRoot = "${finalAttrs.src.name}/gtk";

  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [
    pkg-config
    wrapGAppsHook4
    # build.rs compiles ui/*.blp with blueprint-compiler and bundles the result
    # into a GResource with glib-compile-resources.
    blueprint-compiler
    glib
  ];

  buildInputs = [
    gtk4
    libadwaita
  ];

  postInstall = ''
    install -Dm644 ../data/de.yoxcu.stoandl.gui.gtk.desktop \
      -t "$out/share/applications"
    install -Dm644 ../data/de.yoxcu.stoandl.gui.gtk.metainfo.xml \
      -t "$out/share/metainfo"

    # This variant's app icons only; the heart action icon is already inside
    # the GResource bundle.
    find ../data/icons/hicolor -type f -name 'de.yoxcu.stoandl.gui.gtk*' \
      -printf '%P\0' \
      | while IFS= read -r -d ''' icon; do
          install -Dm644 "../data/icons/hicolor/$icon" \
            "$out/share/icons/hicolor/$icon"
        done
  '';

  meta = {
    description = "GTK4/libadwaita front-end for the stoandl Pebble companion daemon";
    homepage = "https://github.com/yoxcu/stoandl-gui";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "stoandl-gui-gtk";
  };
})
