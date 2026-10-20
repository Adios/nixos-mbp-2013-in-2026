{
  description = "NixOS on the MacBook Pro 15-inch Retina, Early 2013 (MacBookPro10,1): hardware fixes plus a ready-to-install example host";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      # The only knobs most people need: user name, host name, time zone, ...
      settings = import ./hosts/mbp/settings.nix;
    in
    {
      # -----------------------------------------------------------------------
      # Building blocks for YOUR flake (see the README, "Use it from your own flake")
      # -----------------------------------------------------------------------
      nixosModules = {
        # The whole hardware profile: Intel-driven panel, NVIDIA GPU off, Wi-Fi, TLP, charge cap.
        default = ./hardware/hardware-fixes.nix;
        hardware-fixes = ./hardware/hardware-fixes.nix;
        # Optional niri session (system side). GNOME needs no module, see hosts/mbp/configuration.nix.
        niri = ./modules/nixos/niri.nix;
      };

      homeManagerModules = {
        desktop-scale = ./modules/home/desktop-scale.nix;
        desktop-fonts = ./modules/home/desktop-fonts.nix;
        alacritty = ./modules/home/alacritty.nix;
        niri = ./modules/home/niri.nix;
        # niri's GPU rules (render on Intel, never open the powered-off NVIDIA GPU).
        mbp-niri-gpu = ./modules/home/mbp-niri-gpu.nix;
      };

      # -----------------------------------------------------------------------
      # The example host: GNOME + niri sessions, installed by scripts/install.sh.
      # Its name is settings.hostName, so `nixos-rebuild switch --flake .` finds it by itself.
      # -----------------------------------------------------------------------
      nixosConfigurations.${settings.hostName} = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/mbp/configuration.nix
          self.nixosModules.hardware-fixes
          self.nixosModules.niri

          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.${settings.userName} = import ./hosts/mbp/home.nix;
          }
        ];
      };
    };
}
