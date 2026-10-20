# Userspace tool that writes the Apple SMC BCLM/BFCL keys (battery charge limit) on Intel MacBooks.
# Upstream: https://github.com/jtbrough/macbook-charge-limit  (MIT). Upstream tested it on a
# MacBookAir6,2 only; verified working on a MacBookPro10,1 (see ../power-tlp.nix).
{ lib, stdenv, fetchFromGitHub }:

stdenv.mkDerivation {
  pname = "macbook-charge-limit";
  version = "unstable-9bb39ab4";

  src = fetchFromGitHub {
    owner = "jtbrough";
    repo = "macbook-charge-limit";
    rev = "9bb39ab4ee03f59688cd36e3695b0a0ea8c25e2e";
    hash = "sha256-zbtw4PsjvCg9ACvKI+9trgkhJwI5hE/kt6KfBVB+AdM=";
  };

  # `make` builds the binary. Upstream's `make install` writes into /usr/local and /etc, which
  # does not fit NixOS, so install the binary by hand.
  installPhase = ''
    runHook preInstall
    bin="$(find . -maxdepth 2 -type f -name macbook-charge-limit -perm -u+x | head -n 1)"
    install -Dm755 "$bin" "$out/bin/macbook-charge-limit"
    runHook postInstall
  '';

  meta = {
    description = "Set an Intel MacBook battery charge limit via the Apple SMC BCLM/BFCL keys";
    homepage = "https://github.com/jtbrough/macbook-charge-limit";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "macbook-charge-limit";
  };
}
