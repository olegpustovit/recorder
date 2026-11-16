# SwiftPM only: works with Xcode or Command Line Tools. See CLAUDE.md.
APP      := build/Recorder.app
VERSION  ?= $(shell scripts/version.sh version)
BUILD    ?= $(shell scripts/version.sh build)
DEVELOPER_DIR ?= $(shell xcode-select -p)
export DEVELOPER_DIR
# Testing is outside the default search path in both developer toolchains.
TEST_ROOT := $(if $(wildcard $(DEVELOPER_DIR)/Platforms/MacOSX.platform),$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer,$(DEVELOPER_DIR)/Library/Developer)
TEST_FRAMEWORKS := $(TEST_ROOT)/$(if $(wildcard $(DEVELOPER_DIR)/Platforms/MacOSX.platform),Library/)Frameworks
TESTFLAGS := -Xswiftc -F -Xswiftc "$(TEST_FRAMEWORKS)" -Xlinker -F -Xlinker "$(TEST_FRAMEWORKS)" \
             -Xlinker -rpath -Xlinker "$(TEST_FRAMEWORKS)" -Xlinker -rpath -Xlinker "$(TEST_ROOT)/usr/lib"
# Stable identity keeps TCC grants (Screen Recording, Accessibility) across rebuilds. `-` = ad-hoc (grants reset every build).
# A Developer ID in the keychain wins: same signer as the released app, so installs keep its grants. It lives in
# recorder-signing.keychain (empty password, so it unlocks over SSH; the key is already in plain text in .apple).
SIGN_KC  := $(HOME)/Library/Keychains/recorder-signing.keychain-db
DEV_ID   := $(shell security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
# Apple Development (same team) is the next best: Apple-anchored, stable across rebuilds, no extra cert to create.
APPLE_DEV := $(shell security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
SIGN_ID  ?= $(or $(DEV_ID),$(APPLE_DEV),$(shell security find-identity -p codesigning | grep -q "Recorder Dev" && echo "Recorder Dev" || echo -))
# Over SSH the login keychain is locked ("User interaction is not allowed"); unlock it in the terminal first.
UNLOCK   := kc="$$HOME/Library/Keychains/login.keychain-db"; security show-keychain-info "$$kc" >/dev/null 2>&1 || security unlock-keychain "$$kc"
CONFIG   ?= release
GALLERY_PNG ?= build/signal-ui-gallery.png

.PHONY: build test app mcp-smoke run dev gallery gallery-advanced gallery-png install uninstall clean cert
build:
	swift build --build-system native -c $(CONFIG)

# make test                 -> all tests
# make test FILTER=timeMap  -> one test / suite
test:
	swift test --build-system native $(TESTFLAGS) $(if $(FILTER),--filter $(FILTER))

app: build
	@[ ! -e "$(SIGN_KC)" ] || security unlock-keychain -p "" "$(SIGN_KC)"
	APP="$(APP)" BINARY=".build/$(CONFIG)/Recorder" VERSION="$(VERSION)" BUILD="$(BUILD)" SIGN_ID="$(SIGN_ID)" scripts/assemble-app.sh

mcp-smoke: app
	@python3 -c 'import json, subprocess, sys; \
	requests = [{"jsonrpc":"2.0", "id":1, "method":"initialize", "params":{"protocolVersion":"2025-06-18", "capabilities":{}, "clientInfo":{"name":"make mcp-smoke", "version":"1"}}}, {"jsonrpc":"2.0", "id":2, "method":"tools/list"}]; \
	reply = subprocess.run([sys.argv[1], "--mcp"], input="".join(json.dumps(r)+"\n" for r in requests), text=True, capture_output=True, check=True, timeout=30); \
	responses = {r["id"]:r for line in reply.stdout.splitlines() if "id" in (r := json.loads(line))}; \
	assert responses[1]["jsonrpc"] == responses[2]["jsonrpc"] == "2.0", responses; \
	assert responses[1]["result"]["protocolVersion"] == "2025-06-18", responses; \
	assert len(responses[2]["result"]["tools"]) == 9, responses; \
	assert {t["name"] for t in responses[2]["result"]["tools"]} == {"project", "timeline", "transcript", "analyze", "edit", "draft", "render", "export", "ui"}, responses; \
	print("MCP smoke passed: initialize + all nine tools (including edit)")' "$(APP)/Contents/MacOS/Recorder"

run: app
	open $(APP)

# Fast edit loop: incremental debug build, quit the old instance, run in the foreground (logs here, ^C quits).
dev:
	$(MAKE) app CONFIG=debug
	-pkill -f "$(APP)/Contents/MacOS/Recorder"
	$(APP)/Contents/MacOS/Recorder

# Component gallery: interactive AppKit window, or a deterministic PNG for visual review.
gallery: app
	open -n $(APP) --args --ui-gallery

gallery-advanced: app
	open -n $(APP) --args --gallery-advanced

gallery-png: app
	$(APP)/Contents/MacOS/Recorder --selftest ui-kit-png $(GALLERY_PNG)
	open $(GALLERY_PNG)

# Signing identity: Developer ID, else Apple Development, else the self-signed Recorder Dev (created only if neither exists).
install:
	$(if $(DEV_ID)$(APPLE_DEV),,$(MAKE) cert)
	$(MAKE) app APP=build/Recorder.app
	sh scripts/install-app.sh

uninstall:
	rm -rf /Applications/Recorder.app

clean:
	rm -rf .build build

# One-time: self-signed code-signing identity in the login keychain (asks for the keychain password once).
# Remove with: security delete-identity -c "Recorder Dev"
cert:
	@set -eu; $(UNLOCK); \
	if security find-identity -p codesigning | grep -q '"Recorder Dev"'; then \
	  echo "Recorder Dev already exists"; \
	else \
	  cert_tmp=$$(mktemp -d); trap 'rm -rf "$$cert_tmp"' EXIT HUP INT TERM; cd "$$cert_tmp"; \
	  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout k.pem -out c.pem -subj "/CN=Recorder Dev" \
	    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"; \
	  /usr/bin/openssl pkcs12 -export -inkey k.pem -in c.pem -out id.p12 -passout pass:recorder -name "Recorder Dev" \
	    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1; \
	  security import id.p12 -k "$$HOME/Library/Keychains/login.keychain-db" -P recorder -T /usr/bin/codesign; \
	  echo "Created identity: Recorder Dev"; \
	fi
