#!/bin/sh
# TV-Tools：按 kind 卸载
# 用法: tv-tools-adb-uninstall.sh SERIAL PACKAGE kind
# kind=user：adb uninstall → pm uninstall → pm uninstall --user 0
# kind=sys_update：pm uninstall -k --user 0（卸载系统应用更新）
set -u
SERIAL="${1:?}"
PKG="${2:?}"
KIND="${3:?}"
export PATH="/usr/bin:/usr/sbin:/bin:/sbin:${PATH}"
export HOME="${HOME:-/root}"

ok_out() {
	printf '%s\n' "$1"
	echo "$1" | grep -q Success && exit 0
	return 1
}

case "$KIND" in
user)
	O=$(timeout 90 adb -s "$SERIAL" uninstall "$PKG" 2>&1) || true
	printf '%s\n' "$O"
	if echo "$O" | grep -q Success; then exit 0; fi
	O=$(timeout 90 adb -s "$SERIAL" shell pm uninstall "$PKG" 2>&1) || true
	printf '%s\n' "$O"
	if echo "$O" | grep -q Success; then exit 0; fi
	O=$(timeout 90 adb -s "$SERIAL" shell pm uninstall --user 0 "$PKG" 2>&1) || true
	printf '%s\n' "$O"
	if echo "$O" | grep -q Success; then exit 0; fi
	exit 1
	;;
sys_update)
	O=$(timeout 90 adb -s "$SERIAL" shell pm uninstall -k --user 0 "$PKG" 2>&1) || true
	printf '%s\n' "$O"
	if echo "$O" | grep -q Success; then exit 0; fi
	exit 1
	;;
*)
	echo "ERR: kind must be user or sys_update" >&2
	exit 2
	;;
esac
