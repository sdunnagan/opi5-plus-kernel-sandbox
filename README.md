# Kernel driver development sandbox for the Orange Pi 5 Plus

## Overview

This repository contains a deliberately layered GPIO bring-up and validation project for the **Orange Pi 5 Plus**, combining direct userspace GPIO access with a custom kernel GPIO driver.

It is designed as a practical development and validation environment for:

- GPIO bring-up and validation on real hardware  
- Device Tree overlays and DTB merging  
- Writing, building, and deploying kernel modules  
- Userspace GPIO interaction using **libgpiod v2**  
- Coordinating kernel and userspace components with **systemd**

The project targets **aarch64 Fedora systems** running either upstream or custom kernels and is intended as a reusable sandbox for ongoing kernel development rather than a polished end-user application.

---

## Project Structure

The project consists of userspace applications and kernel modules:

- **blinky**  
  A minimal userspace application that toggles an LED directly via the GPIO character device using **libgpiod v2**.  
  It serves as a sanity check for GPIO wiring, permissions, and the kernel GPIO stack.

- **button**  
  A userspace application that communicates with the `gpio_button` driver, exercising the full path from hardware interrupt, through the kernel driver, and up into userspace.

- **gpio_button (kernel module)**  
  A custom GPIO driver defined via a Device Tree overlay.  
  It handles a button interrupt in kernel space and controls an associated LED.

---

## Breadboard Wiring

This project uses a **Pi Cobbler** breakout board to connect the Orange Pi 5 Plus 40-pin header to a breadboard.  
The Pi Cobbler used here is silkscreened for Raspberry Pi.

All GPIO signals operate at **3.3 V**. The 5 V pin is not used. A common ground rail is shared by all components.

### Ground and Power Rails

- Breadboard ground rail → Pi Cobbler **GND** (third pin down, right column)
- Pi Cobbler **3v3** (first pin left column) used only for the pull-up resistor

### Yellow LED (libgpiod-controlled)

- LED cathode → ground
- LED anode → resistor → Pi Cobbler **TXD** (GPIO output)

### Red LED (kernel-driver-controlled)

- LED cathode → ground
- LED anode → resistor → Pi Cobbler **#25**

### Button and Pull-Up

- Button terminal → ground
- Button terminal → Pi Cobbler **#24**
- Pull-up resistor between **#24** and **3v3**

The button is active-low.

---

## Install a Custom Upstream Kernel on Orange Pi 5 Plus

Install packages on the build server:
```sh
$ sudo dnf install libgpiod-devel dtc
```

Install packages on the Orange Pi 5 Plus:
```sh
$ sudo dnf install -y libgpiod libgpiod-utils dtc uboot-tools
```

Prepare an upstream kernel build workspace:
```sh
$ export KERNEL_SRC_DIR="/home/$USER/projects/opi5plus/upstream_kernel"
$ export KERNEL_BUILD_DIR="/home/$USER/projects/opi5plus/build_upstream_kernel"
$ git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$KERNEL_SRC_DIR"
$ mkdir -p "$KERNEL_BUILD_DIR"
```

Seed the build config from the Orange Pi 5 Plus:
```sh
$ scp sdunnaga@orthanc:/boot/config-6.17.6-200.fc42.aarch64 "$KERNEL_BUILD_DIR/.config"
```

Configure and build the custom upstream kernel:
```sh
$ ~/projects/kernel-builder/upstream-kernel-builder     -p opi5plus     -c -b     -k ~/projects/opi5plus/upstream_kernel_config_opi5plus.txt     -l florence
```

The build artifacts will be staged in:
```sh
$KERNEL_BUILD_DIR/deploy/
$KERNEL_BUILD_DIR/modules_staging/
```

Set an environment variable for the custom kernel release:
```sh
$ export KREL="7.0.0-florence+"
```

Copy build artifacts to the Orange Pi 5 Plus:
```sh
$ rsync -av "$KERNEL_BUILD_DIR/deploy/Image-upstream-$KREL"     sdunnaga@orthanc:~/Downloads/
$ rsync -av "$KERNEL_BUILD_DIR/modules_staging/lib/modules/$KREL/"     sdunnaga@orthanc:~/Downloads/modules-$KREL/
$ rsync -av "$KERNEL_BUILD_DIR/deploy/dt
```

On the Orange Pi 5 Plus, install modules:
```sh
$ cd ~/Downloads/
$ sudo rsync -av "modules-$KREL/" "/lib/modules/$KREL/"
$ sudo chown -R root:root "/lib/modules/$KREL"
$ sudo depmod -a "$KREL"
```

Install the kernel image to /boot:
```sh
$ sudo install -m 0755 -o root -g root     "$HOME/Downloads/Image-upstream-$KREL"     "/boot/vmlinuz-$KREL"
```

Rebuild the initramfs:
```sh
$ sudo dracut -f "/boot/initramfs-$KREL.img" "$KREL"
```

Install DTBs:
```sh
$ sudo cp -a "$HOME/Downloads/dtbs" "/boot/dtb-$KREL"
$ sudo ln -sfn "dtb-$KREL" /boot/dtb
```

Create a new GRUB boot entry:
```sh
$ sudo grubby --copy-default     --add-kernel "/boot/vmlinuz-$KREL"     --initrd "/boot/initramfs-$KREL.img"     --title "Fedora Linux ($KREL)"
```

Set the custom kernel as the default boot entry:
```sh
$ sudo grubby --set-default "/boot/vmlinuz-$KREL"
```

Always show the GRUB menu:
```sh
$ sudo grub2-editenv - unset menu_auto_hide
```

Uninstall the custom upstream kernel:
```sh
$ sudo grubby --remove-kernel /boot/vmlinuz-$KREL
$ sudo rm -f /boot/vmlinuz-$KREL
$ sudo rm -f /boot/initramfs-$KREL.img
$ sudo rm -f /boot/System.map-$KREL
$ sudo rm -f /boot/config-$KREL
$ sudo rm -rf /lib/modules/$KREL
$ sudo rm -rf /boot/dtb-$KREL
$ sudo depmod -a "$(uname -r)"
```

---

## Build the Project

```sh
$ make
$ make dt-overlay
$ tree
```

---

## Install the Project

```sh
$ TARGET_HOST=<target-name>
$ make install-remote   TARGET_HOST=$USER@$TARGET_HOST   TARGET_PREFIX=/usr/local   TARGET_SSH_OPTS="-o StrictHostKeyChecking=no"   TARGET_SUDO="sudo -n"
```

Verify on the target:
```sh
$ which blinky
$ which button
$ modinfo gpio_button
$ lsmod | grep gpio_button
$ systemctl is-enabled opi5-sandbox.service
$ systemctl is-active opi5-sandbox.service

```

---

## Merge the Custom Device Tree Overlay

SCP .dtbo files to the target:
```sh
$ scp drivers/gpio_button/overlay/gpio_button.overlay.dtbo $USER@$TARGET_HOST:~
$ scp drivers/gpio_button/overlay/i2c_enable.overlay.dtbo $USER@$TARGET_HOST:~
```

On the target, merge the custom device dree overlay:
```sh
$ BASE=/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb
$ sudo cp -a "$BASE" "$BASE.$(date +%F-%H%M%S)"
$ TMP=/tmp/rk3588-orangepi-5-plus.dtb.$(date +%s)
$ sudo fdtoverlay \
  -i "$BASE" \
  -o "$TMP" \
  "/home/$USER/gpio_button.overlay.dtbo" \
  "/home/$USER/i2c_enable.overlay.dtbo"
$ ls -lh "$TMP"
$ sudo install -m 0644 "$TMP" "$BASE"

```

Verify:
```sh
$ sudo dtc -I dtb -O dts -o - /boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb \
      | grep -n "gpio-button" -n
$ sudo dtc -I dtb -O dts -o - /boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb \
      | sed -n '/i2c@feaa0000 {/,/};/p' | head -n 40
```

Edit the BLS entry to add:
```
devicetree /boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb
```

For example:
```
root@orthanc:~# cat /boot/loader/entries/9de905683ada416ba7aee08d8033d6cc-7.0.0-florence+.conf
title Fedora Linux (7.0.0-florence+) 42 (Server Edition)
version 7.0.0-florence+
linux /boot/vmlinuz-7.0.0-florence+
initrd /boot/initramfs-7.0.0-florence+.img
options root=UUID=656542dd-5917-48b1-94b6-0b110c0ccb09 ro console=ttyS2,1500000n8 console=tty1
id fedora-20260416205942-7.0.0-florence+
grub_users $grub_users
grub_arg --unrestricted
grub_class kernel-
devicetree /boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb
```

Reboot and verify:
```sh
$ cat /sys/firmware/devicetree/base/gpio-button/compatible
$ sudo dtc -I fs -O dts -o /tmp/running.dts /sys/firmware/devicetree/base
$ grep -nA5 -B2 "gpio-button" /tmp/running.dts | sed -n '1,120p'
```

---

## Manual GPIO driver and application testing

For manual testing, temporarily stop the systemd service:
```sh
$ sudo systemctl stop opi5-sandbox.service
```

Manually test the GPIO driver:
```sh
$ sudo usermod -a -G gpio $USER
$ sudo reboot
$ gpioinfo --version
$ gpiodetect
$ sudo gpioset -c gpiochip1 2=1
$ gpioset -c gpiochip1 1=1
$ sudo gpioget -c gpiochip3 14
```

Manually test the GPIO **blinky** and **button** applications:
```sh
$ blinky -D -c gpiochip1 -l 1 -i 250
$ sudo button
```

---

## Uninstall

On the target:
```sh
$ sudo pkill blinky
$ sudo pkill button
$ sudo rmmod gpio_button
```

On the build host:
```sh
$ TARGET_HOST=<orangepi5plus_host_name>
$ make uninstall-remote   TARGET_HOST=$USER@$TARGET_HOST   TARGET_PREFIX=/usr/local   TARGET_SSH_OPTS="-o StrictHostKeyChecking=no"   TARGET_SUDO="sudo -n"
$ make clean
```
