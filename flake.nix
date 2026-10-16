{
  description = "Godot engine dev shell (scons build environment)";

  inputs = {
    # Same nixpkgs pin as ~/dotfiles so the dep set matches pkgs.godot there.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      g = pkgs.godot;
      # Your system's NVIDIA Vulkan ICD (from the installed nvidia-x11 driver).
      # If you update the driver, update this path.
      nvidiaIcd = "/nix/store/rsha0mmmyzsrbryja5ck9w0cdcsj1lap-nvidia-x11-595.71.05/share/vulkan/icd.d/nvidia_icd.json";
    in
    {
      # `cd ~/godot && nix develop` enters this shell.
      devShells.${system}.default = pkgs.mkShell {
        name = "godot";
        packages =
          [ pkgs.python3 ]
          # Runtime display / Vulkan libs the engine dlopens at startup.
          ++ [ pkgs.libX11 pkgs.libXcursor pkgs.libXext pkgs.libXi
               pkgs.libXrender pkgs.libXrandr pkgs.libXinerama pkgs.libXfixes
               pkgs.libXScrnSaver pkgs.libXpresent pkgs.libXcomposite pkgs.libXdamage
               pkgs.libxkbcommon pkgs.fontconfig.lib pkgs.wayland pkgs.vulkan-loader
               pkgs.libglvnd pkgs.alsa-lib pkgs.libpulseaudio ]
          ++ (g.nativeBuildInputs or [])
          ++ (g.buildInputs or [])
          ++ [ (pkgs.writeShellScriptBin "build-godot" ''
                set -e
                cd "$HOME/godot"
                if [ "$#" > 0 ]; then
                  git checkout "$1"
                  scons -c
                fi
                scons debug=1 -j"$(nproc)"
              '') ];
        shellHook = ''
          echo "Godot dev shell (deps mirror pkgs.godot ${pkgs.godot.version})"
          echo "Build debug editor:  scons debug=1   (or: build-godot)"
          echo "Binary:  bin/godot.linuxbsd.editor.dev.x86_64"
          # Runtime display / Vulkan libs the engine dlopens at startup.
          export VK_DRIVER_FILES="${nvidiaIcd}"
          export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:${pkgs.vulkan-loader}/lib:${pkgs.libX11}/lib:${pkgs.libXcursor}/lib:${pkgs.libXext}/lib:${pkgs.libXi}/lib:${pkgs.libXrender}/lib:${pkgs.libXrandr}/lib:${pkgs.libXinerama}/lib:${pkgs.libXfixes}/lib:${pkgs.libXScrnSaver}/lib:${pkgs.libXpresent}/lib:${pkgs.libXcomposite}/lib:${pkgs.libXdamage}/lib:${pkgs.libxkbcommon}/lib:${pkgs.fontconfig.lib}/lib:${pkgs.wayland}/lib:${pkgs.libglvnd}/lib:${pkgs.alsa-lib}/lib:${pkgs.libpulseaudio}/lib"
        '';
      };
    };
}
