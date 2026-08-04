#!/bin/sh

# Verify the four static pfBlockerNG channel recipes and their identity cascade.

set -eu

PORTSDIR=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)}
ASSERTIONS=0
_tab=$(printf '\t')

fail() {
	printf 'not ok: %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	ASSERTIONS=$((ASSERTIONS + 1))
	[ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"
}

assert_contains() {
	ASSERTIONS=$((ASSERTIONS + 1))
	case "$1" in
		*"$2"*) ;;
		*) fail "$3: missing [$2]" ;;
	esac
}

assert_not_contains() {
	ASSERTIONS=$((ASSERTIONS + 1))
	case "$1" in
		*"$2"*) fail "$3: contains forbidden [$2]" ;;
		*) ;;
	esac
}

assert_file() {
	ASSERTIONS=$((ASSERTIONS + 1))
	[ -f "$1" ] || fail "missing file: $1"
}

port_var() {
	_port=$1
	_var=$2
	"$_MAKE" -C "$PORTSDIR/$_port" -V "$_var"
}

query_recipe() {
	_port=$1
	_name=$2
	_conflicts=$3
	_version=$4
	_pkgname=$5
	_charset=$6
	_label=$7
	assert_eq "$(port_var "$_port" PORTNAME)" "$_name" "$_label PORTNAME"
	assert_eq "$(port_var "$_port" PKGBASE)" "$_name" "$_label PKGBASE"
	assert_eq "$(port_var "$_port" PKGNAME)" "$_pkgname" "$_label PKGNAME"
	assert_eq "$(port_var "$_port" PKGORIGIN)" "net/$_name" "$_label PKGORIGIN"
	assert_eq "$(port_var "$_port" PORTVERSION)" "$_version" "$_label PORTVERSION"
	assert_eq "$(port_var "$_port" GH_TAGNAME)" "v$_version" "$_label GH_TAGNAME"
	assert_eq "$(port_var "$_port" DATADIR)" "/usr/local/share/$_name" "$_label DATADIR"
	assert_eq "$(port_var "$_port" DIST_SUBDIR)" "$_name" "$_label DIST_SUBDIR"
	assert_contains "$(port_var "$_port" SUB_LIST)" "PORTNAME=$_name" "$_label SUB_LIST"
	assert_eq "$(port_var "$_port" CONFLICTS)" "$_conflicts" "$_label CONFLICTS"
	_run_depends=$(port_var "$_port" RUN_DEPENDS)
	case "$_charset" in
		yes) assert_contains "$_run_depends" 'charset-normalizer' "$_label charset-normalizer dependency" ;;
		no) assert_not_contains "$_run_depends" 'charset-normalizer' "$_label charset-normalizer dependency" ;;
	esac
}

check_recipe() {
	_port=$1
	_name=$2
	_conflicts=$3
	_version=$4
	_pkgname=$5
	_charset=$6
	_label=$7
	_dir="$PORTSDIR/$_port"

	assert_file "$_dir/Makefile"
	_makefile=$(cat "$_dir/Makefile")
	assert_contains "$_makefile" "PORTNAME=${_tab}$_name" "$_label PORTNAME declaration"
	assert_contains "$_makefile" "PORTVERSION=${_tab}$_version" "$_label static PORTVERSION"
	assert_contains "$_makefile" "NO_ARCH=${_tab}yes" "$_label NO_ARCH"
	assert_contains "$_makefile" "GH_ACCOUNT=${_tab}pfBlockerNG" "$_label source account"
	assert_contains "$_makefile" "GH_PROJECT=${_tab}pfBlockerNG" "$_label source project"
	assert_contains "$_makefile" "GH_TAGNAME=${_tab}v\${PORTVERSION}" "$_label source tag"
	assert_contains "$_makefile" "DIST_SUBDIR=${_tab}\${PORTNAME}" "$_label DIST_SUBDIR declaration"
	assert_contains "$_makefile" "SUB_LIST=${_tab}PORTNAME=\${PORTNAME}" "$_label SUB_LIST declaration"
	assert_contains "$_makefile" "CONFLICTS=${_tab}$_conflicts" "$_label conflicts declaration"
	# shellcheck disable=SC2016
	assert_contains "$_makefile" '%%PKGNAME%%|${PORTNAME:S/pfSense-pkg-//}|g' "$_label info.xml short name"
	# shellcheck disable=SC2016
	assert_contains "$_makefile" '${STAGEDIR}${DATADIR}' "$_label DATADIR staging"
	# shellcheck disable=SC2016
	assert_contains "$_makefile" '${PORTNAME}' "$_label identity cascade"
	assert_not_contains "$_makefile" 'PFB_PACKAGE_IDENTITY' "$_label project identity override"
	assert_not_contains "$_makefile" 'PFB_EXPECTED_' "$_label internal identity override"
	for _dependency in mmdblookup ggrep grepcidr iprange jq rsync lighttpd sqlite3 maxminddb; do
		assert_contains "$_makefile" "$_dependency" "$_label $_dependency dependency"
	done
	case "$_charset" in
		yes) assert_contains "$_makefile" 'charset-normalizer' "$_label charset-normalizer dependency" ;;
		no) assert_not_contains "$_makefile" 'charset-normalizer' "$_label charset-normalizer dependency" ;;
	esac
	case "$_label" in
		stable) assert_contains "$_makefile" "PORTREVISION=${_tab}2" 'stable PORTREVISION' ;;
		*) assert_not_contains "$_makefile" 'PORTREVISION=' "$_label static PORTREVISION" ;;
	esac

	_non_conflicts=$(printf '%s\n' "$_makefile" | awk '!/^CONFLICTS[[:space:]]*=/')
	assert_not_contains "$_non_conflicts" 'pfSense-pkg-pfBlockerNG-devel' "$_label stale devel identity"

	for _hook in pkg-install.in pkg-deinstall.in; do
		assert_file "$_dir/files/$_hook"
		_hook_text=$(cat "$_dir/files/$_hook")
		assert_contains "$_hook_text" '%%PORTNAME%%' "$_label $_hook identity"
		assert_not_contains "$_hook_text" 'pfSense-pkg-pfBlockerNG-devel' "$_label $_hook stale devel identity"
	done

	if [ -f "$_dir/pkg-plist" ]; then
		_plist=$(cat "$_dir/pkg-plist")
		assert_contains "$_plist" '%%DATADIR%%/info.xml' "$_label plist share path"
		assert_not_contains "$_plist" 'pfSense-pkg-pfBlockerNG-devel' "$_label plist stale devel identity"
	else
		# shellcheck disable=SC2016
		assert_contains "$_makefile" '>> ${TMPPLIST}' "$_label generated plist"
	fi

	if [ -n "${_MAKE:-}" ]; then
		query_recipe "$_port" "$_name" "$_conflicts" "$_version" "$_pkgname" "$_charset" "$_label"
	fi
}

assert_eq "$(find "$PORTSDIR/net" -maxdepth 1 -type d -name 'pfSense-pkg-pfBlockerNG*' | wc -l | tr -d ' ')" 4 \
	'recipe directory count'
ASSERTIONS=$((ASSERTIONS + 1))
[ ! -d "$PORTSDIR/net/pfSense-pkg-pfBlockerNG-devel" ] || fail 'obsolete devel recipe directory exists'
assert_file "$PORTSDIR/MOVED"
_moved=$(cat "$PORTSDIR/MOVED")
assert_contains "$_moved" \
	'net/pfSense-pkg-pfBlockerNG-devel|net/pfSense-pkg-pfBlockerNG-testing|2026-08-04|Renamed to Testing channel' \
	'Devel to Testing origin migration'

_MAKE=''
if command -v bmake >/dev/null 2>&1; then
	_MAKE=$(command -v bmake)
elif [ "$(uname -s)" = FreeBSD ] && make -V .MAKE_VERSION >/dev/null 2>&1; then
	_MAKE=$(command -v make)
fi

check_recipe net/pfSense-pkg-pfBlockerNG pfSense-pkg-pfBlockerNG \
	'pfSense-pkg-pfBlockerNG-testing pfSense-pkg-pfBlockerNG-edge pfSense-pkg-pfBlockerNG-nightly pfSense-pkg-pfBlockerNG-devel' \
	3.2.15 pfSense-pkg-pfBlockerNG-3.2.15_2 no stable
check_recipe net/pfSense-pkg-pfBlockerNG-testing pfSense-pkg-pfBlockerNG-testing \
	'pfSense-pkg-pfBlockerNG pfSense-pkg-pfBlockerNG-edge pfSense-pkg-pfBlockerNG-nightly pfSense-pkg-pfBlockerNG-devel' \
	4.0.0.alpha.24 pfSense-pkg-pfBlockerNG-testing-4.0.0.alpha.24 yes testing
check_recipe net/pfSense-pkg-pfBlockerNG-edge pfSense-pkg-pfBlockerNG-edge \
	'pfSense-pkg-pfBlockerNG pfSense-pkg-pfBlockerNG-testing pfSense-pkg-pfBlockerNG-nightly pfSense-pkg-pfBlockerNG-devel' \
	4.0.0.alpha.24 pfSense-pkg-pfBlockerNG-edge-4.0.0.alpha.24 yes edge
check_recipe net/pfSense-pkg-pfBlockerNG-nightly pfSense-pkg-pfBlockerNG-nightly \
	'pfSense-pkg-pfBlockerNG pfSense-pkg-pfBlockerNG-testing pfSense-pkg-pfBlockerNG-edge pfSense-pkg-pfBlockerNG-devel' \
	4.0.0.alpha.24 pfSense-pkg-pfBlockerNG-nightly-4.0.0.alpha.24 yes nightly

if [ -z "$_MAKE" ]; then
	printf 'info: bmake query unavailable; structural recipe checks only\n'
fi
printf 'ok: %s channel recipe assertions\n' "$ASSERTIONS"
