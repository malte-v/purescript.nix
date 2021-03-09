{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    haskell-nix.url = "github:input-output-hk/haskell.nix";
  };
  outputs = { self, flake-utils, haskell-nix, ... }: flake-utils.lib.eachDefaultSystem (
    system:
      let
        pkgs = haskell-nix.legacyPackages.${system};
        defaultCompilerSrc = pkgs.fetchFromGitHub {
          owner = "purescript";
          repo = "purescript";
          rev = "v0.13.8";
          sha256 = "sha256-QMyomlrKR4XfZcF1y0PQ2OQzbCzf0NONf81ZJA3nj1Y=";
        };
        defaultZephyrSrc = pkgs.fetchFromGitHub {
          owner = "coot";
          repo = "zephyr";
          rev = "v0.3.2";
          sha256 = "sha256-iDsuYgwxgEeZYyNcbKCZaXO1fVWxxf97+h/wfs/CtgY=";
        };
        defaultPackageSet = pkgs.fetchFromGitHub {
          owner = "purescript";
          repo = "package-sets";
          rev = "psc-0.13.8-20210118";
          sha256 = "sha256-TwcqgXEhkcPZkbtruJdmT3fuuZIMO4yT+NEbzuGwJVU=";
        };
      in
        {
          purescriptPackage =
            { name
            , src # Must contain an `src` directory
            , compilerSrc ? defaultCompilerSrc
            , zephyrSrc ? defaultZephyrSrc
            , packageSet ? defaultPackageSet
            , dependencies
            , pinnedDependencies ? null
            , extraDeps ? []
            , mainModule ? "Main"
            , sourcemaps ? false
            , namespace ? "PS"
            , extraBundleContents ? null
            }: with pkgs.lib; let
              packages = builtins.fromJSON (builtins.readFile "${packageSet}/packages.json");
              flattenDependencies = deps: concatMap (dep: [ dep ] ++ flattenDependencies packages.${dep}.dependencies) deps;
              flattenedDependenciesOfExtraDeps = concatMap (dep: flattenDependencies dep.dependencies) extraDeps;
              allDependencyNames = unique (flattenDependencies dependencies ++ flattenedDependenciesOfExtraDeps);
              allDependencies = getAttrs allDependencyNames packages;
              pinnedDependenciesFetched = mapAttrsToList (
                name: value: pkgs.fetchgit {
                  inherit (value) url rev sha256;
                }
              ) (import pinnedDependencies);
              dependencySources = concatMapStringsSep " "
                (dep: "'${dep.outPath}/src/**/*.purs'")
                pinnedDependenciesFetched;
              extraDepSources = concatMapStringsSep " "
                (dep: "'${dep.src.outPath}/src/**/*.purs'")
                extraDeps;
              ownSources = "'${src}/src/**/*.purs'";
              purs =
                (
                  pkgs.haskell-nix.stackProject' {
                    name = "purescript";
                    src = compilerSrc;
                    pkg-def-extras = [
                      (hackage: { hsc2hs = hackage.hsc2hs."0.68.7".revisions.default; })
                    ];
                  }
                ).hsPkgs.purescript.components.exes.purs;
              zephyr =
                (
                  pkgs.haskell-nix.cabalProject' {
                    name = "zephyr";
                    src = zephyrSrc;
                    compiler-nix-name = "ghc865";
                  }
                ).hsPkgs.zephyr.components.exes.zephyr;
            in
              rec {
                inherit purs zephyr;

                pinDependencies = let
                  prefetchGitHash = { url, ref }: let
                    src = builtins.fetchGit { inherit url ref; };
                    hashFile = pkgs.runCommand "prefetch-git" {
                      nativeBuildInputs = [ pkgs.nix ];
                    } ''
                      nix-hash --type sha256 --base32 ${src} | tr -d '\n' > $out
                    '';
                  in
                    builtins.readFile hashFile;
                in
                  mapAttrs (
                    name: value: {
                      url = value.repo;
                      rev = value.version;
                      sha256 = prefetchGitHash { url = value.repo; ref = "refs/tags/${value.version}"; };
                    }
                  ) allDependencies;

                buildDeps = { codegen }: pkgs.runCommand "purescript-${name}-deps" {
                  nativeBuildInputs = [ purs ];
                } ''
                  purs --version
                  purs compile \
                    ${dependencySources} \
                    ${extraDepSources} \
                    --codegen ${pkgs.lib.concatStringsSep "," codegen} \
                    -o $out
                '';

                build = { codegen }: pkgs.runCommand "purescript-${name}-build" {
                  nativeBuildInputs = [ purs ];
                } ''
                  cp -r --no-preserve=mode,ownership ${buildDeps { inherit codegen; }} $out
                  purs compile \
                    ${ownSources} \
                    ${dependencySources} \
                    ${extraDepSources} \
                    --codegen ${pkgs.lib.concatStringsSep "," codegen} \
                    -o $out
                '';

                bundle = let
                  corefnBuild = build { codegen = [ "corefn" ]; };
                  createBundleDir =
                    if extraBundleContents != null
                    then "cp -r --no-preserve=mode,ownership ${extraBundleContents} $out"
                    else "mkdir $out";
                in
                  pkgs.runCommand "purescript-${name}-bundle" {
                    nativeBuildInputs = [ purs zephyr ];
                  } ''
                    ${createBundleDir}
                    zephyr ${mainModule} -f -i ${corefnBuild} -o zephyr-out
                    purs bundle \
                      'zephyr-out/**/*.js' \
                      --main ${mainModule} \
                      -o $out/bundle.js
                  '';

                devShell = let
                  ownDevSources = "'src/**/*.purs'";
                  createBundleDir =
                    if extraBundleContents != null
                    then "cp -r --no-preserve=mode,ownership ${extraBundleContents} .out/bundle"
                    else "mkdir .out/bundle";
                  bundleOnceScript = pkgs.writeShellScriptBin "bundle-once" ''
                    rm -rf .out/bundle
                    ${createBundleDir}
                    echo compiling...
                    purs compile \
                      ${ownDevSources} \
                      ${dependencySources} \
                      ${extraDepSources} \
                      --codegen js \
                      -o .out/build
                    echo bundling...
                    purs bundle \
                      '.out/build/**/*.js' \
                      --main ${mainModule} \
                      --source-maps \
                      -o .out/bundle/bundle.js
                    echo done
                  '';
                  langserverConfig.purescript = {
                    outputDirectory = ".out/build";
                    sourceGlobs = builtins.map (dep: "${dep.outPath}/src/**/*.purs") pinnedDependenciesFetched
                    ++ builtins.map (dep: "${dep.src.outPath}/src/**/*.purs") extraDeps;
                  };
                  langserverScript = pkgs.writeShellScriptBin "langserver" ''
                    purescript-language-server \
                      --stdio \
                      --log /tmp/purs-langserver-log \
                      --config '${builtins.toJSON langserverConfig}'
                  '';
                in
                  pkgs.mkShell {
                    buildInputs = [
                      purs
                      zephyr
                      pkgs.nodePackages.purescript-language-server
                      pkgs.inotify-tools
                      pkgs.darkhttpd
                      bundleOnceScript
                      langserverScript
                    ];
                    shellHook = ''
                      rm -rf .out
                      mkdir .out
                      cp -r --no-preserve=mode,ownership ${buildDeps { codegen = [ "js" ]; }} .out/build
                      function bundle() {
                        trap 'kill $(jobs -p)' EXIT
                        bundle-once
                        while inotifywait -qqre modify "src" "${extraBundleContents}"; do
                          bundle-once
                        done &
                        darkhttpd .out/bundle &
                      }
                    '';
                  };
              };
        }
  );
}
