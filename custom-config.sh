cat > "$BUILD_ROOT/.config" <<'EOF'
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_DEVICE_generic=y

CONFIG_TARGET_ROOTFS_PARTSIZE=256

CONFIG_PACKAGE_kmod-virtio=y
CONFIG_PACKAGE_kmod-virtio-net=y
CONFIG_PACKAGE_kmod-virtio-blk=y
CONFIG_PACKAGE_kmod-virtio-scsi=y
CONFIG_PACKAGE_kmod-virtio-ring=y
CONFIG_PACKAGE_kmod-virtio-pci=y
CONFIG_PACKAGE_pbr=y
CONFIG_PACKAGE_zerotier=y
CONFIG_PACKAGE_kmod-wireguard=y
CONFIG_PACKAGE_wireguard-tools=y
CONFIG_PACKAGE_kmod-amneziawg=y
CONFIG_PACKAGE_amneziawg-tools=y
CONFIG_PACKAGE_git=y
CONFIG_PACKAGE_openssh-client=y
CONFIG_PACKAGE_ca-bundle=y
CONFIG_PACKAGE_vim=y
CONFIG_PACKAGE_less=y
CONFIG_PACKAGE_bash=y

EOF
