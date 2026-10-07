# Apple Developer Program なしでローカル用 .app を作る。
#   make app   … リリースビルドして AirUltrawide.app を作り、署名する
#   make run   … app を作って起動
#   make cert  … 自己署名のコード署名証明書をログインキーチェーンに作る（初回のみ）
#   make dist  … 配布用に ad-hoc 署名した app を dist/AirUltrawide-<version>.zip にまとめる
# 自己署名証明書で署名すると、再ビルドしても「画面収録」の許可が外れない。

APP      := AirUltrawide.app
IDENTITY := AirUltrawide Local
BIN      := .build/release/AirUltrawide

.PHONY: app run cert dist clean

VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN) $(APP)/Contents/MacOS/AirUltrawide
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	@if security find-certificate -c "$(IDENTITY)" >/dev/null 2>&1; then \
		codesign --force --entitlements Resources/AirUltrawide.entitlements -s "$(IDENTITY)" $(APP); \
	elif dev=$$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"'); [ -n "$$dev" ]; then \
		codesign --force --entitlements Resources/AirUltrawide.entitlements -s "$$dev" $(APP); \
	else \
		echo "※ 証明書 '$(IDENTITY)' がないため ad-hoc 署名します（make cert で作成可能）"; \
		codesign --force --entitlements Resources/AirUltrawide.entitlements -s - $(APP); \
	fi

run: app
	open $(APP)

cert:
	@tmp=$$(mktemp -d); \
	printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=$(IDENTITY)\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > $$tmp/cfg; \
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout $$tmp/key.pem -out $$tmp/cert.pem -config $$tmp/cfg && \
	openssl pkcs12 -export -legacy -inkey $$tmp/key.pem -in $$tmp/cert.pem -out $$tmp/id.p12 -passout pass:airultrawide 2>/dev/null || \
	openssl pkcs12 -export -inkey $$tmp/key.pem -in $$tmp/cert.pem -out $$tmp/id.p12 -passout pass:airultrawide; \
	security import $$tmp/id.p12 -k ~/Library/Keychains/login.keychain-db -P airultrawide -T /usr/bin/codesign; \
	rm -rf $$tmp; \
	echo "証明書 '$(IDENTITY)' を作成しました"

# 配布用：個人の証明書を埋め込まないよう ad-hoc 署名にする
dist:
	swift build -c release
	rm -rf $(APP) dist
	mkdir -p $(APP)/Contents/MacOS dist
	cp $(BIN) $(APP)/Contents/MacOS/AirUltrawide
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --entitlements Resources/AirUltrawide.entitlements -s - $(APP)
	ditto -c -k --keepParent $(APP) dist/AirUltrawide-$(VERSION).zip
	@echo "dist/AirUltrawide-$(VERSION).zip を作成しました"

clean:
	rm -rf .build $(APP) dist
