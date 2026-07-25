#!/bin/sh

# Behavioral PRE-INSTALL check for the legacy (3.2) fallback.
# Run from the ports worktree: sh tests/pkg-lifecycle/legacy-pre.sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}/pfb-lifecycle-legacy.$$
PHP_BIN=$(command -v php || true)
SCRIPT_SOURCE=$ROOT/net/pfSense-pkg-pfBlockerNG-devel/files/pkg-install.in
TARGET_NAME=pfSense-pkg-pfBlockerNG-devel
TARGET_VERSION=4.0.0.alpha.21
TARGET=$TARGET_NAME-$TARGET_VERSION
ARTIFACT_HASH=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
STATE_ROOT=$TMP/cf/conf/pfblockerng
CONFIG=$TMP/etc/config.json
EVENTS=$TMP/events.log

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

[ -n "$PHP_BIN" ] || fail 'host PHP is required for embedded PRE-INSTALL coverage'
grep -F 'migrate' "$SCRIPT_SOURCE" >/dev/null || fail 'lifecycle has no migrate stage'
grep -F "? 'migrate' : 'restore'" "$SCRIPT_SOURCE" >/dev/null \
	|| fail 'lifecycle does not distinguish first migration from v4 restore'
if grep -Eq "PFB_TRANSITION_STEP=restore|\\\$step[[:space:]]*===[[:space:]]*'restore'" "$SCRIPT_SOURCE"; then
	fail 'package lifecycle invokes restore directly'
fi
mkdir -p "$TMP/etc/inc" "$TMP/usr/local/bin" "$TMP/usr/local/sbin" \
	"$TMP/var/cache/pkg" "$TMP/cf/conf"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Render the ports template before execution; static checks remain against .in.
SCRIPT=$TMP/pkg-install
sed "s/%%PORTNAME%%/$TARGET_NAME/g" "$SCRIPT_SOURCE" >"$SCRIPT"
chmod 755 "$SCRIPT"

printf '%s\n' '#!/bin/sh' "exec \"$PHP_BIN\" \"\$@\"" >"$TMP/usr/local/bin/php"
chmod 755 "$TMP/usr/local/bin/php"

cat >"$TMP/usr/local/sbin/pkg" <<'EOF'
#!/bin/sh
if [ "$1" = config ] && [ "$2" = ABI ]; then
    printf '%s\n' 'FreeBSD:16:amd64'
    exit 0
fi
if [ "$1" = rquery ]; then
    printf '%s\n' "${PFB_TEST_NAME}|4.0.0.alpha.21|FreeBSD:16:amd64|sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    exit 0
fi
if [ "$1" = query ] && [ "$2" = '%n|%v' ]; then
    if [ -n "$3" ] && [ -n "${PFB_TEST_REVERSE_ROWS:-}" ]; then
        printf '%s\n' "$PFB_TEST_REVERSE_ROWS"
    else
        printf '%s\n' "${PFB_TEST_SOURCE_ROWS:-pfSense-pkg-pfBlockerNG|3.2.0}"
    fi
    exit 0
fi
if [ "$1" != query ] || [ "$2" != -F ]; then
    exit 1
fi
case "$4" in
    '%n') printf '%s\n' "${PFB_TEST_NAME}" ;;
    '%v') printf '%s\n' '4.0.0.alpha.21' ;;
    '%q') printf '%s\n' 'FreeBSD:16:amd64' ;;
    '%An=%Av') printf '%s\n' 'commit=0123456789abcdef0123456789abcdef01234567' ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "$TMP/usr/local/sbin/pkg"

cat >"$TMP/etc/inc/config.inc" <<'EOF'
<?php

function pfb_test_load(): void
{
    global $config;
    if (isset($config) && is_array($config)) {
        return;
    }
    $bytes = @file_get_contents((string) getenv('PFB_TEST_CONFIG'));
    $config = is_string($bytes) ? json_decode($bytes, true) : null;
    if (!is_array($config)) {
        $config = [];
    }
}

function config_get_path(string $path, $default = null)
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

function config_set_path(string $path, $value): void
{
    pfb_test_load();
    global $config;
    $cursor =& $config;
    foreach (explode('/', $path) as $part) {
        if (!isset($cursor[$part]) || !is_array($cursor[$part])) {
            $cursor[$part] = [];
        }
        $cursor =& $cursor[$part];
    }
    $cursor = $value;
}

function write_config(string $message): bool
{
    pfb_test_load();
    global $config;
    if (getenv('PFB_TEST_FAIL_WRITE') === '1') {
        return false;
    }
    $journal = (string) getenv('PFB_TEST_JOURNAL');
    if (!is_file($journal)) {
        return false;
    }
    file_put_contents((string) getenv('PFB_TEST_EVENTS'), "config-write-after-journal\n", FILE_APPEND);
    return file_put_contents(
        (string) getenv('PFB_TEST_CONFIG'),
        json_encode($config, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES)
    ) !== false;
}

function config_read_file(bool $primary = false, bool $secondary = false): bool
{
    global $config;
    unset($config);
    pfb_test_load();
    return true;
}

function lock(string $name, int $mode)
{
    $handle = @fopen((string) getenv('PFB_TEST_LOCK'), 'c');
    return $handle !== false && flock($handle, $mode) ? $handle : false;
}

function unlock($handle): bool
{
    flock($handle, LOCK_UN);
    return fclose($handle);
}

function dump_xml_config(array $value, string $name): string
{
    return '<?xml version="1.0"?><' . $name . '><payload>'
        . base64_encode(serialize($value)) . '</payload></' . $name . '>';
}

function parse_xml_config(string $path, string $name): array
{
    $xml = file_get_contents($path);
    $dom = new DOMDocument();
    if (!is_string($xml) || !@$dom->loadXML($xml)
        || $dom->documentElement?->nodeName !== $name) {
        return [];
    }
    $seen = [];
    foreach ($dom->documentElement->childNodes as $child) {
        if ($child->nodeType !== XML_ELEMENT_NODE) {
            continue;
        }
        if (isset($seen[$child->nodeName])) {
            return [];
        }
        $seen[$child->nodeName] = true;
    }
    preg_match('/<payload>([^<]*)<\\/payload>/s', (string) $xml, $matches);
    $value = isset($matches[1]) ? unserialize(base64_decode($matches[1]), ['allowed_classes' => false]) : null;
    return is_array($value) ? $value : [];
}
EOF
cat >"$TMP/etc/inc/util.inc" <<'EOF'
<?php
EOF

cat >"$CONFIG" <<'EOF'
{"installedpackages":{"pfblockerng":{"config":[{"pfb_keep":"off","feed":"legacy"}],"feeds":{"one":"value"}}}}
EOF
: >"$EVENTS"
: >"$TMP/PFB_TEST_LOCK"
artifact="$TMP/var/cache/pkg/$TARGET~fixture.pkg"
: >"$artifact"
chmod 600 "$artifact"

PFB_TEST_NAME="$TARGET_NAME" PFB_TEST_CONFIG="$CONFIG" PFB_TEST_EVENTS="$EVENTS" \
PFB_TEST_JOURNAL="$STATE_ROOT/transition-journal.json" PFB_TEST_LOCK="$TMP/PFB_TEST_LOCK" \
PFB_BYPASS_UPGRADE_VERSION_CHECKS=1 PKG_ROOTDIR="$TMP" \
	sh "$SCRIPT" "$TARGET" PRE-INSTALL || fail 'authorized legacy PRE-INSTALL rejected'

[ -d "$STATE_ROOT/3.2" ] || fail '3.2 state directory missing'
[ -f "$STATE_ROOT/3.2/head.json" ] || fail '3.2 head missing'
[ -f "$STATE_ROOT/transition-state.json" ] || fail 'transition state missing'
[ -f "$STATE_ROOT/transition-journal.json" ] || fail 'prepared journal missing'
[ "$(grep -c 'config-write-after-journal' "$EVENTS")" -eq 1 ] \
	|| fail 'marker write was not ordered after durable journal'

snapshot=$(sed -n 's/.*"snapshot":"\([^"]*\)".*/\1/p' "$STATE_ROOT/3.2/head.json")
[ -n "$snapshot" ] && [ -f "$STATE_ROOT/3.2/$snapshot" ] || fail 'snapshot head mismatch'
snapshot_mode=$(stat -f '%Lp' "$STATE_ROOT/3.2/$snapshot")
journal_state_mode=$(stat -f '%Lp' "$STATE_ROOT/transition-state.json")
journal_mode=$(stat -f '%Lp' "$STATE_ROOT/transition-journal.json")
[ "$snapshot_mode" = 600 ] && [ "$journal_state_mode" = 600 ] && [ "$journal_mode" = 600 ] \
	|| fail 'state files are not mode 0600'
gzip -dc "$STATE_ROOT/3.2/$snapshot" | grep -F '<pfblockerng-settings>' >/dev/null \
	|| fail 'snapshot is not gzip XML'

php -r '
$journalBytes = file_get_contents($argv[1]);
$journal = json_decode(file_get_contents($argv[1]), true);
$headBytes = file_get_contents($argv[2]);
$head = json_decode(file_get_contents($argv[2]), true);
$snapshot = basename($argv[3]);
if (!is_string($journalBytes) || !is_string($headBytes)
    || !is_array($journal) || json_encode($journal, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES) !== $journalBytes
    || !is_array($head) || json_encode($head, JSON_THROW_ON_ERROR) !== $headBytes
    || count($journal) !== 17 || $journal["phase"] !== "prepared"
    || $journal["action"] !== "migrate"
    || $journal["source_family"] !== "3.2"
    || $journal["source_package_name"] !== "pfSense-pkg-pfBlockerNG"
    || $journal["source_package_version"] !== "3.2.0"
    || $journal["target_family"] !== "4.0"
    || $journal["target_artifact_sha256"] !== $argv[4]
    || $journal["target_source_identity"] !== "git:0123456789abcdef0123456789abcdef01234567"
    || $journal["target_snapshot_sha256"] !== ""
    || $journal["source_snapshot_sha256"] . ".xml.gz" !== $snapshot
    || $head["payload_sha256"] !== $journal["source_snapshot_sha256"]
    || $journal["source_live_sha256"] !== hash("sha256", serialize((function () {
        $projected = ["pfblockerng" => [
            "config" => [["pfb_keep" => "off", "feed" => "legacy"]],
            "feeds" => ["one" => "value"],
        ]];
        $projected["pfblockerng"]["config"][0]["pfb_schema_family"] = "3.2";
        $projected["pfblockerng"]["config"][0]["pfb_keep"] = "on";
        return $projected;
    })()))) {
    exit(1);
}
' "$STATE_ROOT/transition-journal.json" "$STATE_ROOT/3.2/head.json" "$snapshot" "$ARTIFACT_HASH" \
	|| fail 'journal identity or hash validation failed'

php -r '
$bytes = file_get_contents($argv[1]);
$state = json_decode($bytes, true);
$journal = json_decode(file_get_contents($argv[2]), true);
if (!is_string($bytes) || !is_array($state) || json_encode($state, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES) !== $bytes
    || array_keys($state) !== ["state_version", "activations", "divergences"]
    || $state["state_version"] !== 1
    || array_keys($state["activations"]) !== ["3.2", "4.0"]
    || $state["activations"]["3.2"] !== $journal["source_snapshot_sha256"]
    || $state["activations"]["4.0"] !== ""
    || $state["divergences"] !== []) {
    exit(1);
}
' "$STATE_ROOT/transition-state.json" "$STATE_ROOT/transition-journal.json" \
	|| fail 'transition state is not canonical or source activation is wrong'

php -r '
$config = json_decode(file_get_contents($argv[1]), true);
$general = $config["installedpackages"]["pfblockerng"]["config"][0] ?? [];
if (($general["pfb_schema_family"] ?? null) !== "3.2" || ($general["pfb_keep"] ?? null) !== "on") {
    exit(1);
}
' "$CONFIG" || fail 'persisted marker/keep projection mismatch'

# Hostile XML constructs must be rejected before the parser can interpret them.
cp "$STATE_ROOT/3.2/$snapshot" "$TMP/snapshot.good"
for hostile_kind in doctype entity xinclude processing-instruction; do
	case "$hostile_kind" in
		doctype)
			hostile_xml='<?xml version="1.0"?><!DOCTYPE pfblockerng-settings [<!ENTITY xxe "boom">]><pfblockerng-settings><payload>ignored</payload></pfblockerng-settings>'
			;;
		entity)
			hostile_xml='<?xml version="1.0"?><!ENTITY xxe "boom"><pfblockerng-settings><payload>ignored</payload></pfblockerng-settings>'
			;;
		xinclude)
			hostile_xml='<?xml version="1.0"?><pfblockerng-settings xmlns:xi="http://www.w3.org/2001/XInclude"><xi:include href="file:///etc/passwd" parse="text"/></pfblockerng-settings>'
			;;
		processing-instruction)
			hostile_xml='<?xml version="1.0"?><pfblockerng-settings><?evil instruction?><payload>ignored</payload></pfblockerng-settings>'
			;;
		*)
			fail "unknown hostile XML fixture: $hostile_kind"
			;;
	esac
	php -r 'file_put_contents($argv[2], gzencode($argv[1], 9));' \
		"$hostile_xml" "$STATE_ROOT/3.2/$snapshot"
	cp "$CONFIG" "$TMP/config.before-hostile-$hostile_kind"
	if PFB_TEST_NAME="$TARGET_NAME" PFB_TEST_CONFIG="$CONFIG" PFB_TEST_EVENTS="$EVENTS" \
	PFB_TEST_JOURNAL="$STATE_ROOT/transition-journal.json" PFB_TEST_LOCK="$TMP/PFB_TEST_LOCK" \
	PFB_BYPASS_UPGRADE_VERSION_CHECKS=1 PKG_ROOTDIR="$TMP" \
		sh "$SCRIPT" "$TARGET" PRE-INSTALL >/dev/null 2>&1; then
		fail "accepted hostile XML fixture: $hostile_kind"
	fi
	cmp -s "$CONFIG" "$TMP/config.before-hostile-$hostile_kind" \
		|| fail "hostile XML fixture mutated config: $hostile_kind"
done
cp "$TMP/snapshot.good" "$STATE_ROOT/3.2/$snapshot"

# Duplicate metadata inside one wrapper must be rejected by the XML parser seam.
php -r '
$path = $argv[1];
$xml = gzdecode(file_get_contents($path));
if (!is_string($xml) || !preg_match("/<payload>([^<]*)<\\/payload>/s", $xml, $matches)) {
    exit(1);
}
$payload = $matches[1];
$duplicate = "<?xml version=\"1.0\"?><pfblockerng-settings>"
    . "<family>3.2</family><family>3.2</family><payload>"
    . $payload . "</payload></pfblockerng-settings>";
file_put_contents($path, gzencode($duplicate, 9));
' "$STATE_ROOT/3.2/$snapshot"
cp "$CONFIG" "$TMP/config.before-hostile-duplicate-wrapper"
if PFB_TEST_NAME="$TARGET_NAME" PFB_TEST_CONFIG="$CONFIG" PFB_TEST_EVENTS="$EVENTS" \
PFB_TEST_JOURNAL="$STATE_ROOT/transition-journal.json" PFB_TEST_LOCK="$TMP/PFB_TEST_LOCK" \
PFB_BYPASS_UPGRADE_VERSION_CHECKS=1 PKG_ROOTDIR="$TMP" \
	sh "$SCRIPT" "$TARGET" PRE-INSTALL >/dev/null 2>&1; then
	fail 'accepted duplicate XML metadata'
fi
cmp -s "$CONFIG" "$TMP/config.before-hostile-duplicate-wrapper" \
	|| fail 'duplicate XML metadata mutated config'
cp "$TMP/snapshot.good" "$STATE_ROOT/3.2/$snapshot"

# A config-write failure must stop PRE-INSTALL without mutating active config.
cp "$CONFIG" "$TMP/config.before-failure"
if PFB_TEST_FAIL_WRITE=1 PFB_TEST_NAME="$TARGET_NAME" PFB_TEST_CONFIG="$CONFIG" \
PFB_TEST_EVENTS="$EVENTS" PFB_TEST_JOURNAL="$STATE_ROOT/transition-journal.json" \
PFB_TEST_LOCK="$TMP/PFB_TEST_LOCK" PFB_BYPASS_UPGRADE_VERSION_CHECKS=1 PKG_ROOTDIR="$TMP" \
	sh "$SCRIPT" "$TARGET" PRE-INSTALL >/dev/null 2>&1; then
	fail 'PRE-INSTALL swallowed config-write failure'
fi
cmp -s "$CONFIG" "$TMP/config.before-failure" || fail 'config-write failure mutated active config'

# A saved v4 activation selects the legitimate v4 restore path on re-upgrade;
# it must not change the first-upgrade migrate journal above.
v4_hash=$(php -r '$owned = ["pfblockerng" => ["config" => [["pfb_keep" => "off", "feed" => "legacy"]], "feeds" => ["one" => "value"]]]; echo hash("sha256", serialize($owned));')
mkdir -p "$STATE_ROOT/4.0"
chmod 700 "$STATE_ROOT/4.0"
php -r '
$hash = $argv[1];
$snapshot = $argv[2];
$owned = ["pfblockerng" => [
    "config" => [["pfb_keep" => "off", "feed" => "legacy"]],
    "feeds" => ["one" => "value"],
]];
$document = [
    "format_version" => "1",
    "family" => "4.0",
    "source_package_name" => "pfSense-pkg-pfBlockerNG-devel",
    "source_package_version" => "4.0.0.alpha.21",
    "created_utc" => "2026-01-01T00:00:00Z",
    "payload_sha256" => hash("sha256", serialize($owned)),
    "owned" => $owned,
];
$xml = "<?xml version=\"1.0\"?><pfblockerng-settings><payload>"
    . base64_encode(serialize($document))
    . "</payload></pfblockerng-settings>";
file_put_contents($snapshot, gzencode($xml, 9));
chmod($snapshot, 0600);
file_put_contents(
    dirname($snapshot) . "/head.json",
    json_encode(["family" => "4.0", "snapshot" => basename($snapshot), "payload_sha256" => $hash], JSON_THROW_ON_ERROR)
);
chmod(dirname($snapshot) . "/head.json", 0600);
' "$v4_hash" "$STATE_ROOT/4.0/$v4_hash.xml.gz"
php -r '
$path = $argv[1];
$state = json_decode(file_get_contents($path), true);
$state["activations"]["4.0"] = $argv[2];
file_put_contents($path, json_encode($state, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES));
chmod($path, 0600);
' "$STATE_ROOT/transition-state.json" "$v4_hash"
# Simulate a changed active v3 snapshot while retaining the saved v4 target.
old_v3_hash=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
php -r '
$path = $argv[1];
$state = json_decode(file_get_contents($path), true);
$state["activations"]["3.2"] = $argv[2];
file_put_contents($path, json_encode($state, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES));
chmod($path, 0600);
' "$STATE_ROOT/transition-state.json" "$old_v3_hash"
rm "$STATE_ROOT/transition-journal.json"
PFB_TEST_NAME="$TARGET_NAME" PFB_TEST_CONFIG="$CONFIG" PFB_TEST_EVENTS="$EVENTS" \
PFB_TEST_JOURNAL="$STATE_ROOT/transition-journal.json" PFB_TEST_LOCK="$TMP/PFB_TEST_LOCK" \
PFB_BYPASS_UPGRADE_VERSION_CHECKS=1 PKG_ROOTDIR="$TMP" \
	sh "$SCRIPT" "$TARGET" PRE-INSTALL || fail 'v4 re-upgrade PRE-INSTALL rejected'
php -r '
$journal = json_decode(file_get_contents($argv[1]), true);
if (!is_array($journal) || $journal["action"] !== "restore"
    || $journal["source_family"] !== "3.2"
    || !preg_match("/^[a-f0-9]{64}$/D", $journal["source_snapshot_sha256"])
    || $journal["target_snapshot_sha256"] !== $argv[2]) {
    exit(1);
}
' "$STATE_ROOT/transition-journal.json" "$v4_hash" \
	|| fail 'v4 re-upgrade did not select saved v4 restore activation'
php -r '
$state = json_decode(file_get_contents($argv[1]), true);
$journal = json_decode(file_get_contents($argv[2]), true);
if (!is_array($state) || !is_array($journal) || count($state["divergences"]) !== 1
    || $state["activations"]["3.2"] !== $argv[3]
    || $state["divergences"][0]["source_family"] !== "3.2"
    || $state["divergences"][0]["target_family"] !== "4.0"
    || $state["divergences"][0]["source_snapshot_sha256"] !== $journal["source_snapshot_sha256"]
    || $state["divergences"][0]["target_snapshot_sha256"] !== $argv[4]
    || $state["divergences"][0]["acknowledged"] !== false) {
    exit(1);
}
' "$STATE_ROOT/transition-state.json" "$STATE_ROOT/transition-journal.json" "$old_v3_hash" "$v4_hash" \
	|| fail 'v3 divergence record is missing or incorrect'

# Retrying the same re-upgrade must not append a duplicate divergence.
rm "$STATE_ROOT/transition-journal.json"
PFB_TEST_NAME="$TARGET_NAME" PFB_TEST_CONFIG="$CONFIG" PFB_TEST_EVENTS="$EVENTS" \
PFB_TEST_JOURNAL="$STATE_ROOT/transition-journal.json" PFB_TEST_LOCK="$TMP/PFB_TEST_LOCK" \
PFB_BYPASS_UPGRADE_VERSION_CHECKS=1 PKG_ROOTDIR="$TMP" \
	sh "$SCRIPT" "$TARGET" PRE-INSTALL || fail 'duplicate-divergence retry rejected'
php -r '
$state = json_decode(file_get_contents($argv[1]), true);
$journal = json_decode(file_get_contents($argv[2]), true);
if (!is_array($state) || !is_array($journal) || count($state["divergences"]) !== 1
    || $state["divergences"][0]["target_snapshot_sha256"] !== $argv[3]
    || $journal["action"] !== "restore") {
    exit(1);
}
' "$STATE_ROOT/transition-state.json" "$STATE_ROOT/transition-journal.json" "$v4_hash" \
	|| fail 'duplicate-divergence retry appended or changed the record'

# Authorization rejection must not create any state or mutate config.
rm -rf "$STATE_ROOT"
cat >"$CONFIG" <<'EOF'
{"installedpackages":{"pfblockerng":{"config":[{"pfb_keep":"off","feed":"legacy"}],"feeds":{"one":"value"}}}}
EOF
reject_output=$TMP/reject.out
if PFB_TEST_NAME="$TARGET_NAME" PFB_TEST_CONFIG="$CONFIG" PFB_TEST_EVENTS="$EVENTS" \
PFB_TEST_JOURNAL="$STATE_ROOT/transition-journal.json" PFB_TEST_LOCK="$TMP/PFB_TEST_LOCK" \
PKG_ROOTDIR="$TMP" sh "$SCRIPT" "$TARGET" PRE-INSTALL >"$reject_output" 2>&1; then
	fail 'unauthorized legacy PRE-INSTALL unexpectedly succeeded'
fi
[ "$(grep -c "PFB_BYPASS_UPGRADE_VERSION_CHECKS=1 pkg install -y -f $TARGET" "$reject_output")" -eq 1 ] \
	|| fail 'unauthorized PRE-INSTALL did not print exact retry command'
[ ! -e "$STATE_ROOT" ] || fail 'unauthorized PRE-INSTALL created state root'
php -r '
$config = json_decode(file_get_contents($argv[1]), true);
$general = $config["installedpackages"]["pfblockerng"]["config"][0] ?? [];
if (array_key_exists("pfb_schema_family", $general)) {
    exit(1);
}
' "$CONFIG" || fail 'unauthorized PRE-INSTALL mutated config'

echo 'PASS: embedded legacy PRE-INSTALL snapshot/journal contract'
