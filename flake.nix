{
  description = "Catet local meeting recorder runtime";
  inputs.nixpkgs.url = "https://api.flakehub.com/f/pinned/DeterminateSystems/nixpkgs-weekly/0.1.1085777%2Brev-494ce7fd23ff6a5dff39e1fb11e9b6f2ac74bf25/01a133c9-a3ed-7b73-8056-143ddb2158b1/source.tar.gz";
  outputs = { self, nixpkgs }: let
    pkgs = import nixpkgs { system = "aarch64-darwin"; };
  in {
    packages.aarch64-darwin = {
      whisper = pkgs.whisper-cpp;
      ffmpeg = pkgs.ffmpeg;
    };
    devShells.aarch64-darwin.default = pkgs.mkShell {
      packages = [ pkgs.whisper-cpp pkgs.ffmpeg ];
    };
  };
}
