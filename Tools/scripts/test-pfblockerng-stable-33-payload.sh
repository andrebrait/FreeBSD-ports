#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd -P)
port_dir="$repo_root/net/pfSense-pkg-pfBlockerNG"
makefile="$port_dir/Makefile"
plist="$port_dir/pkg-plist"

aws_scripts='AF ALL_REGIONS AP AP_EAST AP_NORTHEAST AP_SOUTH AP_SOUTHEAST CA CN CN_NORTH CN_NORTHWEST EU EU_CENTRAL EU_NORTH EU_SOUTH EU_WEST IL ME ME_CENTRAL ME_SOUTH SA US US_EAST US_GOV US_WEST'

fail() {
	printf 'not ok: %s\n' "$1" >&2
	exit 1
}

for region in $aws_scripts; do
	script="ip_pre_AWS_${region}.sh"
	grep -Fq "\${WRKSRC}\${PREFIX}/pkg/pfblockerng/$script" "$makefile" ||
		fail "Stable recipe does not install legacy source $script"
	grep -Fxq "pkg/pfblockerng/$script" "$plist" ||
		fail "Stable plist does not contain legacy path $script"
done

[ "$(grep -c 'ip_pre_AWS_' "$makefile")" -eq 25 ] ||
	fail 'Stable recipe AWS script set is not exact'
[ "$(grep -c 'ip_pre_AWS_' "$plist")" -eq 25 ] ||
	fail 'Stable plist AWS script set is not exact'

if grep -Eq 'pfblockerng/list_scripts|aws_region_prefixes|www/shortcuts/pkg_pfblockerng' "$makefile" "$plist"; then
	fail 'Stable payload contains post-3.3 files or paths'
fi

printf 'ok: Stable payload matches release/3.3 compatibility paths\n'
