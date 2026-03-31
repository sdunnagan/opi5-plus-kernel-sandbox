#------------------------------------------------------------------------------
# File:         Makefile
#
# Description:  Builds and installs apps, drivers, and the consolidated
#               sandbox service for Orange Pi 5 Plus / aarch64 (or similar).
#
# Notes:
# ------
# - Export two env vars that point to your kernel workspace:
#   * KERNEL_SRC_DIR:   the kernel source tree (srctree)
#   * KERNEL_BUILD_DIR: the kernel build tree (objtree, i.e. O=)
# - Drivers build as external modules against the O= tree.
#------------------------------------------------------------------------------

SUBDIRS := apps drivers

TARGET_HOST     ?=
TARGET_SSH_OPTS ?=
TARGET_SUDO     ?= sudo
TARGET_PREFIX   ?= /usr/local

SYSTEMD_UNIT_DIR ?= /etc/systemd/system
LIBEXEC_DIR      ?= /usr/local/libexec

SYSTEMD_UNITS := opi5-sandbox.service
SYSTEMD_UNIT_SRC := $(addprefix systemd/,$(SYSTEMD_UNITS))

SANDBOX_SCRIPT := opi5-sandbox-start.sh
SANDBOX_SCRIPT_SRC := scripts/$(SANDBOX_SCRIPT)

ifndef KERNEL_SRC_DIR
$(error KERNEL_SRC_DIR not set; export it or pass on the make command line)
endif
ifndef KERNEL_BUILD_DIR
$(error KERNEL_BUILD_DIR not set; export it or pass on the make command line)
endif
export KERNEL_SRC_DIR KERNEL_BUILD_DIR

.PHONY: all clean \
        apps drivers \
        install install-apps install-drivers install-services \
        install-remote install-remote-apps install-remote-drivers install-remote-services \
        uninstall-remote uninstall-remote-apps uninstall-remote-drivers uninstall-remote-services \
        prepare-kbuild print-kernel-release \
        dt-overlay dtb-grub-install dtb-grub-uninstall

all: apps drivers

apps:
	$(MAKE) -C apps

drivers: prepare-kbuild
	$(MAKE) -C drivers

prepare-kbuild:
	@[ -f "$(KERNEL_BUILD_DIR)/include/generated/autoconf.h" ] || \
	  $(MAKE) -C "$(KERNEL_SRC_DIR)" O="$(KERNEL_BUILD_DIR)" olddefconfig modules_prepare
	@[ -f "$(KERNEL_BUILD_DIR)/Module.symvers" ] || \
	  { echo "NOTE: $(KERNEL_BUILD_DIR)/Module.symvers missing; external modules may lack modversions."; \
	    echo "      Build the kernel or run 'make -C \"$(KERNEL_SRC_DIR)\" O=\"$(KERNEL_BUILD_DIR)\" modules' if needed."; }

print-kernel-release:
	@$(MAKE) -s -C "$(KERNEL_SRC_DIR)" O="$(KERNEL_BUILD_DIR)" kernelrelease

# ---- Local installs (optional) -----------------------------------------------

install: install-apps install-drivers install-services

install-apps:
	$(MAKE) -C apps install

install-drivers:
	$(MAKE) -C drivers install

install-services:
	@echo "Local install of systemd units is not implemented (use install-remote)."
	@echo "If you want it, we can add a local install that copies to $(SYSTEMD_UNIT_DIR)"
	@echo "and $(LIBEXEC_DIR)."

# ---- Remote installs ----------------------------------------------------------

install-remote: install-remote-apps install-remote-drivers install-remote-services

install-remote-apps:
	$(MAKE) -C apps install-remote \
		TARGET_HOST="$(TARGET_HOST)" \
		TARGET_SSH_OPTS="$(TARGET_SSH_OPTS)" \
		TARGET_SUDO="$(TARGET_SUDO)" \
		TARGET_PREFIX="$(TARGET_PREFIX)"

install-remote-drivers:
	$(MAKE) -C drivers install-remote \
		TARGET_HOST="$(TARGET_HOST)" \
		TARGET_SSH_OPTS="$(TARGET_SSH_OPTS)" \
		TARGET_SUDO="$(TARGET_SUDO)"

install-remote-services: $(SYSTEMD_UNIT_SRC) $(SANDBOX_SCRIPT_SRC)
	@if [ -z "$(TARGET_HOST)" ]; then echo "ERROR: TARGET_HOST is required"; exit 2; fi
	@echo ">> Installing sandbox launcher script to $(TARGET_HOST): $(SANDBOX_SCRIPT)"
	@ssh $(TARGET_SSH_OPTS) "$(TARGET_HOST)" '$(TARGET_SUDO) mkdir -p "$(LIBEXEC_DIR)"'
	@cat "$(SANDBOX_SCRIPT_SRC)" | ssh $(TARGET_SSH_OPTS) "$(TARGET_HOST)" \
		'$(TARGET_SUDO) install -m 0755 /dev/stdin "$(LIBEXEC_DIR)/$(SANDBOX_SCRIPT)"'

	@echo ">> Installing systemd unit to $(TARGET_HOST): $(SYSTEMD_UNITS)"
	@ssh $(TARGET_SSH_OPTS) "$(TARGET_HOST)" '$(TARGET_SUDO) mkdir -p "$(SYSTEMD_UNIT_DIR)"'
	@for u in $(SYSTEMD_UNITS); do \
		echo "   - $$u"; \
		cat "systemd/$$u" | ssh $(TARGET_SSH_OPTS) "$(TARGET_HOST)" \
			'$(TARGET_SUDO) install -m 0644 /dev/stdin "$(SYSTEMD_UNIT_DIR)/'$$u'"'; \
	done

	@ssh $(TARGET_SSH_OPTS) "$(TARGET_HOST)" '$(TARGET_SUDO) systemctl daemon-reload'
	@for u in $(SYSTEMD_UNITS); do \
		ssh $(TARGET_SSH_OPTS) "$(TARGET_HOST)" '$(TARGET_SUDO) systemctl enable --now '$$u' >/dev/null'; \
	done
	@echo ">> Installed and started opi5-sandbox.service."

# ---- Remote uninstalls --------------------------------------------------------

uninstall-remote: uninstall-remote-services uninstall-remote-apps uninstall-remote-drivers

uninstall-remote-apps:
	$(MAKE) -C apps uninstall-remote \
		TARGET_HOST="$(TARGET_HOST)" \
		TARGET_SSH_OPTS="$(TARGET_SSH_OPTS)" \
		TARGET_SUDO="$(TARGET_SUDO)" \
		TARGET_PREFIX="$(TARGET_PREFIX)"

uninstall-remote-drivers:
	$(MAKE) -C drivers uninstall-remote \
		TARGET_HOST="$(TARGET_HOST)" \
		TARGET_SSH_OPTS="$(TARGET_SSH_OPTS)" \
		TARGET_SUDO="$(TARGET_SUDO)"

uninstall-remote-services:
	@if [ -z "$(TARGET_HOST)" ]; then echo "ERROR: TARGET_HOST is required"; exit 2; fi
	@echo ">> Uninstalling sandbox service from $(TARGET_HOST): $(SYSTEMD_UNITS)"
	@for u in $(SYSTEMD_UNITS); do \
		ssh $(TARGET_SSH_OPTS) "$(TARGET_HOST)" '$(TARGET_SUDO) systemctl disable --now '$$u' >/dev/null 2>&1 || true'; \
		ssh $(TARGET_SSH_OPTS) "$(TARGET_HOST)" '$(TARGET_SUDO) rm -f "$(SYSTEMD_UNIT_DIR)/'$$u'" || true'; \
	done
	@ssh $(TARGET_SSH_OPTS) "$(TARGET_HOST)" '$(TARGET_SUDO) rm -f "$(LIBEXEC_DIR)/$(SANDBOX_SCRIPT)" || true'
	@ssh $(TARGET_SSH_OPTS) "$(TARGET_HOST)" '$(TARGET_SUDO) systemctl daemon-reload'
	@echo ">> Removed opi5-sandbox.service and launcher script."

clean:
	@for d in $(SUBDIRS); do \
		echo "CLEAN $$d"; \
		$(MAKE) -C $$d clean; \
	done

# ------------------------------------------------------------------------------
# Device-tree overlay (compile-time) convenience targets
# ------------------------------------------------------------------------------

dt-overlay:
	$(MAKE) -C drivers/gpio_button/overlay

SUDO ?= sudo -n
GRUB_TITLE ?= Fedora (custom DT: gpio_button)

MERGED_DTB := drivers/gpio_button/overlay/rk3399-rockpro64.with-gpio_button-merged.dtb
INSTALL_DTB_GRUB := scripts/grub-install-merged-dtb.sh
UNINSTALL_DTB_GRUB := scripts/grub-uninstall-merged-dtb.sh

dtb-grub-install: $(MERGED_DTB) $(INSTALL_DTB_GRUB)
	@echo ">> Installing merged DTB and GRUB entry '$(GRUB_TITLE)'"
	@$(SUDO) bash "$(INSTALL_DTB_GRUB)" --dtb "$(abspath $(MERGED_DTB))" --title "$(GRUB_TITLE)"

dtb-grub-uninstall: $(UNINSTALL_DTB_GRUB)
	@echo ">> Removing merged DTB and GRUB entry '$(GRUB_TITLE)'"
	@$(SUDO) bash "$(UNINSTALL_DTB_GRUB)" --title "$(GRUB_TITLE)"
