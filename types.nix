{ lib, rootMountPoint }:
with lib;
with builtins;

rec {

  diskoLib = {
    # like types.oneOf but instead of a list takes an attrset
    # uses the field "type" to find the correct type in the attrset
    subType = typeAttr: mkOptionType rec {
      name = "subType";
      description = "one of ${concatStringsSep "," (attrNames typeAttr)}";
      check = x: if x ? type then typeAttr.${x.type}.check x else throw "No type option set in:\n${generators.toPretty {} x}";
      merge = loc: defs:
        foldl' (res: def: typeAttr.${def.value.type}.merge loc [def]) {} defs;
      nestedTypes = typeAttr;
    };

    # option for valid contents of partitions (basically like devices, but without tables)
    partitionType = mkOption {
      type = types.nullOr (diskoLib.subType { inherit btrfs filesystem zfs mdraid luks lvm_pv swap; });
      default = null;
      description = "The type of partition";
    };

    # option for valid contents of devices
    deviceType = mkOption {
      type = types.nullOr (diskoLib.subType { inherit table btrfs filesystem zfs mdraid luks lvm_pv swap; });
      default = null;
      description = "The type of device";
    };

    /* deepMergeMap takes a function and a list of attrsets and deep merges them

       deepMergeMap :: -> (AttrSet -> AttrSet ) -> [ AttrSet ] -> Attrset

       Example:
         deepMergeMap (x: x.t = "test") [ { x = { y = 1; z = 3; }; } { x = { bla = 234; }; } ]
         => { x = { y = 1; z = 3; bla = 234; t = "test"; }; }
    */
    deepMergeMap = f: listOfAttrs:
      foldr (attr: acc: (recursiveUpdate acc (f attr))) {} listOfAttrs;

    /* get a device and an index to get the matching device name

       deviceNumbering :: str -> int -> str

       Example:
       deviceNumbering "/dev/sda" 3
       => "/dev/sda3"

       deviceNumbering "/dev/disk/by-id/xxx" 2
       => "/dev/disk/by-id/xxx-part2"
    */
    deviceNumbering = dev: index:
      if match "/dev/[vs]d.+" dev != null then
        dev + toString index  # /dev/{s,v}da style
      else if match "/dev/disk/.+" dev != null then
        "${dev}-part${toString index}" # /dev/disk/by-id/xxx style
      else if match "/dev/(nvme|md/|mmcblk).+" dev != null then
        "${dev}p${toString index}" # /dev/nvme0n1p1 style
      else
        abort "${dev} seems not to be a supported disk format";

    /* A nix option type representing a json datastructure, vendored from nixpkgs to avoid dependency on pkgs */
    jsonType = let
      valueType = types.nullOr (types.oneOf [
        types.bool
        types.int
        types.float
        types.str
        types.path
        (types.attrsOf valueType)
        (types.listOf valueType)
      ]) // {
        description = "JSON value";
      };
    in valueType;

    /* Given a attrset of deviceDependencies and a devices attrset
       returns a sorted list by deviceDependencies. aborts if a loop is found

       sortDevicesByDependencies :: AttrSet -> AttrSet -> [ [ str str ] ]
    */
    sortDevicesByDependencies = deviceDependencies: devices:
      let
        dependsOn = a: b:
          elem a (attrByPath b [] deviceDependencies);
        maybeSortedDevices = toposort dependsOn (diskoLib.deviceList devices);
      in
        if (hasAttr "cycle" maybeSortedDevices) then
          abort "detected a cycle in your disk setup: ${maybeSortedDevices.cycle}"
        else
          maybeSortedDevices.result;

    /* Takes a devices attrSet and returns it as a list

       deviceList :: AttrSet -> [ [ str str ] ]

       Example:
         deviceList { zfs.pool1 = {}; zfs.pool2 = {}; mdadm.raid1 = {}; }
         => [ [ "zfs" "pool1" ] [ "zfs" "pool2" ] [ "mdadm" "raid1" ] ]
    */
    deviceList = devices:
      concatLists (mapAttrsToList (n: v: (map (x: [ n x ]) (attrNames v))) devices);

    /* Takes either a string or null and returns the string or an empty string

       maybeStr :: Either (str null) -> str

       Example:
         maybeStr null
         => ""
         maybeSTr "hello world"
         => "hello world"
    */
    maybeStr = x: optionalString (!isNull x) x;

    /* Takes a Submodules config and options argument and returns a serializable
       subset of config variables as a shell script snippet.
    */
    defineHookVariables = {config, options}:
      let
        sanitizeName = lib.replaceStrings ["-"] ["_"];
        isAttrsOfSubmodule = o: o.type.name == "attrsOf" && o.type.nestedTypes.elemType.name == "submodule";
        isSerializable = n: o: !(
          lib.hasPrefix "_" n
          || lib.hasSuffix "Hook" n
          || isAttrsOfSubmodule o
          # TODO don't hardcode diskoLib.subType options.
          || n == "content" || n == "partitions");
      in
      lib.toShellVars
        (lib.mapAttrs'
          (n: o: lib.nameValuePair (sanitizeName n) o.value)
          (lib.filterAttrs isSerializable options));

    hookMixin = { config, options,... }: {
      options = let
        mkHook = description: mkOption {
          inherit description;
          type = types.str;
          default = "";
        };
      in {
        preCreateHook = mkHook "shell commands to run before create";
        postCreateHook = mkHook "shell commands to run after create";
        preMountHook = mkHook "shell commands to run before mount";
        postMountHook = mkHook "shell commands to run after mount";
      };
    };

    mkCreateOption = { config, options, default }@attrs:
      mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo types.str;
        default = args:
          let name = "format";
              test = lib.optionalString (config ? name) "${config.${name}}";
          in
          ''
          ( # ${config.type} ${concatMapStringsSep " " (n: toString (config.${n} or "")) ["name" "device" "format" "mountpoint"]}
            ${diskoLib.defineHookVariables { inherit config options; }}
            ${config.preCreateHook}
            ${attrs.default args}
            ${config.postCreateHook}
          )
          '';
        description = "Creation script";
      };

    mkMountOption = { config, options, default }@attrs:
      mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo diskoLib.jsonType;
        default = args: attrs.default args;
        description = "Mount script";
      };


    /* Takes a disko device specification, returns an attrset with metadata

       meta :: types.devices -> AttrSet
    */
    meta = devices: diskoLib.deepMergeMap (dev: dev._meta) (flatten (map attrValues (attrValues devices)));

    /* Takes a disko device specification and returns a string which formats the disks

       create :: types.devices -> str
    */
    create = devices: let
      sortedDeviceList = diskoLib.sortDevicesByDependencies ((diskoLib.meta devices).deviceDependencies or {}) devices;
    in ''
      set -efux

      disko_devices_dir=$(mktemp -d)
      trap 'rm -rf "$disko_devices_dir"' EXIT
      mkdir -p "$disko_devices_dir"

      ${concatMapStrings (dev: (attrByPath (dev ++ [ "_create" ]) ({}: {}) devices) {}) sortedDeviceList}
    '';
    /* Takes a disko device specification and returns a string which mounts the disks

       mount :: types.devices -> str
    */
    mount = devices: let
      fsMounts = diskoLib.deepMergeMap (dev: (dev._mount {}).fs or {}) (flatten (map attrValues (attrValues devices)));
      sortedDeviceList = diskoLib.sortDevicesByDependencies ((diskoLib.meta devices).deviceDependencies or {}) devices;
    in ''
      set -efux
      # first create the necessary devices
      ${concatMapStrings (dev: ((attrByPath (dev ++ [ "_mount" ]) {} devices) {}).dev or "") sortedDeviceList}

      # and then mount the filesystems in alphabetical order
      ${concatStrings (attrValues fsMounts)}
    '';

    /* takes a disko device specification and returns a string which unmounts, destroys all disks and then runs create and mount

       zapCreateMount :: types.devices -> str
    */
    zapCreateMount = devices: ''
      set -efux
      umount -Rv "${rootMountPoint}" mnt || :

      for dev in ${toString (lib.catAttrs "device" (lib.attrValues devices.disk))}; do
        ${./disk-deactivate}/disk-deactivate "$dev" | bash -x
      done

      echo 'creating partitions...'
      ${diskoLib.create devices}
      echo 'mounting partitions...'
      ${diskoLib.mount devices}
    '';
    /* Takes a disko device specification and returns a nixos configuration

       config :: types.devices -> nixosConfig
    */
    config = devices: flatten (map (dev: dev._config) (flatten (map attrValues (attrValues devices))));
    /* Takes a disko device specification and returns a function to get the needed packages to format/mount the disks

       packages :: types.devices -> pkgs -> [ derivation ]
    */
    packages = devices: pkgs: unique (flatten (map (dev: dev._pkgs pkgs) (flatten (map attrValues (attrValues devices)))));
  };

  optionTypes = rec {
    filename = mkOptionType {
      name = "filename";
      check = x: isString x;
      merge = mergeOneOption;
      description = "A filename";
    };

    absolute-pathname = mkOptionType {
      name = "absolute pathname";
      check = x: isString x && substring 0 1 x == "/" && pathname.check x;
      merge = mergeOneOption;
      description = "An absolute path";
    };

    pathname = mkOptionType {
      name = "pathname";
      check = x:
        let
          # The filter is used to normalize paths, i.e. to remove duplicated and
          # trailing slashes.  It also removes leading slashes, thus we have to
          # check for "/" explicitly below.
          xs = filter (s: stringLength s > 0) (splitString "/" x);
        in
          isString x && (x == "/" || (length xs > 0 && all filename.check xs));
      merge = mergeOneOption;
      description = "A path name";
    };
  };

  /* topLevel type of the disko config, takes attrsets of disks, mdadms, zpools, nodevs, and lvm vgs.
  */
  devices = types.submodule {
    options = {
      disk = mkOption {
        type = types.attrsOf disk;
        default = {};
        description = "Block device";
      };
      mdadm = mkOption {
        type = types.attrsOf mdadm;
        default = {};
        description = "mdadm device";
      };
      zpool = mkOption {
        type = types.attrsOf zpool;
        default = {};
        description = "ZFS pool device";
      };
      lvm_vg = mkOption {
        type = types.attrsOf lvm_vg;
        default = {};
        description = "LVM VG device";
      };
      nodev = mkOption {
        type = types.attrsOf nodev;
        default = {};
        description = "A non-block device";
      };
    };
  };

  nodev = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      type = mkOption {
        type = types.enum [ "nodev" ];
        default = "nodev";
        internal = true;
        description = "Device type";
      };
      fsType = mkOption {
        type = types.str;
        description = "File system type";
      };
      device = mkOption {
        type = types.str;
        default = "none";
        description = "Device to use";
      };
      mountpoint = mkOption {
        type = optionTypes.absolute-pathname;
        default = config._module.args.name;
        description = "Location to mount the file system at";
      };
      mountOptions = mkOption {
        type = types.listOf types.str;
        default = [ "defaults" ];
        description = "Options to pass to mount";
      };
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = diskoLib.jsonType;
        default = {
        };
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {}: "";
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {}: {
          fs.${config.mountpoint} = ''
            if ! findmnt ${config.fsType} "${rootMountPoint}${config.mountpoint}" > /dev/null 2>&1; then
              mount -t ${config.fsType} ${config.device} "${rootMountPoint}${config.mountpoint}" \
              ${concatMapStringsSep " " (opt: "-o ${opt}") config.mountOptions} \
              -o X-mount.mkdir
            fi
          '';
        };
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = [{
          fileSystems.${config.mountpoint} = {
            device = config.device;
            fsType = config.fsType;
            options = config.mountOptions;
          };
        }];
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: [];
        description = "Packages";
      };
    };
  })];

  btrfs = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      type = mkOption {
        type = types.enum [ "btrfs" ];
        internal = true;
        description = "Type";
      };
      extraArgs = mkOption {
        type = types.str;
        default = "";
        description = "Arguments to pass to BTRFS";
      };
      mountOptions = mkOption {
        type = types.listOf types.str;
        default = [ "defaults" ];
        description = "A list of options to pass to mount.";
      };
      subvolumes = mkOption {
        type = types.attrsOf btrfs_subvol;
        default = {};
        description = "Subvolumes to define for BTRFS.";
      };
      mountpoint = mkOption {
        type = types.nullOr optionTypes.absolute-pathname;
        default = null;
        description = "A path to mount the BTRFS filesystem to.";
      };
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo diskoLib.jsonType;
        default = dev:
          diskoLib.deepMergeMap (subvol: subvol._meta dev) (attrValues config.subvolumes);
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {dev}: ''
          mkfs.btrfs ${dev} ${config.extraArgs}
          ${concatMapStrings (subvol: subvol._create { inherit dev; }) (attrValues config.subvolumes)}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {dev}:
          let
            subvolMounts = diskoLib.deepMergeMap (subvol: subvol._mount {inherit dev; parent = config.mountpoint;}) (attrValues config.subvolumes);
          in {
            fs = subvolMounts.fs // optionalAttrs (!isNull config.mountpoint) {
              ${config.mountpoint} = ''
                if ! findmnt ${dev} "${rootMountPoint}${config.mountpoint}" > /dev/null 2>&1; then
                  mount ${dev} "${rootMountPoint}${config.mountpoint}" \
                  ${concatMapStringsSep " " (opt: "-o ${opt}") config.mountOptions} \
                  -o X-mount.mkdir
                fi
              '';
            };
          };
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = dev: [
          (map (subvol: subvol._config dev config.mountpoint) (attrValues config.subvolumes))
          (optional (!isNull config.mountpoint) {
            fileSystems.${config.mountpoint} = {
              device = dev;
              fsType = "btrfs";
              options = config.mountOptions;
            };
          })
        ];
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs:
          [ pkgs.btrfs-progs ] ++ flatten (map (subvolume: subvolume._pkgs pkgs) (attrValues config.subvolumes));
        description = "Packages";
      };
    };
  })];

  btrfs_subvol = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        default = config._module.args.name;
        description = "Name of the BTRFS subvolume.";
      };
      type = mkOption {
        type = types.enum [ "btrfs_subvol" ];
        default = "btrfs_subvol";
        internal = true;
        description = "Type";
      };
      extraArgs = mkOption {
        type = types.str;
        default = "";
        description = "Extra arguments to pass";
      };
      mountOptions = mkOption {
        type = types.listOf types.str;
        default = [ "defaults" ];
        description = "Options to pass to mount";
      };
      mountpoint = mkOption {
        type = types.nullOr optionTypes.absolute-pathname;
        default = null;
        description = "Location to mount the subvolume to.";
      };
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo diskoLib.jsonType;
        default = dev: {
        };
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {dev}: ''
          MNTPOINT=$(mktemp -d)
          (
            mount ${dev} "$MNTPOINT" -o subvol=/
            trap 'umount $MNTPOINT; rm -rf $MNTPOINT' EXIT
            btrfs subvolume create "$MNTPOINT"/${config.name} ${config.extraArgs}
          )
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {dev, parent}: let
          mountpoint = if (!isNull config.mountpoint) then config.mountpoint
                       else if (isNull parent) then config.name
                       else null;
        in optionalAttrs (!isNull mountpoint) {
          fs.${mountpoint} = ''
            if ! findmnt ${dev} "${rootMountPoint}${mountpoint}" > /dev/null 2>&1; then
              mount ${dev} "${rootMountPoint}${mountpoint}" \
              ${concatMapStringsSep " " (opt: "-o ${opt}") (config.mountOptions ++ [ "subvol=${config.name}" ])} \
              -o X-mount.mkdir
            fi
          '';
        };
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = dev: parent: let
          mountpoint = if (!isNull config.mountpoint) then config.mountpoint
                       else if (isNull parent) then config.name
                       else null;
        in optional (!isNull mountpoint) {
          fileSystems.${mountpoint} = {
            device = dev;
            fsType = "btrfs";
            options = config.mountOptions ++ [ "subvol=${config.name}" ];
          };
        };
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: [ pkgs.coreutils ];
        description = "Packages";
      };
    };
  })];

  filesystem = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      type = mkOption {
        type = types.enum [ "filesystem" ];
        internal = true;
        description = "Type";
      };
      extraArgs = mkOption {
        type = types.str;
        default = "";
        description = "Arguments to pass";
      };
      mountOptions = mkOption {
        type = types.listOf types.str;
        default = [ "defaults" ];
        description = "Options to pass to mount";
      };
      mountpoint = mkOption {
        type = optionTypes.absolute-pathname;
        description = "Path to mount the filesystem to";
      };
      format = mkOption {
        type = types.str;
        description = "Format of the filesystem";
      };
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo diskoLib.jsonType;
        default = dev: {
        };
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {dev}: ''
          mkfs.${config.format} \
            ${config.extraArgs} \
            ${dev}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {dev}: {
          fs.${config.mountpoint} = ''
            if ! findmnt ${dev} "${rootMountPoint}${config.mountpoint}" > /dev/null 2>&1; then
              mount ${dev} "${rootMountPoint}${config.mountpoint}" \
                -t "${config.format}" \
                ${concatMapStringsSep " " (opt: "-o ${opt}") config.mountOptions} \
                -o X-mount.mkdir
            fi
          '';
        };
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = dev: [{
          fileSystems.${config.mountpoint} = {
            device = dev;
            fsType = config.format;
            options = config.mountOptions;
          };
        }];
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        # type = types.functionTo (types.listOf types.package);
        default = pkgs:
          [ pkgs.util-linux ] ++ (
            # TODO add many more
            if (config.format == "xfs") then [ pkgs.xfsprogs ]
            else if (config.format == "btrfs") then [ pkgs.btrfs-progs ]
            else if (config.format == "vfat") then [ pkgs.dosfstools ]
            else if (config.format == "ext2") then [ pkgs.e2fsprogs ]
            else if (config.format == "ext3") then [ pkgs.e2fsprogs ]
            else if (config.format == "ext4") then [ pkgs.e2fsprogs ]
            else if (config.format == "bcachefs") then [ pkgs.bcachefs-tools ]
            else []
          );
        description = "Packages";
      };
    };
  })];

  table = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      type = mkOption {
        type = types.enum [ "table" ];
        internal = true;
        description = "Partition table";
      };
      format = mkOption {
        type = types.enum [ "gpt" "msdos" ];
        default = "gpt";
        description = "The kind of partition table";
      };
      partitions = mkOption {
        type = types.listOf partition;
        default = [];
        description = "List of partitions to add to the partition table";
      };
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo diskoLib.jsonType;
        default = dev:
          diskoLib.deepMergeMap (partition: partition._meta dev) config.partitions;
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {dev}: ''
          parted -s ${dev} -- mklabel ${config.format}
          ${concatMapStrings (partition: partition._create {inherit dev; type = config.format;} ) config.partitions}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {dev}:
          let
            partMounts = diskoLib.deepMergeMap (partition: partition._mount {inherit dev;}) config.partitions;
          in {
            dev = partMounts.dev or "";
            fs = partMounts.fs or {};
        };
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = dev:
          map (partition: partition._config dev) config.partitions;
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs:
          [ pkgs.parted pkgs.systemdMinimal ] ++ flatten (map (partition: partition._pkgs pkgs) config.partitions);
        description = "Packages";
      };
    };
  })];

  partition = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      type = mkOption {
        type = types.enum [ "partition" ];
        internal = true;
        description = "Type";
      };
      part-type = mkOption {
        type = types.enum [ "primary" "logical" "extended" ];
        default = "primary";
        description = "Partition type";
      };
      fs-type = mkOption {
        type = types.nullOr (types.enum [ "btrfs" "ext2" "ext3" "ext4" "fat16" "fat32" "hfs" "hfs+" "linux-swap" "ntfs" "reiserfs" "udf" "xfs" ]);
        default = null;
        description = "Filesystem type to use";
      };
      name = mkOption {
        type = types.nullOr types.str;
        description = "Name of the partition";
      };
      start = mkOption {
        type = types.str;
        default = "0%";
        description = "Start of the partition";
      };
      end = mkOption {
        type = types.str;
        default = "100%";
        description = "End of the partition";
      };
      index = mkOption {
        type = types.int;
        # TODO find a better way to get the index
        default = toInt (head (match ".*entry ([[:digit:]]+)]" config._module.args.name));
        description = "Index of the partition";
      };
      flags = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Partition flags";
      };
      bootable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to make the partition bootable";
      };
      content = diskoLib.partitionType;
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo diskoLib.jsonType;
        default = dev:
          optionalAttrs (!isNull config.content) (config.content._meta dev);
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {dev, type}: ''
          ${optionalString (type == "gpt") ''
            parted -s ${dev} -- mkpart ${config.name} ${diskoLib.maybeStr config.fs-type} ${config.start} ${config.end}
          ''}
          ${optionalString (type == "msdos") ''
            parted -s ${dev} -- mkpart ${config.part-type} ${diskoLib.maybeStr config.fs-type} ${diskoLib.maybeStr config.fs-type} ${config.start} ${config.end}
          ''}
          # ensure /dev/disk/by-path/..-partN exists before continuing
          udevadm trigger --subsystem-match=block; udevadm settle
          ${optionalString (config.bootable) ''
            parted -s ${dev} -- set ${toString config.index} boot on
          ''}
          ${concatMapStringsSep "" (flag: ''
            parted -s ${dev} -- set ${toString config.index} ${flag} on
          '') config.flags}
          # ensure further operations can detect new partitions
          udevadm trigger --subsystem-match=block; udevadm settle
          ${optionalString (!isNull config.content) (config.content._create {dev = (diskoLib.deviceNumbering dev config.index);})}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {dev}:
          optionalAttrs (!isNull config.content) (config.content._mount {dev = (diskoLib.deviceNumbering dev config.index);});
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = dev:
          optional (!isNull config.content) (config.content._config (diskoLib.deviceNumbering dev config.index));
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: optionals (!isNull config.content) (config.content._pkgs pkgs);
        description = "Packages";
      };
    };
  })];

  swap = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      type = mkOption {
        type = types.enum [ "swap" ];
        internal = true;
        description = "Type";
      };
      randomEncryption = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to randomly encrypt the swap";
      };
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo diskoLib.jsonType;
        default = dev: {
        };
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {dev}: ''
          mkswap ${dev}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {dev}: {
          fs.${dev} = ''
            if ! swapon --show | grep -q '^${dev} '; then
              swapon ${dev}
            fi
          '';
        };
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = dev: [{
          swapDevices = [{
            device = dev;
            randomEncryption = config.randomEncryption;
          }];
        }];
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: [ pkgs.gnugrep pkgs.util-linux ];
        description = "Packages";
      };
    };
  })];

  lvm_pv = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      type = mkOption {
        type = types.enum [ "lvm_pv" ];
        internal = true;
        description = "Type";
      };
      vg = mkOption {
        type = types.str;
        description = "Volume group";
      };
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo diskoLib.jsonType;
        default = dev: {
          deviceDependencies.lvm_vg.${config.vg} = [ dev ];
        };
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {dev}: ''
          pvcreate ${dev}
          echo "${dev}" >> $disko_devices_dir/lvm_${config.vg}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {dev}:
          {};
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = dev: [];
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: [ pkgs.lvm2 ];
        description = "Packages";
      };
    };
  })];

  lvm_vg = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        default = config._module.args.name;
        description = "Name of the volume gorup";
      };
      type = mkOption {
        type = types.enum [ "lvm_vg" ];
        internal = true;
        description = "Type";
      };
      lvs = mkOption {
        type = types.attrsOf lvm_lv;
        default = {};
        description = "LVS for the volume group";
      };
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = diskoLib.jsonType;
        default =
          diskoLib.deepMergeMap (lv: lv._meta [ "lvm_vg" config.name ]) (attrValues config.lvs);
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {}: ''
          vgcreate ${config.name} $(tr '\n' ' ' < $disko_devices_dir/lvm_${config.name})
          ${concatMapStrings (lv: lv._create {vg = config.name; }) (attrValues config.lvs)}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {}: let
          lvMounts = diskoLib.deepMergeMap (lv: lv._mount {vg = config.name;}) (attrValues config.lvs);
        in {
          dev = ''
            vgchange -a y
            ${concatMapStrings (x: x.dev or "") (attrValues lvMounts)}
          '';
          fs = lvMounts.fs;
        };
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default =
          map (lv: lv._config config.name) (attrValues config.lvs);
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: flatten (map (lv: lv._pkgs pkgs) (attrValues config.lvs));
        description = "Packages";
      };
    };
  })];

  lvm_lv = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        default = config._module.args.name;
        description = "Name of the logical volume";
      };
      type = mkOption {
        type = types.enum [ "lvm_lv" ];
        default = "lvm_lv";
        internal = true;
        description = "Type";
      };
      size = mkOption {
        type = types.str; # TODO lvm size type
        description = "Size of the logical volume";
      };
      lvm_type = mkOption {
        type = types.nullOr (types.enum [ "mirror" "raid0" "raid1" ]); # TODO add all types
        default = null; # maybe there is always a default type?
        description = "LVM type";
      };
      extraArgs = mkOption {
        type = types.str;
        default = "";
        description = "Extra arguments";
      };
      content = diskoLib.partitionType;
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo diskoLib.jsonType;
        default = dev:
          optionalAttrs (!isNull config.content) (config.content._meta dev);
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {vg}: ''
          lvcreate \
            --yes \
            ${if hasInfix "%" config.size then "-l" else "-L"} ${config.size} \
            -n ${config.name} \
            ${optionalString (!isNull config.lvm_type) "--type=${config.lvm_type}"} \
            ${config.extraArgs} \
            ${vg}
          ${optionalString (!isNull config.content) (config.content._create {dev = "/dev/${vg}/${config.name}";})}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {vg}:
          optionalAttrs (!isNull config.content) (config.content._mount {dev = "/dev/${vg}/${config.name}";});
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = vg:
          [
            (optional (!isNull config.content) (config.content._config "/dev/${vg}/${config.name}"))
            (optional (!isNull config.lvm_type) {
              boot.initrd.kernelModules = [ "dm-${config.lvm_type}" ];
            })
          ];
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: lib.optionals (!isNull config.content) (config.content._pkgs pkgs);
        description = "Packages";
      };
    };
  })];

  zfs = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      type = mkOption {
        type = types.enum [ "zfs" ];
        internal = true;
        description = "Type";
      };
      pool = mkOption {
        type = types.str;
        description = "Name of the ZFS pool";
      };
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo diskoLib.jsonType;
        default = dev: {
          deviceDependencies.zpool.${config.pool} = [ dev ];
        };
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {dev}: ''
          echo "${dev}" >> $disko_devices_dir/zfs_${config.pool}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {dev}:
          {};
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = dev: [];
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: [ pkgs.zfs ];
        description = "Packages";
      };
    };
  })];

  zpool = types.submodule [diskoLib.hookMixin ({ config, options, ... }:
    {
    options = {
      name = mkOption {
        type = types.str;
        default = config._module.args.name;
        description = "Name of the ZFS pool";
      };
      type = mkOption {
        type = types.enum [ "zpool" ];
        default = "zpool";
        internal = true;
        description = "Type";
      };
      mode = mkOption {
        type = types.str; # TODO zfs modes
        default = "";
        description = "Mode of the ZFS pool";
      };
      options = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Options for the ZFS pool";
      };
      rootFsOptions = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Options for the root filesystem";
      };
      mountpoint = mkOption {
        type = types.nullOr optionTypes.absolute-pathname;
        default = null;
        description = "The mountpoint of the pool";
      };
      mountOptions = mkOption {
        type = types.listOf types.str;
        default = [ "defaults" ];
        description = "Options to pass to mount";
      };
      datasets = mkOption {
        type = types.attrsOf zfs_dataset;
        description = "List of datasets to define";
      };
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = diskoLib.jsonType;
        default =
          diskoLib.deepMergeMap (dataset: dataset._meta [ "zpool" config.name ]) (attrValues config.datasets);
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {}: ''
          zpool create ${config.name} \
            ${config.mode} \
            ${concatStringsSep " " (mapAttrsToList (n: v: "-o ${n}=${v}") config.options)} \
            ${concatStringsSep " " (mapAttrsToList (n: v: "-O ${n}=${v}") config.rootFsOptions)} \
            $(tr '\n' ' ' < $disko_devices_dir/zfs_${config.name})
          ${concatMapStrings (dataset: dataset._create {zpool = config.name;}) (attrValues config.datasets)}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {}: let
          datasetMounts = diskoLib.deepMergeMap (dataset: dataset._mount {zpool = config.name;}) (attrValues config.datasets);
        in {
          dev = ''
            zpool list '${config.name}' >/dev/null 2>/dev/null || zpool import '${config.name}'
            ${concatMapStrings (x: x.dev or "") (attrValues datasetMounts)}
          '';
          fs = datasetMounts.fs // optionalAttrs (!isNull config.mountpoint) {
            ${config.mountpoint} = ''
              if ! findmnt ${config.name} "${rootMountPoint}${config.mountpoint}" > /dev/null 2>&1; then
                mount ${config.name} "${rootMountPoint}${config.mountpoint}" \
                ${optionalString ((config.options.mountpoint or "") != "legacy") "-o zfsutil"} \
                ${concatMapStringsSep " " (opt: "-o ${opt}") config.mountOptions} \
                -o X-mount.mkdir \
                -t zfs
              fi
            '';
          };
        };
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = [
          (map (dataset: dataset._config config.name) (attrValues config.datasets))
          (optional (!isNull config.mountpoint) {
            fileSystems.${config.mountpoint} = {
              device = config.name;
              fsType = "zfs";
              options = config.mountOptions ++ lib.optional ((config.options.mountpoint or "") != "legacy") "zfsutil";
            };
          })
        ];
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: [ pkgs.util-linux ] ++ flatten (map (dataset: dataset._pkgs pkgs) (attrValues config.datasets));
        description = "Packages";
      };
    };
  })];

  zfs_dataset = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        default = config._module.args.name;
        description = "Name of the dataset";
      };
      type = mkOption {
        type = types.enum [ "zfs_dataset" ];
        default = "zfs_dataset";
        internal = true;
        description = "Type";
      };
      zfs_type = mkOption {
        type = types.enum [ "filesystem" "volume" ];
        description = "The type of the dataset";
      };
      options = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Options to set for the dataset";
      };
      mountOptions = mkOption {
        type = types.listOf types.str;
        default = [ "defaults" ];
        description = "Mount options";
      };

      # filesystem options
      mountpoint = mkOption {
        type = types.nullOr optionTypes.absolute-pathname;
        default = null;
        description = "Path to mount the dataset to";
      };

      # volume options
      size = mkOption {
        type = types.nullOr types.str; # TODO size
        default = null;
        description = "Size of the dataset";
      };

      content = diskoLib.partitionType;
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo diskoLib.jsonType;
        default = dev:
          optionalAttrs (!isNull config.content) (config.content._meta dev);
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {zpool}: ''
          zfs create ${zpool}/${config.name} \
            ${concatStringsSep " " (mapAttrsToList (n: v: "-o ${n}=${v}") config.options)} \
            ${optionalString (config.zfs_type == "volume") "-V ${config.size}"}
          ${optionalString (config.zfs_type == "volume") ''
            udevadm trigger --subsystem-match=block; udevadm settle
            ${optionalString (!isNull config.content) (config.content._create {dev = "/dev/zvol/${zpool}/${config.name}";})}
          ''}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {zpool}:
          optionalAttrs (config.zfs_type == "volume" && !isNull config.content) (config.content._mount {dev = "/dev/zvol/${zpool}/${config.name}";}) //
            optionalAttrs (config.zfs_type == "filesystem" && config.options.mountpoint or "" != "none") { fs.${config.mountpoint} = ''
              if ! findmnt ${zpool}/${config.name} "${rootMountPoint}${config.mountpoint}" > /dev/null 2>&1; then
                mount ${zpool}/${config.name} "${rootMountPoint}${config.mountpoint}" \
                -o X-mount.mkdir \
                ${concatMapStringsSep " " (opt: "-o ${opt}") config.mountOptions} \
                ${optionalString ((config.options.mountpoint or "") != "legacy") "-o zfsutil"} \
                -t zfs
              fi
            ''; };
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = zpool:
          (optional (config.zfs_type == "volume" && !isNull config.content) (config.content._config "/dev/zvol/${zpool}/${config.name}")) ++
          (optional (config.zfs_type == "filesystem" && config.options.mountpoint or "" != "none") {
            fileSystems.${config.mountpoint} = {
              device = "${zpool}/${config.name}";
              fsType = "zfs";
              options = config.mountOptions ++ lib.optional ((config.options.mountpoint or "") != "legacy") "zfsutil";
            };
          });
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: [ pkgs.util-linux ] ++ lib.optionals (!isNull config.content) (config.content._pkgs pkgs);
        description = "Packages";
      };
    };
  })];

  mdadm = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        default = config._module.args.name;
        description = "Name";
      };
      type = mkOption {
        type = types.enum [ "mdadm" ];
        default = "mdadm";
        internal = true;
        description = "Type";
      };
      level = mkOption {
        type = types.int;
        default = 1;
        description = "mdadm level";
      };
      metadata = mkOption {
        type = types.enum [ "1" "1.0" "1.1" "1.2" "default" "ddf" "imsm" ];
        default = "default";
        description = "Metadata";
      };
      content = diskoLib.deviceType;
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = diskoLib.jsonType;
        default =
          optionalAttrs (!isNull config.content) (config.content._meta [ "mdadm" config.name ]);
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {}: ''
          echo 'y' | mdadm --create /dev/md/${config.name} \
            --level=${toString config.level} \
            --raid-devices=$(wc -l $disko_devices_dir/raid_${config.name} | cut -f 1 -d " ") \
            --metadata=${config.metadata} \
            --force \
            --homehost=any \
            $(tr '\n' ' ' < $disko_devices_dir/raid_${config.name})
          udevadm trigger --subsystem-match=block; udevadm settle
          ${optionalString (!isNull config.content) (config.content._create {dev = "/dev/md/${config.name}";})}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {}:
          optionalAttrs (!isNull config.content) (config.content._mount {dev = "/dev/md/${config.name}";});
        # TODO we probably need to assemble the mdadm somehow
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default =
          optional (!isNull config.content) (config.content._config "/dev/md/${config.name}");
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: (lib.optionals (!isNull config.content) (config.content._pkgs pkgs));
        description = "Packages";
      };
    };
  })];

  mdraid = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      type = mkOption {
        type = types.enum [ "mdraid" ];
        internal = true;
        description = "Type";
      };

      name = mkOption {
        type = types.str;
        description = "Name";
      };
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo diskoLib.jsonType;
        default = dev: {
          deviceDependencies.mdadm.${config.name} = [ dev ];
        };
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {dev}: ''
          echo "${dev}" >> $disko_devices_dir/raid_${config.name}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {dev}:
          {};
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = dev: [];
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: [ pkgs.mdadm ];
        description = "Packages";
      };
    };
  })];

  luks = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      type = mkOption {
        type = types.enum [ "luks" ];
        internal = true;
        description = "Type";
      };
      name = mkOption {
        type = types.str;
        description = "Name of the LUKS";
      };
      keyFile = mkOption {
        type = types.nullOr optionTypes.absolute-pathname;
        default = null;
        description = "Path to the key for encryption";
      };
      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra arguments";
      };
      content = diskoLib.deviceType;
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo diskoLib.jsonType;
        default = dev:
          optionalAttrs (!isNull config.content) (config.content._meta dev);
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {dev}: ''
          cryptsetup -q luksFormat ${dev} ${diskoLib.maybeStr config.keyFile} ${toString config.extraArgs}
          cryptsetup luksOpen ${dev} ${config.name} ${optionalString (!isNull config.keyFile) "--key-file ${config.keyFile}"}
          ${optionalString (!isNull config.content) (config.content._create {dev = "/dev/mapper/${config.name}";})}
        '';
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {dev}:
          let
            contentMount = config.content._mount {dev = "/dev/mapper/${config.name}";};
          in
            {
              dev = ''
                cryptsetup status ${config.name} >/dev/null 2>/dev/null ||
                  cryptsetup luksOpen ${dev} ${config.name} ${optionalString (!isNull config.keyFile) "--key-file ${config.keyFile}"}
                ${optionalString (!isNull config.content) contentMount.dev or ""}
              '';
              fs = optionalAttrs (!isNull config.content) contentMount.fs or {};
            };
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default = dev:
          [
            # TODO do we need this always in initrd and only there?
            { boot.initrd.luks.devices.${config.name}.device = dev; }
          ] ++ (optional (!isNull config.content) (config.content._config "/dev/mapper/${config.name}"));
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: [ pkgs.cryptsetup ] ++ (lib.optionals (!isNull config.content) (config.content._pkgs pkgs));
        description = "Packages";
      };
    };
  })];

  disk = types.submodule [diskoLib.hookMixin ({ config, options, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        default = config._module.args.name;
        description = "Device name";
      };
      type = mkOption {
        type = types.enum [ "disk" ];
        default = "disk";
        internal = true;
        description = "Type";
      };
      device = mkOption {
        type = optionTypes.absolute-pathname; # TODO check if subpath of /dev ? - No! eg: /.swapfile
        description = "Device path";
      };
      content = diskoLib.deviceType;
      _meta = mkOption {
        internal = true;
        readOnly = true;
        type = diskoLib.jsonType;
        default =
          optionalAttrs (!isNull config.content) (config.content._meta [ "disk" config.device ]);
        description = "Metadata";
      };
      _create = diskoLib.mkCreateOption {
        inherit config options;
        default = {}: config.content._create {dev = config.device;};
      };
      _mount = diskoLib.mkMountOption {
        inherit config options;
        default = {}:
          optionalAttrs (!isNull config.content) (config.content._mount {dev = config.device;});
      };
      _config = mkOption {
        internal = true;
        readOnly = true;
        default =
          optional (!isNull config.content) (config.content._config config.device);
        description = "NixOS configuration";
      };
      _pkgs = mkOption {
        internal = true;
        readOnly = true;
        type = types.functionTo (types.listOf types.package);
        default = pkgs: [ pkgs.jq ] ++ lib.optionals (!isNull config.content) (config.content._pkgs pkgs);
        description = "Packages";
      };
    };
  })];
}
