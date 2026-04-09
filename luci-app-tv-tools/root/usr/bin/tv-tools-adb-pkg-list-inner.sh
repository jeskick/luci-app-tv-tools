# 在电视端执行：adb shell sh -s < 本文件（勿依赖 heredoc 跨 adb）
UF=/data/local/tmp/tv_tools_user_pkgs.lst
rm -f "$UF"
TMP="${UF}.tmp"
: > "$TMP"
if pm list packages --user 0 -3 2>/dev/null | tr -d '\r' | sed 's/^package://' | sort -u > "$TMP" && [ -s "$TMP" ]; then
	mv -f "$TMP" "$UF"
elif rm -f "$TMP" && pm list packages -3 --user 0 2>/dev/null | tr -d '\r' | sed 's/^package://' | sort -u > "$TMP" && [ -s "$TMP" ]; then
	mv -f "$TMP" "$UF"
elif rm -f "$TMP" && pm list packages -3 2>/dev/null | tr -d '\r' | sed 's/^package://' | sort -u > "$TMP" && [ -s "$TMP" ]; then
	mv -f "$TMP" "$UF"
else
	rm -f "$TMP"
	: > "$UF"
fi
while IFS= read -r pkg; do
	[ -z "$pkg" ] && continue
	pline=$(pm path "$pkg" 2>/dev/null | head -n 1 | tr -d '\r')
	ap="${pline#package:}"
	[ -z "$ap" ] && continue
	vn=$(dumpsys package "$pkg" 2>/dev/null | grep -m1 versionName= | head -n 1)
	vn="${vn#*=}"
	vn="${vn%%[[:space:]]*}"
	vn=$(printf '%s' "$vn" | tr -d '\r')
	printf 'u\t%s\t%s\t%s\n' "$pkg" "$ap" "$vn"
done < "$UF"
(
	pm list packages --user 0 -s -f 2>/dev/null || pm list packages -s -f 2>/dev/null
) | tr -d '\r' | while IFS= read -r line; do
	[ -z "$line" ] && continue
	case "$line" in package:*) ;; *) continue ;; esac
	pkg="${line##*=}"
	ap="${line#package:}"
	ap="${ap%=*}"
	[ -z "$pkg" ] && continue
	if [ -s "$UF" ] && grep -Fxq "$pkg" "$UF" 2>/dev/null; then
		continue
	fi
	upd=0
	case "$ap" in *"/data/app/"*) upd=1 ;; esac
	printf 's\t%s\t%s\t%d\t\n' "$pkg" "$ap" "$upd"
done
rm -f "$UF"
