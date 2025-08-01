PREFIX ?= $(HOME)/.local
CACHE_DIR ?= .cache
IMPORT_DIR := .godot
ROOTFS ?= $(CACHE_DIR)/rootfs
OGUI_VERSION ?= $(shell grep 'core = ' core/global/version.tres | cut -d '"' -f2)
GODOT ?= godot
GODOT_VERSION ?= $(shell $(GODOT) --version | grep -o '[0-9].*[0-9]\.' | sed 's/.$$//')
GODOT_RELEASE ?= $(shell $(GODOT) --version | grep -oP '^[0-9].*?[a-z]\.' | grep -oP '[a-z]+')
GODOT_REVISION := $(GODOT_VERSION).$(GODOT_RELEASE)
GAMESCOPE ?= gamescope
GAMESCOPE_CMD ?= $(GAMESCOPE) -e --xwayland-count 2 --
BUILD_TYPE ?= release

EXPORT_TEMPLATE ?= $(HOME)/.local/share/godot/export_templates/$(GODOT_REVISION)/linux_$(BUILD_TYPE).x86_64
#EXPORT_TEMPLATE_URL ?= https://downloads.tuxfamily.org/godotengine/$(GODOT_VERSION)/Godot_v$(GODOT_VERSION)-$(GODOT_RELEASE)_export_templates.tpz
EXPORT_TEMPLATE_URL ?= https://github.com/godotengine/godot/releases/download/$(GODOT_VERSION)-$(GODOT_RELEASE)/Godot_v$(GODOT_VERSION)-$(GODOT_RELEASE)_export_templates.tpz

ALL_EXTENSIONS := ./addons/core/bin/libopengamepadui-core.linux.template_$(BUILD_TYPE).x86_64.so
ALL_EXTENSION_FILES := $(shell find ./extensions/ -regex  '.*\(\.rs|\.toml\|\.lock\)$$')
ALL_GDSCRIPT := $(shell find ./ -name '*.gd')
ALL_SCENES := $(shell find ./ -name '*.tscn')
ALL_RESOURCES := $(shell find ./ -regex  '.*\(\.tres\|\.svg\|\.png\)$$')
PROJECT_FILES := $(ALL_EXTENSIONS) $(ALL_GDSCRIPT) $(ALL_SCENES) $(ALL_RESOURCES)

# Docker image variables
IMAGE_NAME ?= ghcr.io/shadowblip/opengamepadui-builder
IMAGE_TAG ?= latest

# Remote debugging variables 
SSH_USER ?= deck
SSH_HOST ?= 192.168.0.65
SSH_MOUNT_PATH ?= /tmp/remote
SSH_DATA_PATH ?= /home/$(SSH_USER)/Projects

# systemd-sysext variables 
SYSEXT_ID ?= steamos
SYSEXT_VERSION_ID ?= 3.6.3
SYSEXT_LIBIIO_VERSION ?= 0.26-3
SYSEXT_LIBSERIALPORT_VERSION ?= 0.1.2-1

# Include any user defined settings
-include settings.mk

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@echo "Godot Version: '$(GODOT_VERSION)'"
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: install 
install: rootfs ## Install OpenGamepadUI (default: ~/.local)
	cd $(ROOTFS) && make install PREFIX=$(PREFIX)

.PHONY: uninstall
uninstall: ## Uninstall OpenGamepadUI
	cd $(ROOTFS) && make uninstall PREFIX=$(PREFIX)

##@ Systemd Extension

.PHONY: enable-ext
enable-ext: ## Enable systemd extensions
	mkdir -p $(HOME)/.var/lib/extensions
	sudo ln -s $(HOME)/.var/lib/extensions /var/lib/extensions
	sudo systemctl enable systemd-sysext
	sudo systemctl start systemd-sysext
	systemd-sysext status

.PHONY: disable-ext
disable-ext: ## Disable systemd extensions
	sudo systemctl stop systemd-sysext
	sudo systemctl disable systemd-sysext

.PHONY: install-ext
install-ext: systemd-sysext ## Install OpenGamepadUI as a systemd extension
	cp dist/opengamepadui.raw $(HOME)/.var/lib/extensions
	sudo systemd-sysext refresh
	systemd-sysext status

.PHONY: uninstall-ext
uninstall-ext: ## Uninstall the OpenGamepadUI systemd extension
	rm -rf $(HOME)/.var/lib/extensions
	sudo systemd-sysext refresh
	systemd-sysext status

##@ Development

ifeq ($(GAMESCOPE_CMD),)
HEADLESS := --headless
endif

.PHONY: test
test: $(IMPORT_DIR) ## Run all unit tests
	$(GAMESCOPE_CMD) $(GODOT) \
		--position 320,140 \
		--path $(PWD) $(HEADLESS) \
		--script res://addons/gut/gut_cmdln.gd

.PHONY: build
build: build/opengamepad-ui.x86_64 ## Build and export the project
build/opengamepad-ui.x86_64: $(IMPORT_DIR) $(PROJECT_FILES) $(EXPORT_TEMPLATE)
	@echo "Building OpenGamepadUI v$(OGUI_VERSION)"
	mkdir -p build
	$(GODOT) -v --headless --export-$(BUILD_TYPE) "Linux/X11"

.PHONY: metadata
metadata: build/metadata.json ## Build update metadata
build/metadata.json: build/opengamepad-ui.x86_64 assets/crypto/keys/opengamepadui.key
	@echo "Building update metadata"
	@FILE_SIGS='{'; \
	cd build; \
	# Sign any GDExtension libraries \
	for lib in `ls *.so`; do \
		echo "Signing file: $$lib"; \
		SIG=$$(openssl dgst -sha256 -sign ../assets/crypto/keys/opengamepadui.key $$lib | base64 -w 0); \
		HASH=$$(sha256sum $$lib | cut -d' ' -f1); \
		FILE_SIGS="$$FILE_SIGS\"$$lib\": {\"signature\": \"$$SIG\", \"hash\": \"$$HASH\"}, "; \
	done; \
	# Sign the binary files \
	echo "Signing file: opengamepad-ui.x86_64"; \
	SIG=$$(openssl dgst -sha256 -sign ../assets/crypto/keys/opengamepadui.key opengamepad-ui.x86_64 | base64 -w 0); \
	HASH=$$(sha256sum opengamepad-ui.x86_64 | cut -d' ' -f1); \
	FILE_SIGS="$$FILE_SIGS\"opengamepad-ui.x86_64\": {\"signature\": \"$$SIG\", \"hash\": \"$$HASH\"}, "; \
	echo "Signing file: opengamepad-ui.pck"; \
	SIG=$$(openssl dgst -sha256 -sign ../assets/crypto/keys/opengamepadui.key opengamepad-ui.pck | base64 -w 0); \
	HASH=$$(sha256sum opengamepad-ui.pck | cut -d' ' -f1); \
	FILE_SIGS="$$FILE_SIGS\"opengamepad-ui.pck\": {\"signature\": \"$$SIG\", \"hash\": \"$$HASH\"}}"; \
	# Write out the signatures to metadata.json \
	echo "{\"version\": \"$(OGUI_VERSION)\", \"engine_version\": \"$(GODOT_REVISION)\", \"files\": $$FILE_SIGS}" > metadata.json

	@echo "Metadata written to $@"


.PHONY: import
import: $(IMPORT_DIR) ## Import project assets
$(IMPORT_DIR): $(ALL_EXTENSIONS)
	@echo "Importing project assets. This will take some time..."
	command -v $(GODOT) > /dev/null 2>&1
	$(GODOT) --headless --import > /dev/null 2>&1 || echo "Finished"
	touch $(IMPORT_DIR)

.PHONY: force-import
force-import: $(ALL_EXTENSIONS)
	@echo "Force importing project assets. This will take some time..."
	command -v $(GODOT) > /dev/null 2>&1
	$(GODOT) --headless --import > /dev/null 2>&1 || echo "Finished"
	$(GODOT) --headless --import > /dev/null 2>&1 || echo "Finished"

.PHONY: extensions
extensions: $(ALL_EXTENSIONS) ## Build engine extensions
$(ALL_EXTENSIONS) &: $(ALL_EXTENSION_FILES)
	@echo "Building engine extensions..."
	cd ./extensions && $(MAKE) build

.PHONY: edit
edit: $(IMPORT_DIR) ## Open the project in the Godot editor
	$(GODOT) --editor .

.PHONY: purge 
purge: clean ## Remove all build artifacts including engine extensions
	rm -rf $(ROOTFS)
	cd ./extensions && $(MAKE) clean

.PHONY: clean
clean: ## Remove Godot build artifacts
	rm -rf build
	rm -rf $(CACHE_DIR)
	rm -rf dist
	rm -rf $(IMPORT_DIR)

.PHONY: run run-force
run: build/opengamepad-ui.x86_64 run-force ## Run the project in gamescope
run-force:
	$(GAMESCOPE) -w 1920 -h 1080 -f \
		--xwayland-count 2 -- ./build/opengamepad-ui.x86_64

$(EXPORT_TEMPLATE):
	mkdir -p $(HOME)/.local/share/godot/export_templates
	@echo "Downloading export templates"
	wget $(EXPORT_TEMPLATE_URL) -O $(HOME)/.local/share/godot/export_templates/templates.zip
	@echo "Extracting export templates"
	unzip $(HOME)/.local/share/godot/export_templates/templates.zip -d $(HOME)/.local/share/godot/export_templates/
	rm $(HOME)/.local/share/godot/export_templates/templates.zip
	mv $(HOME)/.local/share/godot/export_templates/templates $(@D)

.PHONY: debug 
debug: $(IMPORT_DIR) ## Run the project in debug mode in gamescope
	$(GAMESCOPE) -e --xwayland-count 2 --expose-wayland -- \
		$(GODOT) --path $(PWD) --remote-debug tcp://127.0.0.1:6007 \
		--position 320,140 res://entrypoint.tscn

.PHONY: debug-overlay
debug-overlay: $(IMPORT_DIR) ## Run the project in debug mode in gamescope with --overlay-mode
	$(GAMESCOPE) --xwayland-count 2 -- \
		$(GODOT) --path $(PWD) --remote-debug tcp://127.0.0.1:6007 \
		--position 320,140 res://entrypoint.tscn --overlay-mode -- steam -gamepadui -steamos3 -steampal -steamdeck

.PHONY: docs
docs: docs/api/classes/.generated ## Generate docs
docs/api/classes/.generated: $(IMPORT_DIR) $(ALL_GDSCRIPT)
	rm -rf docs/api/classes
	mkdir -p docs/api/classes
	$(GODOT) \
		--editor \
		--quit \
		--doctool docs/api/classes \
		--no-docbase \
		--gdextension-docs
	$(GODOT) \
		--editor \
		--path $(PWD) \
		--quit \
		--doctool docs/api/classes \
		--no-docbase \
		--gdscript-docs core
	rm -rf docs/api/classes/core--*
	$(MAKE) -C docs/api rst

.PHONY: inspect
inspect: $(IMPORT_DIR) ## Launch Gamescope inspector
	$(GODOT) --path $(PWD) res://core/ui/menu/debug/gamescope_inspector.tscn


.PHONY: signing-keys
signing-keys: assets/crypto/keys/opengamepadui.pub ## Generate a signing keypair to sign packages

assets/crypto/keys/opengamepadui.key:
	@echo "Generating signing keys"
	mkdir -p assets/crypto/keys
	openssl genrsa -out $@ 4096

assets/crypto/keys/opengamepadui.pub: assets/crypto/keys/opengamepadui.key
	openssl rsa -in $^ -outform PEM -pubout -out $@


##@ Remote Debugging

.PHONY: deploy
deploy: dist-archive ## Build and deploy to a remote device
	scp dist/opengamepadui.tar.gz $(SSH_USER)@$(SSH_HOST):$(SSH_DATA_PATH)
	ssh -t $(SSH_USER)@$(SSH_HOST) tar xvfz "$(SSH_DATA_PATH)/opengamepadui.tar.gz"


.PHONY: deploy-update
deploy-update: dist/update.zip ## Build and deploy update zip to remote device
	ssh $(SSH_USER)@$(SSH_HOST) mkdir -p .local/share/opengamepadui/updates
	scp dist/update.zip $(SSH_USER)@$(SSH_HOST):~/.local/share/opengamepadui/updates


.PHONY: deploy-ext
deploy-ext: dist-ext ## Build and deploy systemd extension to remote device
	ssh $(SSH_USER)@$(SSH_HOST) mkdir -p .var/lib/extensions .config/systemd/user .local/bin
	scp dist/opengamepadui.raw $(SSH_USER)@$(SSH_HOST):~/.var/lib/extensions
	scp rootfs/usr/lib/systemd/user/systemd-sysext-updater.service $(SSH_USER)@$(SSH_HOST):~/.config/systemd/user
	scp rootfs/usr/share/opengamepadui/scripts/update_systemd_ext.sh $(SSH_USER)@$(SSH_HOST):~/.local/bin
	ssh -t $(SSH_USER)@$(SSH_HOST) systemctl --user enable --now systemd-sysext-updater || echo "WARN: failed to restart sysext updater"
	sleep 3
	ssh -t $(SSH_USER)@$(SSH_HOST) sudo systemd-sysext refresh
	ssh $(SSH_USER)@$(SSH_HOST) systemd-sysext status


.PHONY: deploy-nix
deploy-nix: dist-nix ## Build and deploy the nix package to a remote device
	nix copy $$(cat ./dist/opengamepadui.nix) --to ssh://$(SSH_USER)@$(SSH_HOST)
	@echo "Copied OpenGamepadUI package: $$(cat ./dist/opengamepadui.nix)"
	@echo "Modifying config to use package"
	@DEPLOY_SCRIPT=$$(mktemp); set -e; \
		echo "set -ex" >> $$DEPLOY_SCRIPT; \
		echo "echo 'Removing old package references'" >> $$DEPLOY_SCRIPT; \
	  echo "sed -i '/.*programs.opengamepadui.package.*/d' /etc/nixos/configuration.nix" >> $$DEPLOY_SCRIPT; \
		echo "echo 'Setting opengamepadui package in /etc/nixos/configuration.nix'" >> $$DEPLOY_SCRIPT; \
		echo "sed -i 's|^}|  programs.opengamepadui.package = $$(cat ./dist/opengamepadui.nix);\n}|g' /etc/nixos/configuration.nix" >> $$DEPLOY_SCRIPT; \
		echo "echo 'Applying new configuration'" >> $$DEPLOY_SCRIPT; \
		echo "nixos-rebuild switch --impure" >> $$DEPLOY_SCRIPT; \
		echo "echo 'Applying new configuration'" >> $$DEPLOY_SCRIPT; \
		echo "rm $$DEPLOY_SCRIPT" >> $$DEPLOY_SCRIPT; \
		echo "Copying deployment script to target device"; \
		scp $$DEPLOY_SCRIPT $(SSH_USER)@$(SSH_HOST):$$DEPLOY_SCRIPT; \
		echo "Executing deployment script"; \
		ssh -t $(SSH_USER)@$(SSH_HOST) sudo bash $$DEPLOY_SCRIPT; \
		rm $$DEPLOY_SCRIPT


.PHONY: enable-debug
enable-debug: ## Set OpenGamepadUI command to use remote debug on target device
	ssh $(SSH_USER)@$(SSH_HOST) mkdir -p .config/environment.d
	echo 'CLIENTCMD="opengamepadui --remote-debug tcp://127.0.0.1:6007"' | \
		ssh $(SSH_USER)@$(SSH_HOST) bash -c \
		'cat > .config/environment.d/opengamepadui-session.conf'


.PHONY: tunnel
tunnel: ## Create an SSH tunnel to allow remote debugging
	ssh $(SSH_USER)@$(SSH_HOST) -N -f -R 6007:localhost:6007


##@ Distribution

.PHONY: rootfs
rootfs: build/opengamepad-ui.x86_64
	rm -rf $(ROOTFS)
	mkdir -p $(ROOTFS)
	cp -r rootfs/* $(ROOTFS)
	mkdir -p $(ROOTFS)/usr/share/opengamepadui
	cp -r build/*.so $(ROOTFS)/usr/share/opengamepadui
	cp -r build/opengamepad-ui.x86_64 $(ROOTFS)/usr/share/opengamepadui
	cp -r build/opengamepad-ui.pck $(ROOTFS)/usr/share/opengamepadui
	cp ./extensions/target/release/reaper $(ROOTFS)/usr/share/opengamepadui
	touch $(ROOTFS)/.gdignore


.PHONY: dist 
dist: dist/opengamepadui.tar.gz dist/opengamepadui.raw dist/update.zip dist/opengamepadui-$(OGUI_VERSION)-1.x86_64.rpm ## Create all redistributable versions of the project
	cd dist && sha256sum opengamepadui-$(OGUI_VERSION)-1.x86_64.rpm > opengamepadui-$(OGUI_VERSION)-1.x86_64.rpm.sha256.txt
	cd dist && sha256sum opengamepadui.tar.gz > opengamepadui.tar.gz.sha256.txt
	cd dist && sha256sum opengamepadui.raw > opengamepadui.raw.sha256.txt
	cd dist && sha256sum update.zip > update.zip.sha256.txt

.PHONY: dist-rpm
dist-rpm: dist/opengamepadui-$(OGUI_VERSION)-1.x86_64.rpm ## Create a redistributable RPM
dist/opengamepadui-$(OGUI_VERSION)-1.x86_64.rpm: dist/opengamepadui.tar.gz
	@echo "Building redistributable RPM package"
	mkdir -p dist $(HOME)/rpmbuild/SOURCES
	cp dist/opengamepadui.tar.gz $(HOME)/rpmbuild/SOURCES
	rpmbuild -bb package/rpm/opengamepadui.spec
	cp $(HOME)/rpmbuild/RPMS/x86_64/opengamepadui-$(OGUI_VERSION)-1.x86_64.rpm dist

.PHONY: dist-archive
dist-archive: dist/opengamepadui.tar.gz ## Create a redistributable tar.gz of the project
dist/opengamepadui.tar.gz: rootfs
	@echo "Building redistributable tar.gz archive"
	mkdir -p dist
	mv $(ROOTFS) $(CACHE_DIR)/opengamepadui
	cd $(CACHE_DIR) && tar cvfz opengamepadui.tar.gz opengamepadui
	mv $(CACHE_DIR)/opengamepadui.tar.gz dist
	mv $(CACHE_DIR)/opengamepadui $(ROOTFS)


.PHONY: dist-update-zip
dist-update-zip: dist/update.zip ## Create an update zip archive
dist/update.zip: build/metadata.json
	@echo "Building redistributable update zip"
	mkdir -p $(CACHE_DIR)
	rm -rf $(CACHE_DIR)/update.zip
	cd build && zip -5 ../$(CACHE_DIR)/update *.so opengamepad-ui.* metadata.json
	mkdir -p dist
	cp $(CACHE_DIR)/update.zip $@


.PHONY: dist-nix
dist-nix: dist/opengamepadui.nix ## Create a nix package
dist/opengamepadui.nix: $(IMPORT_DIR) $(PROJECT_FILES)
	@echo "Building nix package"
	mkdir -p dist
	nix build --impure \
		--expr 'with import (builtins.getFlake "gitlab:shadowapex/os-flake?ref=main").inputs.nixpkgs {}; callPackage ./package/nix/package.nix {}'
	echo $$(file result | cut -d' ' -f5) > $@
	@rm result
	@echo "Built OpenGamepadUI package: $$(cat ./dist/opengamepadui.nix)"


# https://blogs.igalia.com/berto/2022/09/13/adding-software-to-the-steam-deck-with-systemd-sysext/
.PHONY: dist-ext
dist-ext: dist/opengamepadui.raw ## Create a systemd-sysext extension archive
dist/opengamepadui.raw: dist/opengamepadui.tar.gz $(CACHE_DIR)/gamescope-session.tar.gz $(CACHE_DIR)/gamescope-session-opengamepadui.tar.gz $(CACHE_DIR)/powerstation.tar.gz $(CACHE_DIR)/inputplumber.tar.gz
	@echo "Building redistributable systemd extension"
	mkdir -p dist
	rm -rf dist/opengamepadui.raw $(CACHE_DIR)/opengamepadui.raw
	cp dist/opengamepadui.tar.gz $(CACHE_DIR)
	cd $(CACHE_DIR) && tar xvfz opengamepadui.tar.gz opengamepadui/usr
	mkdir -p $(CACHE_DIR)/opengamepadui/usr/lib/extension-release.d
	echo ID=$(SYSEXT_ID) > $(CACHE_DIR)/opengamepadui/usr/lib/extension-release.d/extension-release.opengamepadui
	echo VERSION_ID=$(SYSEXT_VERSION_ID) >> $(CACHE_DIR)/opengamepadui/usr/lib/extension-release.d/extension-release.opengamepadui

	@# Copy gamescope-session into the extension
	cd $(CACHE_DIR) && tar xvfz gamescope-session.tar.gz
	cp -r $(CACHE_DIR)/gamescope-session-main/usr/* $(CACHE_DIR)/opengamepadui/usr

	@# Copy opengamepadui-session into the extension
	cd $(CACHE_DIR) && tar xvfz gamescope-session-opengamepadui.tar.gz
	cp -r $(CACHE_DIR)/gamescope-session-opengamepadui-main/usr/* $(CACHE_DIR)/opengamepadui/usr

	@# Copy powerstation into the extension
	cd $(CACHE_DIR) && tar xvfz powerstation.tar.gz
	cp -r $(CACHE_DIR)/powerstation/usr/* $(CACHE_DIR)/opengamepadui/usr

	@# Copy inputplumber into the extension
	cd $(CACHE_DIR) && tar xvfz inputplumber.tar.gz
	cp -r $(CACHE_DIR)/inputplumber/usr/* $(CACHE_DIR)/opengamepadui/usr

	@# Install libserialport for inputplumber in the extension for libiio compatibility in SteamOS
	cp -r $(CACHE_DIR)/libserialport/usr/lib/libserialport* $(CACHE_DIR)/opengamepadui/usr/lib
	
	@# Install libiio for inputplumber in the extension for SteamOS compatibility
	cp -r $(CACHE_DIR)/libiio/usr/lib/libiio* $(CACHE_DIR)/opengamepadui/usr/lib

	@# Build the extension archive
	cd $(CACHE_DIR) && mksquashfs opengamepadui opengamepadui.raw
	rm -rf $(CACHE_DIR)/opengamepadui $(CACHE_DIR)/gamescope-session-opengamepadui-main $(CACHE_DIR)/gamescope-session-main
	mv $(CACHE_DIR)/opengamepadui.raw $@


$(CACHE_DIR)/gamescope-session.tar.gz:
	wget -O $@ https://github.com/ChimeraOS/gamescope-session/archive/refs/heads/main.tar.gz


$(CACHE_DIR)/gamescope-session-opengamepadui.tar.gz:
	wget -O $@ https://github.com/ShadowBlip/gamescope-session-opengamepadui/archive/refs/heads/main.tar.gz


$(CACHE_DIR)/powerstation.tar.gz:
	export PS_VERSION=$$(curl -s https://api.github.com/repos/ShadowBlip/PowerStation/releases/latest | jq -r '.name') && \
		wget -O $@ https://github.com/ShadowBlip/PowerStation/releases/download/$${PS_VERSION}/powerstation-x86_64.tar.gz


$(CACHE_DIR)/inputplumber.tar.gz: $(CACHE_DIR)/libiio $(CACHE_DIR)/libserialport
	export IP_VERSION=$$(curl -s https://api.github.com/repos/ShadowBlip/InputPlumber/releases/latest | jq -r '.name') && \
		wget -O $@ https://github.com/ShadowBlip/InputPlumber/releases/download/$${IP_VERSION}/inputplumber-x86_64.tar.gz


LIBIIO_URL ?= https://mirror.rackspace.com/archlinux/extra/os/x86_64/libiio-$(SYSEXT_LIBIIO_VERSION)-x86_64.pkg.tar.zst
$(CACHE_DIR)/libiio:
	rm -rf $(CACHE_DIR)/libiio*
	wget $(LIBIIO_URL) \
		-O $(CACHE_DIR)/libiio.tar.zst
	zstd -d $(CACHE_DIR)/libiio.tar.zst
	mkdir -p $(CACHE_DIR)/libiio
	tar xvf $(CACHE_DIR)/libiio.tar -C $(CACHE_DIR)/libiio


LIBSERIALPORT_URL ?= https://mirror.rackspace.com/archlinux/extra/os/x86_64/libserialport-$(SYSEXT_LIBSERIALPORT_VERSION)-x86_64.pkg.tar.zst
$(CACHE_DIR)/libserialport:
	rm -rf $(CACHE_DIR)/libserialport*
	wget $(LIBSERIALPORT_URL) \
	  -O $(CACHE_DIR)/libserialport.tar.zst
	zstd -d $(CACHE_DIR)/libserialport.tar.zst
	mkdir -p $(CACHE_DIR)/libserialport
	tar xvf $(CACHE_DIR)/libserialport.tar -C $(CACHE_DIR)/libserialport

.PHONY: update-pkgbuild-hash
update-pkgbuild-hash: dist/opengamepadui.tar.gz ## Update the PKGBUILD hash
	sed -i "s#^sha256sums=.*#sha256sums=('$$(cat dist/opengamepadui.tar.gz.sha256.txt | cut -d' ' -f1)')#g" \
		package/archlinux/PKGBUILD

# Refer to .releaserc.yaml for release configuration
.PHONY: release 
release: ## Publish a release with semantic release 
	npx semantic-release

# E.g. make in-docker TARGET=build
.PHONY: in-docker
in-docker:
	@# Run the given make target inside Docker
	docker run --rm \
		-v $(PWD):/src \
		--workdir /src \
		-e HOME=/home/build \
		-e PWD=/src \
		--user $(shell id -u):$(shell id -g) \
		$(IMAGE_NAME):$(IMAGE_TAG) \
		make GODOT=/usr/sbin/godot $(TARGET)

.PHONY: docker-builder
docker-builder:
	@# Pull any existing image to cache it
	docker pull $(IMAGE_NAME):$(IMAGE_TAG) || echo "No remote image to pull"
	@# Build the Docker image that will build the project
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) -f docker/Dockerfile ./docker

.PHONY: docker-builder-push
docker-builder-push: docker-builder
	docker push $(IMAGE_NAME):$(IMAGE_TAG)
