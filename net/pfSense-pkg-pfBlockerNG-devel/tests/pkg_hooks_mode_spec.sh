#!/bin/sh

set -eu

ROOT=$(cd -- "$(dirname -- "$0")/../../.." && pwd)
PHP_BIN=$(command -v php || true)
TMP=${TMPDIR:-/tmp}/pfb-pkg-hooks-mode.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

[ -n "$PHP_BIN" ] || fail 'host PHP is required'
mkdir -p "$TMP/usr/local/bin" "$TMP/etc/inc" "$TMP/var/db/pfblockerng"
chmod 0775 "$TMP/var/db/pfblockerng"

cat >"$TMP/usr/local/bin/php" <<'EOF'
#!/bin/sh
case "${1-}" in
	-r)
		exec "$PFB_HOST_PHP" -r "$2"
		;;
	-f)
		exit 0
		;;
	*)
		exit 2
		;;
esac
EOF
chmod 755 "$TMP/usr/local/bin/php"

cat >"$TMP/etc/inc/config.inc" <<'EOF'
<?php
function config_get_path(string $path, $default = NULL)
{
	if ($path === 'installedpackages/pfblockerng/config/0/settings_family') {
		return '';
	}
	if ($path === 'installedpackages') {
		return ['pfblockerng' => ['config' => [['pfb_keep' => 'off']]]];
	}
	return $default;
}
function dump_xml_config(array $value, string $name): string
{
	return '<?xml version="1.0"?><' . $name . '><family>'
		. htmlspecialchars((string) $value['family'], ENT_XML1 | ENT_QUOTES, 'UTF-8')
		. '</family><payload>'
		. htmlspecialchars((string) $value['payload'], ENT_XML1 | ENT_QUOTES, 'UTF-8')
		. '</payload></' . $name . '>';
}
EOF

for channel in devel nightly; do
	script="$ROOT/net/pfSense-pkg-pfBlockerNG-$channel/files/pkg-install.in"
	if PFB_HOST_PHP="$PHP_BIN" PKG_ROOTDIR="$TMP" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL; then
		fail "$channel accepted group/world-writable settings directory"
	fi
	[ ! -e "$TMP/var/db/pfblockerng/settings-3.2.xml" ] \
		|| fail "$channel wrote a slot after rejecting unsafe directory"
done

echo 'PASS: v4 settings directory mode guard'
