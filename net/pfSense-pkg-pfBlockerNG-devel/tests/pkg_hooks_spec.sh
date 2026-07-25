#!/bin/sh

set -eu

ROOT=$(cd -- "$(dirname -- "$0")/../../.." && pwd)
PHP_BIN=$(command -v php || true)
TMP=${TMPDIR:-/tmp}/pfb-pkg-hooks.$$
LOG=$TMP/php-dispatch.log
HELPER_LOG=$TMP/helper.log
OLD_INCLUDE_LOG=$TMP/old-include.log
CONFIG=$TMP/etc/config.json
mkdir -p "$TMP/usr/local/bin" "$TMP/etc/inc" "$TMP/usr/local/pkg/pfblockerng" "$TMP/var/db"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

assert_hash()
{
	actual=$(git -C "$ROOT" hash-object "$1")
	[ "$actual" = "$2" ] || fail "$1 changed: $actual"
}

assert_mode()
{
	actual=$("$PHP_BIN" -r 'printf("%o", fileperms($argv[1]) & 07777);' "$1")
	[ "$actual" = "$2" ] || fail "$1 mode changed: $actual"
}

[ -n "$PHP_BIN" ] || fail 'host PHP is required for fallback execution'

cat >"$TMP/usr/local/bin/php" <<'EOF'
#!/bin/sh
case "${1-}" in
	-r)
		if [ -n "${PFB_CANARY_SLOT-}" ]; then
			printf '%s' 'canary-sentinel' >"$PFB_CANARY_TARGET"
			ln -s "$PFB_CANARY_TARGET" "${PFB_CANARY_SLOT}.tmp.$$"
		fi
		exec "$PFB_HOST_PHP" -r "$2"
		;;
	-f)
		printf '%s\n' "$*" >>"$PFB_DISPATCH_LOG"
		;;
	*)
		exit 2
		;;
esac
EOF
chmod 755 "$TMP/usr/local/bin/php"

cat >"$TMP/etc/inc/config.inc" <<'EOF'
<?php
function pfb_test_load(): void
{
	global $config;
	if (isset($config)) {
		return;
	}
	$decoded = json_decode((string) file_get_contents((string) getenv('PFB_TEST_CONFIG')), TRUE);
	$config = is_array($decoded) ? $decoded : [];
}
function config_get_path(string $path, $default = NULL)
{
	pfb_test_load();
	global $config;
	$value = $config;
	foreach (explode('/', $path) as $part) {
		if (!is_array($value) || !array_key_exists($part, $value)) {
			return $default;
		}
		$value = $value[$part];
	}
	return $value;
}
function dump_xml_config(array $value, string $name): string
{
	$family = htmlspecialchars((string) $value['family'], ENT_XML1 | ENT_QUOTES, 'UTF-8');
	$payload = htmlspecialchars((string) $value['payload'], ENT_XML1 | ENT_QUOTES, 'UTF-8');
	return '<?xml version="1.0"?><' . $name . '><family>' . $family . '</family><payload>'
		. $payload . '</payload></' . $name . '>';
}
EOF

assert_hash "$ROOT/net/pfSense-pkg-pfBlockerNG/files/pkg-install.in" \
	c192d05db62d9ebe243425fe0e983777652cde27
assert_hash "$ROOT/net/pfSense-pkg-pfBlockerNG/files/pkg-deinstall.in" \
	83d1c3dcab9e12f72791e6b418a538a4c7bbec67

devel="$ROOT/net/pfSense-pkg-pfBlockerNG-devel/files/pkg-install.in"
nightly="$ROOT/net/pfSense-pkg-pfBlockerNG-nightly/files/pkg-install.in"
cmp -s "$devel" "$nightly" || fail 'v4 install templates diverge'

run_case()
{
	channel=$1
	script=$TMP/pkg-install-$channel
	sed "s/%%PORTNAME%%/pfSense-pkg-pfBlockerNG-$channel/g" \
		"$ROOT/net/pfSense-pkg-pfBlockerNG-$channel/files/pkg-install.in" >"$script"
	chmod 755 "$script"

	: >"$LOG"
	: >"$HELPER_LOG"
	: >"$CONFIG"
	mkdir -p "$TMP/var/db/pfblockerng"
	chmod 755 "$TMP/var/db/pfblockerng"
	printf '%s\n' '{"installedpackages":{"otherpackage":{"value":"untouched"}}}' >"$CONFIG"
	rm -f "$TMP"/var/db/pfblockerng/settings-*.xml
	PFB_HOST_PHP="$PHP_BIN" PFB_DISPATCH_LOG="$LOG" PFB_TEST_CONFIG="$CONFIG" \
		PFB_HELPER_LOG="$HELPER_LOG" PKG_ROOTDIR="$TMP" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL
	[ ! -e "$TMP/var/db/pfblockerng/settings-3.2.xml" ] \
		|| fail "$channel saved settings without live owned config"

	printf '%s\n' '{"installedpackages":{"pfblockerng":{"config":[{"pfb_keep":"off","credential":"v3"}]},"pfblockerngglobal":{"nested":{"value":"owned"}},"otherpackage":{"value":"untouched"}}}' >"$CONFIG"
	rm -f "$TMP"/var/db/pfblockerng/settings-*.xml
	PFB_HOST_PHP="$PHP_BIN" PFB_DISPATCH_LOG="$LOG" PFB_TEST_CONFIG="$CONFIG" \
		PFB_HELPER_LOG="$HELPER_LOG" PKG_ROOTDIR="$TMP" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL
	slot="$TMP/var/db/pfblockerng/settings-3.2.xml"
	[ -f "$slot" ] || fail "$channel missing-marker fallback did not save 3.2 slot"
	assert_mode "$TMP/var/db/pfblockerng" 755
	assert_mode "$slot" 600
	"$PHP_BIN" -r '
$xml = simplexml_load_file($argv[1]);
$bytes = base64_decode((string) $xml->payload, TRUE);
$owned = is_string($bytes) ? unserialize($bytes, ["allowed_classes" => FALSE]) : FALSE;
if ((string) $xml->family !== "3.2" || !is_array($owned)
    || ($owned["pfblockerng"]["config"][0]["credential"] ?? NULL) !== "v3"
    || ($owned["pfblockerng"]["config"][0]["pfb_keep"] ?? NULL) !== "off"
    || ($owned["pfblockerngglobal"]["nested"]["value"] ?? NULL) !== "owned") {
    exit(1);
}
' "$slot" || fail "$channel 3.2 slot payload mismatch"
	[ ! -f "$TMP/var/db/pfblockerng/settings-4.0.xml" ] || fail "$channel restored target slot"

	printf '%s\n' '{"installedpackages":{"pfblockerng":{"config":[{"settings_family":"4.0","pfb_keep":"off","credential":"v4"}]}}}' >"$CONFIG"
	rm -f "$TMP"/var/db/pfblockerng/settings-*.xml
	PFB_HOST_PHP="$PHP_BIN" PFB_DISPATCH_LOG="$LOG" PFB_TEST_CONFIG="$CONFIG" \
		PFB_HELPER_LOG="$HELPER_LOG" PKG_ROOTDIR="$TMP" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL
	[ -f "$TMP/var/db/pfblockerng/settings-4.0.xml" ] || fail "$channel valid marker did not save 4.0 slot"
	[ ! -f "$TMP/var/db/pfblockerng/settings-3.2.xml" ] || fail "$channel valid marker wrote wrong slot"
	grep -F '<family>4.0</family>' "$TMP/var/db/pfblockerng/settings-4.0.xml" >/dev/null \
		|| fail "$channel valid marker slot family mismatch"

	printf '%s\n' '{"installedpackages":{"pfblockerng":{"config":[{"settings_family":"bogus","pfb_keep":"off"}]}}}' >"$CONFIG"
	rm -f "$TMP"/var/db/pfblockerng/settings-*.xml
	if PFB_HOST_PHP="$PHP_BIN" PFB_DISPATCH_LOG="$LOG" PFB_TEST_CONFIG="$CONFIG" \
		PFB_HELPER_LOG="$HELPER_LOG" PKG_ROOTDIR="$TMP" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL; then
		fail "$channel accepted invalid settings marker"
	fi
	[ ! -e "$TMP/var/db/pfblockerng/settings-3.2.xml" ] \
		&& [ ! -e "$TMP/var/db/pfblockerng/settings-4.0.xml" ] \
		|| fail "$channel invalid marker wrote a slot"

	cat >"$TMP/usr/local/pkg/pfblockerng/pfblockerng.inc" <<'EOF'
<?php
file_put_contents((string) getenv('PFB_OLD_INCLUDE_LOG'), "loaded\n", FILE_APPEND);
exit(97);
EOF
	printf '%s\n' '{"installedpackages":{"pfblockerng":{"config":[{"settings_family":"4.1","pfb_keep":"off","credential":"canary"}]}}}' >"$CONFIG"
	rm -f "$TMP"/var/db/pfblockerng/settings-*.xml
	: >"$OLD_INCLUDE_LOG"
	PFB_HOST_PHP="$PHP_BIN" PFB_DISPATCH_LOG="$LOG" PFB_TEST_CONFIG="$CONFIG" \
		PFB_HELPER_LOG="$HELPER_LOG" PFB_OLD_INCLUDE_LOG="$OLD_INCLUDE_LOG" PKG_ROOTDIR="$TMP" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL \
		|| fail "$channel loaded outgoing pfblockerng.inc"
	[ ! -s "$OLD_INCLUDE_LOG" ] || fail "$channel outgoing include had side effects"
	[ -f "$TMP/var/db/pfblockerng/settings-4.1.xml" ] \
		|| fail "$channel self-contained fallback did not save 4.1 slot"
	rm -f "$TMP/usr/local/pkg/pfblockerng/pfblockerng.inc"

	canary="$TMP/canary.xml"
	rm -f "$TMP"/var/db/pfblockerng/settings-*.xml.tmp.* "$canary"
	PFB_HOST_PHP="$PHP_BIN" PFB_DISPATCH_LOG="$LOG" PFB_TEST_CONFIG="$CONFIG" \
		PFB_HELPER_LOG="$HELPER_LOG" PFB_CANARY_SLOT="$TMP/var/db/pfblockerng/settings-4.1.xml" \
		PFB_CANARY_TARGET="$canary" PKG_ROOTDIR="$TMP" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL \
		|| fail "$channel temp canary PRE-INSTALL failed"
	[ "$(cat "$canary")" = canary-sentinel ] || fail "$channel temp canary was overwritten"
	canary_link=$(find "$TMP/var/db/pfblockerng" -type l -name 'settings-4.1.xml.tmp.*' -print -quit)
	[ -n "$canary_link" ] || fail "$channel temp canary symlink was replaced"

	: >"$LOG"
	PFB_HOST_PHP="$PHP_BIN" PFB_DISPATCH_LOG="$LOG" PFB_TEST_CONFIG="$CONFIG" \
		PFB_HELPER_LOG="$HELPER_LOG" PKG_ROOTDIR="$TMP" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" POST-INSTALL
	grep -F -- "-f $TMP/etc/rc.packages pfSense-pkg-pfBlockerNG-$channel POST-INSTALL" "$LOG" >/dev/null \
		|| fail "$channel POST-INSTALL rc.packages dispatch changed"
}

run_case devel
run_case nightly

echo 'PASS: v4 package hooks'
