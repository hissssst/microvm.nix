{ self, nixpkgs }:

{
  runQemu = { system
            , vcpu ? 1
            , mem ? 512
            , nixosConfig
            , append ? ""
            , user ? null
            , interfaces ? [ { id = "eth0"; type = "user"; mac = "00:23:de:ad:be:ef"; } ]
            , shared ? []
            , preStart ? ""
            }:
    let
      nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ (
          { modulesPath, config, ... }:
          {
            imports = [
              (modulesPath + "/profiles/minimal.nix")
            ];

            boot.isContainer = true;
            systemd.services.nix-daemon.enable = false;
            systemd.sockets.nix-daemon.enable = false;

            fileSystems =
              builtins.foldl' (result: { id, tag ? id, mountpoint, ... }: result // {
                "${mountpoint}" = {
                  device = tag;
                  fsType = "9p";
                  options = [ "trans=virtio" "version=9p2000.L" "cache=loose" "msize=65536" ];
                };
              }) {} shared;
          }
        ) nixosConfig ];
      };
      inherit (nixos.config.networking) hostName;
      pkgs = nixpkgs.legacyPackages.${system};
      arch = builtins.head (builtins.split "-" system);
      rootfs = nixos.config.system.build.toplevel;
      vmTools = pkgs.callPackage ../vmtools.nix { rootModules = []; };
      initrd = "${vmTools.initrd}/initrd";
      qemuCommand = nixpkgs.lib.escapeShellArgs ([
        "${pkgs.qemu}/bin/qemu-system-${arch}"
        "-name" "qemu-${hostName}"
        "-M" "microvm,x-option-roms=off,isa-serial=off,rtc=off"
        "-m" (toString mem)
        "-cpu" "host"
        "-smp" (toString vcpu)
        "-no-acpi" "-enable-kvm"
        "-nodefaults" "-no-user-config"
        "-nographic"
        "-device" "virtio-serial-device"
        "-chardev" "stdio,id=virtiocon0"
        "-device" "virtconsole,chardev=virtiocon0"
        "-device" "virtio-rng-device"
        "-kernel" "${self.packages.${system}.virtioKernel}/bzImage"
        "-initrd" "${initrd}"
        "-fsdev" "local,id=root,path=${rootfs},security_model=passthrough,readonly=on"
        "-device" "virtio-9p-device,fsdev=root,mount_tag=/dev/root"
        "-fsdev" "local,id=store,path=/nix/store,security_model=passthrough,readonly=on"
        "-device" "virtio-9p-device,fsdev=store,mount_tag=store"
        "-append" "console=hvc0 acpi=off reboot=t panic=-1 quiet rootfstype=9p rootflags=trans=virtio ro init=/init command=${rootfs}/init ${append}"
        "-sandbox" "on"
      ] ++
      (if user != null then [ "-user" user ] else []) ++
      (builtins.concatMap ({ type, id, mac }: [
        "-netdev" "${type},id=${id}"
        "-device" "virtio-net-device,netdev=${id},mac=${mac}"
      ]) interfaces) ++
      (builtins.concatMap ({ id
                           , tag ? id
                           , path
                           , writable ? false
                           , security ? (if writable then "mapped-xattr" else "passthrough")
                           , ...
                           }: [
        "-fsdev" "local,id=${id},path=${path},security_model=${security},readonly=${if writable then "off" else "on"}"
        "-device" "virtio-9p-device,fsdev=${id},mount_tag=${tag}"
      ]) shared)
      );
    in
      pkgs.writeScriptBin "run-qemu-${hostName}" ''
        #! ${pkgs.runtimeShell} -e

        ${preStart}

        exec ${qemuCommand}
      '';
}
