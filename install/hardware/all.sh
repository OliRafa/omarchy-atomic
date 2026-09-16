run_logged "$OMARCHY_INSTALL/hardware/network.sh"
run_logged "$OMARCHY_INSTALL/hardware/set-wireless-regdom.sh"
run_logged "$OMARCHY_INSTALL/hardware/bluetooth.sh"
run_logged "$OMARCHY_INSTALL/hardware/vulkan.sh"

# x86 leaves are DMI-gated inside each script; only call scripts that exist on disk.
run_logged "$OMARCHY_INSTALL/hardware/intel/lpmd.sh"
run_logged "$OMARCHY_INSTALL/hardware/intel/thermald.sh"
run_logged "$OMARCHY_INSTALL/hardware/intel/ipu7-camera.sh"
run_logged "$OMARCHY_INSTALL/hardware/intel/fred.sh"
run_logged "$OMARCHY_INSTALL/hardware/intel/fix-wifi7-eht.sh"
run_logged "$OMARCHY_INSTALL/hardware/intel/sof-firmware.sh"

run_logged "$OMARCHY_INSTALL/hardware/fix-elgato-camlink-4k.sh"

# Rebuilds the boot image, so it follows camera module setup.
run_logged "$OMARCHY_INSTALL/hardware/dell-xps13-sidecar-amps.sh"

run_logged "$OMARCHY_INSTALL/hardware/asus/fix-asus-ptl-display-backlight.sh"
run_logged "$OMARCHY_INSTALL/hardware/asus/fix-asus-ptl-b9406-display.sh"
run_logged "$OMARCHY_INSTALL/hardware/asus/fix-asus-ptl-b9406-touchpad.sh"
run_logged "$OMARCHY_INSTALL/hardware/asus/fix-z13-touchpad.sh"

run_logged "$OMARCHY_INSTALL/hardware/framework/qmk-hid.sh"

# Apple Silicon (aarch64) leaves — skip Arch-only T2 / missing scripts.
run_logged "$OMARCHY_INSTALL/hardware/apple/fix-spi-keyboard.sh"
run_logged "$OMARCHY_INSTALL/hardware/apple/fix-brcmfmac-supplicant.sh"
run_logged "$OMARCHY_INSTALL/hardware/apple/fix-asahi-hid-race.sh"
run_logged "$OMARCHY_INSTALL/hardware/apple/enable-notch.sh"
run_logged "$OMARCHY_INSTALL/hardware/apple/audio.sh"

run_logged "$OMARCHY_INSTALL/hardware/lenovo/fix-yoga-pro7-bass-speakers.sh"

run_logged "$OMARCHY_INSTALL/hardware/fix-yt6801-ethernet-adapter.sh"
run_logged "$OMARCHY_INSTALL/hardware/fix-tuxedo-backlight.sh"
run_logged "$OMARCHY_INSTALL/hardware/speaker-tuning.sh"
