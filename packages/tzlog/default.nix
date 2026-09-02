{
  lib,
  stdenv,
  fp5-fingerprint-tools,
  kernel,
}:
stdenv.mkDerivation {
  pname = "qcom-tzlog";
  version = "0.1.0";

  src = "${fp5-fingerprint-tools}/tzlog";

  nativeBuildInputs = kernel.moduleBuildDependencies;

  makeFlags = [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)"
    "modules"
  ];

  installPhase = ''
    runHook preInstall
    install -Dm444 qcom_tzlog.ko \
      $out/lib/modules/${kernel.modDirVersion}/misc/qcom_tzlog.ko
    runHook postInstall
  '';

  meta = {
    description = "Read TrustZone's diagnostic and application logs";
    longDescription = ''
      QSEE keeps two logs, and without either one a trusted application that
      dies says nothing at all: the SCM call returns an error the kernel has no
      name for, and that is the whole diagnosis.

      This exposes both. /sys/kernel/debug/tzlog/raw is TrustZone's diagnostic
      area, reached through a pointer in on-chip memory rather than at the
      address the device tree names. /sys/kernel/debug/tzlog/qsee is the
      application log, which stays empty until a buffer is registered with QSEE
      -- so a fault in a trusted application is invisible to Linux until
      something asks for it.

      With the application log readable, an application names its own last
      function before it dies. That is how the FP5 fingerprint enrolment was
      unblocked: four separate faults, each of which had survived days of
      guessing, were found in hours once this existed.

      Out of tree, and a debugging aid rather than something to run in
      production: it maps memory the secure world owns and hands it to
      user space.
    '';
    license = lib.licenses.gpl2Only;
    platforms = [ "aarch64-linux" ];
    broken = kernel.kernelOlder "5.10";
  };
}
