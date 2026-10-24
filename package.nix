{
  lib,
  stdenvNoCC,
  makeWrapper,
  curl,
  jq,
  coreutils,
  gawk,
  gnused,
  ncurses,
  # Where the source comes from. The flake passes itself in; non-flake users
  # pass a downloaded copy (see README). Default: the folder this file is in.
  src ? lib.cleanSource ./.,
}:

let
  versionLine = lib.findFirst (l: lib.hasPrefix "VERSION=" l) "" (
    lib.splitString "\n" (builtins.readFile (src + "/ai.sh"))
  );
  stamped = lib.removeSuffix "\"" (lib.removePrefix "VERSION=\"" versionLine);
  version = if stamped == "" || stamped == "dev" then "unstable" else stamped;
in
stdenvNoCC.mkDerivation {
  pname = "ai-sh";
  inherit version src;

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 ai.sh $out/bin/ai.sh

    # Tell the script it came from Nix, so "ai.sh --update" explains how Nix
    # updates it instead of trying to overwrite a read-only store file.
    substituteInPlace $out/bin/ai.sh \
      --replace-fail 'INSTALL_METHOD="script"' 'INSTALL_METHOD="nix"'

    # Make sure the tools the script needs exist, without overriding the user's own.
    wrapProgram $out/bin/ai.sh \
      --suffix PATH : ${
        lib.makeBinPath [
          curl
          jq
          coreutils
          gawk
          gnused
          ncurses
        ]
      }

    # Short alias
    ln -s ai.sh $out/bin/ai

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/ai.sh --version
    runHook postInstallCheck
  '';

  meta = {
    description = "POSIX sh AI assistant for your terminal (Anthropic, OpenAI, Ollama)";
    homepage = "https://github.com/snapsettle/ai.sh";
    mainProgram = "ai.sh";
    platforms = lib.platforms.unix;
  };
}
