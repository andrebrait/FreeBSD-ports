#!/bin/sh

# Contract gate for the v4 package lifecycle scripts.
# Run from the ports worktree: sh tests/pkg-lifecycle/contract.sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}/pfb-lifecycle-contract.$$
BIN=$TMP/usr/local/bin
PKGBIN=$TMP/usr/local/sbin
LOG=$TMP/events.log
mkdir -p "$BIN" "$PKGBIN"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

assert_contains()
{
	grep -F "$2" "$1" >/dev/null 2>&1 || fail "$1 lacks: $2"
}

assert_hash()
{
	actual=$(git hash-object "$1")
	[ "$actual" = "$2" ] || fail "$1 changed: expected $2 got $actual"
}

cat >"$BIN/php" <<'EOF'
#!/bin/sh
step=${PFB_TRANSITION_STEP:-rc}
printf '%s\n' "$step" >>"${PFB_TEST_LOG}"
if [ "${PFB_TEST_REQUIRE_SOURCE:-}" = 1 ] && [ -z "${PFB_TRANSITION_SOURCE_NAME:-}" ]; then
    exit 19
fi
if [ "${PFB_TEST_FAIL_STEP:-}" = "$step" ]; then
    exit 17
fi
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
format=$4
case "$format" in
    '%n') printf '%s\n' "${PFB_TEST_NAME}"
        ;;
    '%v') printf '%s\n' "4.0.0.alpha.21"
        ;;
    '%q') printf '%s\n' "FreeBSD:16:amd64"
        ;;
    '%An=%Av') printf '%s\n' "commit=0123456789abcdef0123456789abcdef01234567"
        ;;
    *) exit 1
        ;;
esac
EOF
chmod 755 "$PKGBIN/pkg"

stable_install=$ROOT/net/pfSense-pkg-pfBlockerNG/files/pkg-install.in
stable_deinstall=$ROOT/net/pfSense-pkg-pfBlockerNG/files/pkg-deinstall.in
assert_hash "$stable_install" c192d05db62d9ebe243425fe0e983777652cde27
assert_hash "$stable_deinstall" 83d1c3dcab9e12f72791e6b418a538a4c7bbec67

for channel in devel nightly; do
	install=$ROOT/net/pfSense-pkg-pfBlockerNG-$channel/files/pkg-install.in
	deinstall=$ROOT/net/pfSense-pkg-pfBlockerNG-$channel/files/pkg-deinstall.in
	assert_hash "$deinstall" 83d1c3dcab9e12f72791e6b418a538a4c7bbec67
	assert_contains "$install" 'PRE-INSTALL'
	assert_contains "$install" 'POST-INSTALL'
	assert_contains "$install" 'PFB_BYPASS_UPGRADE_VERSION_CHECKS'
	assert_contains "$install" 'transition-journal.json'
	assert_contains "$install" '/cf/conf/pfblockerng'
	assert_contains "$install" ' -r '
	assert_contains "$install" 'lstat'
	assert_contains "$install" 'pkg query -F'
	assert_contains "$install" 'pkg rquery'
	assert_contains "$install" '%An=%Av'
	assert_contains "$install" "query '%n|%v'"
	assert_contains "$install" 'migrate'
	assert_contains "$install" "? 'migrate' : 'restore'"
	assert_contains "$install" 'source_rows'
	assert_contains "$install" "query '%n|%v' \"\$source_name\""
	assert_contains "$install" 'case "$candidate_name" in'
	assert_contains "$install" '<!DOCTYPE|<!ENTITY|XInclude'
	assert_contains "$install" '<\?(?!xml\b)'
	if grep -Eq "PFB_TRANSITION_STEP=restore|\\\$step[[:space:]]*===[[:space:]]*'restore'" "$install"; then
		fail "$channel package lifecycle invokes restore directly"
	fi
	script="$TMP/pkg-install-$channel"
	sed "s/%%PORTNAME%%/pfSense-pkg-pfBlockerNG-$channel/g" "$install" >"$script"
	chmod 755 "$script"

	# Unknown lifecycle phases are deliberately a no-op.
	: >"$LOG"
	PFB_TEST_LOG="$LOG" PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" \
		PKG_ROOTDIR="$TMP" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" UNKNOWN
	[ ! -s "$LOG" ] || fail "$channel unknown phase executed a hook"

	cache="$TMP/cache-$channel"
	mkdir -p "$cache/var/cache/pkg" "$cache/usr/local/bin" "$cache/usr/local/sbin"
	cp "$BIN/php" "$cache/usr/local/bin/php"
	cp "$PKGBIN/pkg" "$cache/usr/local/sbin/pkg"
	artifact="$cache/var/cache/pkg/pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21~fixture.pkg"
	: >"$artifact"
	chmod 600 "$artifact"
	: >"$LOG"
	PFB_TEST_LOG="$LOG" PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" \
		PKG_ROOTDIR="$cache" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL \
		|| fail "$channel valid PRE-INSTALL rejected fixture"
	[ "$(sed -n '1p' "$LOG")" = prepare ] || fail "$channel PRE-INSTALL did not prepare"

	# Owned legacy settings require exactly one supported v3 source and exact reverse lookup.
	PFB_TEST_LOG="$LOG" PFB_TEST_REQUIRE_SOURCE=1 PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" \
	PFB_TEST_SOURCE_ROWS='pfSense-pkg-unrelated|3.2.0' PKG_ROOTDIR="$cache" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL >/dev/null 2>&1 && \
		fail "$channel accepted an unsupported source package"
	PFB_TEST_LOG="$LOG" PFB_TEST_REQUIRE_SOURCE=1 PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" \
	PFB_TEST_SOURCE_ROWS='pfSense-pkg-pfBlockerNG|3.2.0
pfSense-pkg-pfBlockerNG-devel|3.2.0' PKG_ROOTDIR="$cache" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL >/dev/null 2>&1 && \
		fail "$channel accepted multiple supported source packages"
	PFB_TEST_LOG="$LOG" PFB_TEST_REQUIRE_SOURCE=1 PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" \
	PFB_TEST_REVERSE_ROWS='pfSense-pkg-pfBlockerNG|3.2.99' PKG_ROOTDIR="$cache" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL >/dev/null 2>&1 && \
		fail "$channel accepted a reverse source identity mismatch"

	# Target artifacts must be private, single-link regular files owned by the caller.
	chmod 666 "$artifact"
	if PFB_TEST_LOG="$LOG" PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" \
		PKG_ROOTDIR="$cache" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL >/dev/null 2>&1; then
		fail "$channel accepted a group/world-writable artifact"
	fi
	chmod 600 "$artifact"
	mv "$artifact" "$artifact.real"
	ln -s "$(basename "$artifact.real")" "$artifact"
	if PFB_TEST_LOG="$LOG" PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" \
		PKG_ROOTDIR="$cache" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL >/dev/null 2>&1; then
		fail "$channel followed a symlink artifact"
	fi
	rm "$artifact"
	mv "$artifact.real" "$artifact"
	ln "$artifact" "$artifact.hardlink"
	if PFB_TEST_LOG="$LOG" PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" \
		PKG_ROOTDIR="$cache" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL >/dev/null 2>&1; then
		fail "$channel accepted a hardlink artifact"
	fi
	rm "$artifact.hardlink"
	PFB_TEST_LOG="$LOG" PFB_TEST_NAME=wrong-name PKG_ROOTDIR="$cache" \
		sh "$script" "pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL >/dev/null 2>&1 && \
		fail "$channel accepted a mismatched embedded package name"

	# An archive with the same target identity in a second accepted suffix is ambiguous.
	: >"$cache/var/cache/pkg/pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21~other.pkg"
	if PFB_TEST_LOG="$LOG" PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" \
		PKG_ROOTDIR="$cache" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" PRE-INSTALL >/dev/null 2>&1; then
		fail "$channel accepted multiple cached target artifacts"
	fi
	rm -f "$cache/var/cache/pkg/pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21~other.pkg"

	# POST-INSTALL is migrate -> rc.packages -> complete, and each failure stops the tail.
	: >"$LOG"
	PFB_TEST_LOG="$LOG" PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" \
		PKG_ROOTDIR="$cache" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" POST-INSTALL \
		|| fail "$channel valid POST-INSTALL rejected fixture"

	[ "$(sed -n '1p' "$LOG")" = migrate ] || fail "$channel POST-INSTALL did not migrate first"
	[ "$(sed -n '2p' "$LOG")" = rc ] || fail "$channel POST-INSTALL skipped rc.packages"
	[ "$(sed -n '3p' "$LOG")" = complete ] || fail "$channel POST-INSTALL did not complete last"

	# Failure boundaries: no later lifecycle stage may run after a failed stage.
	: >"$LOG"
	if PFB_TEST_FAIL_STEP=migrate PFB_TEST_LOG="$LOG" PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" \
		PKG_ROOTDIR="$cache" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" POST-INSTALL >/dev/null 2>&1; then
		fail "$channel swallowed migrate failure"
	fi
	[ "$(sed -n '1p' "$LOG")" = migrate ] && [ "$(sed -n '2p' "$LOG")" = '' ] \
		|| fail "$channel ran a later stage after migrate failure"
	: >"$LOG"
	if PFB_TEST_FAIL_STEP=rc PFB_TEST_LOG="$LOG" PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" \
		PKG_ROOTDIR="$cache" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" POST-INSTALL >/dev/null 2>&1; then
		fail "$channel swallowed rc failure"
	fi
	[ "$(sed -n '1p' "$LOG")" = migrate ] && [ "$(sed -n '2p' "$LOG")" = rc ] \
		&& [ "$(sed -n '3p' "$LOG")" = '' ] || fail "$channel completed after rc failure"
	: >"$LOG"
	if PFB_TEST_FAIL_STEP=complete PFB_TEST_LOG="$LOG" PFB_TEST_NAME="pfSense-pkg-pfBlockerNG-$channel" \
		PKG_ROOTDIR="$cache" sh "$script" \
		"pfSense-pkg-pfBlockerNG-$channel-4.0.0.alpha.21" POST-INSTALL >/dev/null 2>&1; then
		fail "$channel swallowed complete failure"
	fi
	[ "$(sed -n '1p' "$LOG")" = migrate ] && [ "$(sed -n '2p' "$LOG")" = rc ] \
		&& [ "$(sed -n '3p' "$LOG")" = complete ] || fail "$channel skipped complete failure boundary"

	# Both templates use the generated PORTNAME token and must remain identical.
	devel_script=$ROOT/net/pfSense-pkg-pfBlockerNG-devel/files/pkg-install.in
	nightly_script=$ROOT/net/pfSense-pkg-pfBlockerNG-nightly/files/pkg-install.in
	if [ "$channel" = nightly ]; then
		cmp -s "$devel_script" "$nightly_script" \
			|| fail 'devel/nightly pkg-install scripts diverge'
	fi
done

echo 'PASS: package lifecycle contract'
