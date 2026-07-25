#!/bin/sh

# Off-box lifecycle contract for the v4 package scripts.
# Run from the ports worktree: sh tests/pkg-lifecycle/settings-transition.sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}/pfb-lifecycle-test.$$
BIN=$TMP/usr/local/bin
PKGBIN=$TMP/usr/local/sbin
LOG=$TMP/php.log
mkdir -p "$BIN" "$PKGBIN" "$TMP/var/cache/pkg"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

assert_contains()
{
	file=$1
	needle=$2
	grep -F "$needle" "$file" >/dev/null 2>&1 || fail "$file lacks: $needle"
}

cat >"$BIN/php" <<'EOF'
#!/bin/sh
printf '%s\n' "${PFB_TRANSITION_STEP:-rc}" >>"${PFB_TEST_LOG}"
exit 0
EOF
chmod 755 "$BIN/php"

cat >"$PKGBIN/pkg" <<'EOF'
#!/bin/sh
if [ "$1" = config ] && [ "$2" = ABI ]; then
    printf '%s\n' "FreeBSD:16:amd64"
    exit 0
fi
if [ "$1" = rquery ]; then
    printf '%s\n' "${PFB_TEST_NAME}|4.0.0.alpha.21|FreeBSD:16:amd64|sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    exit 0
fi
if [ "$1" = query ] && [ "$2" = '%n|%v' ]; then
    printf '%s\n' "${PFB_TEST_SOURCE_ROWS:-pfSense-pkg-pfBlockerNG|3.2.0}"
    exit 0
fi
if [ "$1" != query ] || [ "$2" != -F ]; then exit 1; fi
case "$4" in
    '%n') printf '%s\n' "${PFB_TEST_NAME}" ;;
    '%v') printf '%s\n' "4.0.0.alpha.21" ;;
    '%q') printf '%s\n' "FreeBSD:16:amd64" ;;
    '%An=%Av') printf '%s\n' "commit=0123456789abcdef0123456789abcdef01234567" ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "$PKGBIN/pkg"

for channel in devel nightly; do
	install="$ROOT/net/pfSense-pkg-pfBlockerNG-$channel/files/pkg-install.in"
	assert_contains "$install" 'PRE-INSTALL'
	assert_contains "$install" 'POST-INSTALL'
	assert_contains "$install" 'PFB_BYPASS_UPGRADE_VERSION_CHECKS'
	assert_contains "$install" '/cf/conf/pfblockerng'
	assert_contains "$install" 'transition-journal.json'
	assert_contains "$install" ' -r '
	assert_contains "$install" 'pkg query -F'
	assert_contains "$install" "query '%n|%v'"
	assert_contains "$install" 'migrate'
	assert_contains "$install" "? 'migrate' : 'restore'"
	if grep -Eq "PFB_TRANSITION_STEP=restore|\\\$step[[:space:]]*===[[:space:]]*'restore'" "$install"; then
		fail "$channel package lifecycle invokes restore directly"
	fi
	script="$TMP/pkg-install-$channel"
	sed "s/%%PORTNAME%%/pfSense-pkg-pfBlockerNG-$channel/g" "$install" >"$script"
	chmod 755 "$script"

	archive="$TMP/var/cache/pkg/pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21~fixture.pkg"
	: >"$archive"
	chmod 600 "$archive"
	: >"$LOG"
	PFB_TEST_LOG="$LOG" PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" PKG_ROOTDIR="$TMP" \
		sh "$script" "pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL \
		|| fail "$channel PRE-INSTALL rejected fixture"
	[ "$(sed -n '1p' "$LOG")" = prepare ] || fail "$channel PRE-INSTALL skipped direct transition call"

	: >"$LOG"
	PFB_TEST_LOG="$LOG" PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" PKG_ROOTDIR="$TMP" \
		sh "$script" "pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" POST-INSTALL \
		|| fail "$channel POST-INSTALL rejected fixture"
	first=$(sed -n '1p' "$LOG")
	second=$(sed -n '2p' "$LOG")
	third=$(sed -n '3p' "$LOG")
	[ "$first" = migrate ] || fail "$channel POST-INSTALL did not migrate before rc.packages"
	[ "$second" = rc ] || fail "$channel POST-INSTALL did not dispatch rc.packages second"
	[ "$third" = complete ] || fail "$channel POST-INSTALL did not complete last"
done

echo "PASS: v4 lifecycle scripts protect PRE-INSTALL and order POST-INSTALL"
