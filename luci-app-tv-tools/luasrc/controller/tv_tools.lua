--[[
  TV-Tools — LuCI 控制器（OpenWrt 21.02 / lua luci）
  菜单位置：服务 → TV-Tools

  约束（避免再踩坑）：
  - Lua 5.1：math.randomseed 只接受整数；不要用 os.clock() 混出浮点当种子。
  - 临时文件唯一性：用 nixio.getpid + /proc/sys/kernel/random/uuid，勿依赖 math.random。
]]
module("luci.controller.tv_tools", package.seeall)

local function adb_allowed_keys()
	return {
		power = true,
		home = true,
		back = true,
		ok = true,
		up = true,
		down = true,
		left = true,
		right = true,
		vol_plus = true,
		vol_minus = true,
		mute = true,
		menu = true,
	}
end

function adb_key()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local disp = require "luci.dispatcher"

	http.prepare_content("application/json")
	if not disp.context or not disp.context.authsession then
		http.status(403, "Forbidden")
		http.write_json({ ok = false, err = "not authenticated" })
		return
	end

	local key = http.formvalue("key")
	if not key or key == "" then
		http.write_json({ ok = false, err = "missing key" })
		return
	end

	if not adb_allowed_keys()[key] then
		http.write_json({ ok = false, err = "key not allowed" })
		return
	end

	local out = sys.exec("/usr/bin/tv-tools-adb-key.sh '" .. key:gsub("'", "") .. "' 2>&1") or ""
	local ok = type(out) == "string" and out:match("OK")
	http.write_json({ ok = ok, out = out:gsub("^%s+", ""):gsub("%s+$", "") })
end

local function trim_exec(s)
	if not s or type(s) ~= "string" then
		return ""
	end
	return (s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\r", ""))
end

-- tv-tools-adb-text.sh 在设备上的结果行（须整行精确匹配；旧版经 stdin 喂脚本时会把源码打进 out，子串匹配会误判；现与 tvcontrol 一样走单条 shell，仍保留按行解析更稳）
local TV_TEXT_LINE_OK = {
	TVTOOLS_OK_CLIPBOARD_SET = "clipboard_set",
	TVTOOLS_OK_CLIPBOARD_SETTEXT = "clipboard_set_text",
	TVTOOLS_OK_PRIMARY = "clipboard_primary",
	TVTOOLS_OK_USER0 = "clipboard_user0",
	TVTOOLS_OK_ASCII = "input_text_ascii",
}

local function tv_text_parse_line_tokens(out)
	local last_kind, last_method, last_err
	if not out or out == "" then
		return nil, nil
	end
	for line in out:gmatch("[^\r\n]+") do
		local t = line:match("^%s*(.-)%s*$") or ""
		if TV_TEXT_LINE_OK[t] then
			last_kind, last_method, last_err = "ok", TV_TEXT_LINE_OK[t], nil
		elseif t == "TVTOOLS_ERR_ASCII_INPUT" then
			last_kind, last_method, last_err = "err", nil, "ascii"
		elseif t == "TVTOOLS_ERR_UNICODE_CLIPBOARD" then
			last_kind, last_method, last_err = "err", nil, "unicode"
		end
	end
	if last_kind == "ok" then
		return last_method, nil
	end
	if last_kind == "err" then
		return nil, last_err
	end
	return nil, nil
end

-- 与 luci-app-tvcontrol 一致：整段命令用单引号交给 adb shell，避免设备端 stdin 脚本在部分路由器/adb 上无效
local function shell_single_quoted(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

-- 与 luci-app-tvcontrol 一致：Android input text 参数转义（空格->%s，%->%%）
local function to_android_input_text(s)
	if not s or s == "" then
		return nil
	end
	if #s > 900 then
		return nil
	end
	if s:find("\0", 1, true) or s:find("\r", 1, true) or s:find("\n", 1, true) then
		return nil
	end
	if s:find(";", 1, true) or s:find("&", 1, true) or s:find("|", 1, true)
		or s:find("`", 1, true) or s:find("$", 1, true)
		or s:find("<", 1, true) or s:find(">", 1, true) then
		return nil
	end
	s = s:gsub("%%", "%%%%")
	s = s:gsub(" ", "%%s")
	return s
end

local function adb_app_shell(sys, safe, inner_cmd, timeout_sec, use_to)
	timeout_sec = tonumber(timeout_sec) or 180
	local cmd = "adb -s '" .. safe .. "' shell " .. shell_single_quoted(inner_cmd) .. " 2>&1"
	if use_to then
		return sys.exec("timeout " .. tostring(timeout_sec) .. " " .. cmd) or ""
	end
	return sys.exec(cmd) or ""
end

-- MemTotal / MemAvailable，单位 kB
local function parse_meminfo_kb(text)
	local total_kb, avail_kb, free_kb, buffers_kb, cached_kb
	if not text or text == "" then
		return nil, nil
	end
	for line in text:gmatch("[^\r\n]+") do
		local k, v = line:match("^([^:]+):%s*(%d+)")
		if k then
			k = (k:gsub("^%s+", ""):gsub("%s+$", ""))
			v = tonumber(v)
			if k == "MemTotal" then
				total_kb = v
			elseif k == "MemAvailable" then
				avail_kb = v
			elseif k == "MemFree" then
				free_kb = v
			elseif k == "Buffers" then
				buffers_kb = v
			elseif k == "Cached" then
				cached_kb = v
			end
		end
	end
	if total_kb and not avail_kb then
		local approx = (free_kb or 0) + (buffers_kb or 0) + (cached_kb or 0)
		if approx > 0 then
			avail_kb = approx
		else
			avail_kb = free_kb
		end
	end
	return total_kb, avail_kb
end

local function kb_to_gb_str(kb)
	if not kb or kb < 0 then
		return nil
	end
	local gb = kb / 1024 / 1024
	return string.format("%.2f", gb)
end

local function format_memory_summary(memraw)
	local total_kb, avail_kb = parse_meminfo_kb(memraw)
	if not total_kb then
		return "（无法解析内存）"
	end
	avail_kb = avail_kb or total_kb
	local used_kb = total_kb - avail_kb
	if used_kb < 0 then
		used_kb = 0
	end
	local u, t, a = kb_to_gb_str(used_kb), kb_to_gb_str(total_kb), kb_to_gb_str(avail_kb)
	if not u or not t or not a then
		return "（无法解析内存）"
	end
	return string.format("已用约 %s GB / 总计 %s GB（可用 %s GB）", u, t, a)
end

-- df -Pk 一行：块数与已用、可用均为 1K 块，等同 KB
local function parse_df_pk_summary(text)
	if not text or text == "" then
		return nil
	end
	for line in text:gmatch("[^\r\n]+") do
		if not line:match("^Filesystem") then
			local t = {}
			for w in line:gmatch("%S+") do
				table.insert(t, w)
			end
			if #t >= 6 then
				local blocks, used, avail = tonumber(t[2]), tonumber(t[3]), tonumber(t[4])
				if blocks and used and avail and blocks > 0 then
					local u, tot, a = kb_to_gb_str(used), kb_to_gb_str(blocks), kb_to_gb_str(avail)
					if u and tot and a then
						return string.format("已用约 %s GB / 总计 %s GB（可用 %s GB）", u, tot, a)
					end
				end
			end
		end
	end
	return nil
end

-- 无线 ADB 常出现「devices 为 device 但 shell 卡死」；有 timeout 时包一层避免 LuCI 挂死
-- 须先于 storage_summary 定义（Lua 5.1 局部函数不可前向引用）
local function adb_shell(sys, safe, inner, timeout_sec, use_to)
	timeout_sec = tonumber(timeout_sec) or 12
	inner = (inner or ""):gsub("'", "")
	if inner == "" then
		return ""
	end
	local cmd = "adb -s '" .. safe .. "' shell " .. inner .. " 2>/dev/null"
	if use_to then
		return sys.exec("timeout " .. tostring(timeout_sec) .. " " .. cmd) or ""
	end
	return sys.exec(cmd) or ""
end

local function storage_summary(sys, safe, use_to)
	local paths = { "/data", "/storage/emulated/0" }
	for _, p in ipairs(paths) do
		local inner = "df -Pk " .. p:gsub("'", "")
		local raw = adb_shell(sys, safe, inner, 18, use_to)
		local s = parse_df_pk_summary(trim_exec(raw))
		if s then
			return s
		end
	end
	return "（无法解析存储，可检查 /data 挂载）"
end

local function format_uptime_line(upraw)
	local total = tonumber((trim_exec(upraw or ""):match("^([%d%.]+)")))
	if not total or total < 0 then
		return "—"
	end
	total = math.floor(total + 0.5)
	local sec = total
	local d = math.floor(sec / 86400)
	sec = sec % 86400
	local h = math.floor(sec / 3600)
	sec = sec % 3600
	local m = math.floor(sec / 60)
	return string.format("约 %d 天 %d 小时 %d 分钟（总 %d 秒）", d, h, m, total)
end

local function parse_screen_state(pow)
	pow = pow or ""
	if #pow > 14000 then
		pow = pow:sub(1, 14000)
	end
	if pow:match("mWakefulness=Awake") or pow:match("Display Power: state=ON") or pow:match("mScreenOn=true") then
		return "亮屏"
	end
	if pow:match("mWakefulness=Asleep") or pow:match("mWakefulness=Dozing")
		or pow:match("Display Power: state=OFF") or pow:match("mScreenOn=false") then
		return "灭屏或休眠"
	end
	return "未知"
end

local function format_boot_line(vb, fl)
	local parts = {}
	if vb ~= "" then
		local zh = ({ green = "绿/通过", yellow = "黄/警告", orange = "橙/降级", red = "红" })[vb:lower()]
			or vb
		table.insert(parts, "VerifiedBoot " .. zh)
	end
	if fl == "1" then
		table.insert(parts, "Flash 已锁")
	elseif fl == "0" then
		table.insert(parts, "Flash 未锁")
	end
	if #parts == 0 then
		return "—"
	end
	return table.concat(parts, " · ")
end

-- adb connect + get-state，供 tv_info / tv_input_text 共用
local function adb_prepare_connection(sys, host, port)
	local safe = (host .. ":" .. port):gsub("'", "")
	local use_to = trim_exec(sys.exec("command -v timeout 2>/dev/null")) ~= ""
	local function timed(cmd, sec)
		sec = tonumber(sec)
		if use_to and sec then
			return sys.exec("timeout " .. tostring(sec) .. " " .. cmd) or ""
		end
		return sys.exec(cmd) or ""
	end
	sys.exec("adb start-server >/dev/null 2>&1")
	if use_to then
		sys.exec("timeout 20 adb connect '" .. safe .. "' >/dev/null 2>&1")
	else
		sys.exec("adb connect '" .. safe .. "' >/dev/null 2>&1")
	end
	local state = trim_exec(timed("adb -s '" .. safe .. "' get-state 2>/dev/null", 8))
	if state ~= "device" then
		if use_to then
			sys.exec("timeout 20 adb connect '" .. safe .. "' >/dev/null 2>&1")
		else
			sys.exec("adb connect '" .. safe .. "' >/dev/null 2>&1")
		end
		state = trim_exec(timed("adb -s '" .. safe .. "' get-state 2>/dev/null", 8))
	end
	return safe, use_to, timed, state
end

local function get_tv_section_name(uci)
	local sid = "main"
	local t = uci:get("tv_tools", sid)
	if t == "tv" then
		return sid
	end
	uci:set("tv_tools", sid, "tv")
	return sid
end

local function get_tv_host_port(uci)
	local host = uci:get("tv_tools", "main", "host") or ""
	local port = uci:get("tv_tools", "main", "port") or "5555"
	return host, port
end

function tv_input_text()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local disp = require "luci.dispatcher"
	local uci = require "luci.model.uci".cursor()

	http.prepare_content("application/json")
	if not disp.context or not disp.context.authsession then
		http.status(403, "Forbidden")
		http.write_json({ ok = false, err = "not authenticated" })
		return
	end

	local text = http.formvalue("text")
	if not text or type(text) ~= "string" or text == "" then
		http.write_json({ ok = false, err = "缺少 text 参数" })
		return
	end
	local arg = to_android_input_text(text)
	if not arg then
		http.write_json({ ok = false, err = "invalid", hint = "内容过长、含换行或含 shell 特殊字符 ;|&`$<> 等" })
		return
	end

	local host, port = get_tv_host_port(uci)
	if host == "" or host == "0.0.0.0" then
		http.write_json({ ok = false, err = "未配置 host（UCI tv_tools.main）" })
		return
	end

	local safe, use_to, timed, state = adb_prepare_connection(sys, host, port)
	if state ~= "device" then
		http.write_json({
			ok = false,
			err = "adb 非 device",
			display_host = host,
			display_port = port,
			state = state,
		})
		return
	end

	local remote = "input text " .. shell_single_quoted(arg)
	local out = trim_exec(adb_app_shell(sys, safe, remote, 35, use_to))
	http.write_json({ ok = true, stderr = out, sent_chars = #text, method = "input_text" })
end

function screencap_cfg()
	local http = require "luci.http"
	local disp = require "luci.dispatcher"
	local uci = require "luci.model.uci".cursor()

	http.prepare_content("application/json")
	if not disp.context or not disp.context.authsession then
		http.status(403, "Forbidden")
		http.write_json({ ok = false, err = "not authenticated" })
		return
	end

	local sid = get_tv_section_name(uci)
	if not sid or sid == "" then
		http.write_json({ ok = false, err = "无法定位 tv_tools 配置节" })
		return
	end

	if http.getenv("REQUEST_METHOD") == "POST" then
		http.formvalue("token")
		local auto_raw = tostring(http.formvalue("auto") or "")
		local itv_raw = tostring(http.formvalue("interval_ms") or "")
		local auto = (auto_raw == "1" or auto_raw == "true" or auto_raw == "on") and "1" or "0"
		local itv = tonumber(itv_raw) or 2000
		if itv < 1000 then
			itv = 1000
		elseif itv > 10000 then
			itv = 10000
		end
		itv = math.floor(itv + 0.5)
		uci:set("tv_tools", sid, "cap_auto_refresh", auto)
		uci:set("tv_tools", sid, "cap_interval_ms", tostring(itv))
		uci:commit("tv_tools")
		http.write_json({ ok = true, auto = auto, interval_ms = itv })
		return
	end

	local auto = uci:get("tv_tools", sid, "cap_auto_refresh") or "1"
	local itv = tonumber(uci:get("tv_tools", sid, "cap_interval_ms") or "2000") or 2000
	if itv < 1000 then
		itv = 1000
	elseif itv > 10000 then
		itv = 10000
	end
	itv = math.floor(itv + 0.5)
	http.write_json({ ok = true, auto = auto, interval_ms = itv })
end

local CAP_DIR = "/www/luci-static/tv-tools/caps"
local CAP_SEQ = CAP_DIR .. "/.seq"

local function is_png_file(path)
	local f = io.open(path, "rb")
	if not f then
		return false
	end
	local h = f:read(8)
	f:close()
	if not h or #h < 8 then
		return false
	end
	return h:byte(1) == 0x89 and h:sub(2, 4) == "PNG"
end

-- 当天内 mtime 最新的槽位；若无则回退为 .seq 指向的最后一次截图槽位
local function screencap_pick_latest_path()
	local now = os.date("*t")
	local start_day = os.time({
		year = now.year,
		month = now.month,
		day = now.day,
		hour = 0,
		min = 0,
		sec = 0,
	})
	local best_path, best_mtime = nil, 0
	for slot = 0, 2 do
		local path = CAP_DIR .. "/" .. slot .. ".png"
		local st = nixio.fs.stat(path)
		if st and st.mtime and st.mtime >= start_day and is_png_file(path) then
			if st.mtime > best_mtime then
				best_mtime = st.mtime
				best_path = path
			end
		end
	end
	if best_path then
		return best_path
	end
	local seq = 0
	local sf = io.open(CAP_SEQ, "r")
	if sf then
		seq = tonumber(sf:read("*l")) or 0
		sf:close()
	end
	if seq < 1 then
		return nil
	end
	local slot = (seq - 1) % 3
	return CAP_DIR .. "/" .. slot .. ".png"
end

-- POST：截一张图写入 caps/0..2.png，轮询覆盖（最多保留 3 张）
function screencap_run()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local disp = require "luci.dispatcher"
	local uci = require "luci.model.uci".cursor()

	http.prepare_content("application/json")
	if not disp.context or not disp.context.authsession then
		http.status(403, "Forbidden")
		http.write_json({ ok = false, err = "not authenticated" })
		return
	end

	local host, port = get_tv_host_port(uci)
	if host == "" or host == "0.0.0.0" then
		http.write_json({ ok = false, err = "未配置 host（UCI tv_tools.main）" })
		return
	end

	local safe, use_to, timed, state = adb_prepare_connection(sys, host, port)
	if state ~= "device" then
		http.write_json({
			ok = false,
			err = "adb 非 device",
			display_host = host,
			display_port = port,
			state = state,
		})
		return
	end

	local sh = "/usr/bin/tv-tools-adb-screencap.sh"
	if not nixio.fs.access(sh) then
		http.write_json({ ok = false, err = "缺少 " .. sh .. "，请部署 tv-tools-adb-screencap.sh" })
		return
	end

	sys.call("mkdir -p '" .. CAP_DIR:gsub("'", "") .. "' >/dev/null 2>&1")

	local seq = 0
	local sf = io.open(CAP_SEQ, "r")
	if sf then
		seq = tonumber(sf:read("*l")) or 0
		sf:close()
	end
	seq = seq + 1
	local slot = (seq - 1) % 3
	local outpath = CAP_DIR .. "/" .. tostring(slot) .. ".png"

	sf = io.open(CAP_SEQ, "w")
	if sf then
		sf:write(tostring(seq) .. "\n")
		sf:close()
	end

	local run = "sh '" .. sh:gsub("'", "") .. "' '" .. safe .. "' '" .. outpath:gsub("'", "") .. "' 2>&1"
	local errout
	if use_to then
		errout = trim_exec(sys.exec("timeout 45 " .. run) or "")
	else
		errout = trim_exec(sys.exec(run) or "")
	end

	if not is_png_file(outpath) then
		http.write_json({
			ok = false,
			err = "截屏失败或输出非 PNG",
			slot = slot,
			seq = seq,
			adb_log = errout,
		})
		return
	end

	http.write_json({
		ok = true,
		slot = slot,
		seq = seq,
		display_host = host,
		display_port = port,
	})
end

-- GET：slot=0..2 取指定槽；不传 slot 则取「当天 mtime 最新，否则 .seq 最后一次」PNG（需已登录 LuCI）
function screencap_image()
	local http = require "luci.http"
	local disp = require "luci.dispatcher"

	if not disp.context or not disp.context.authsession then
		http.status(403, "Forbidden")
		http.prepare_content("text/plain; charset=utf-8")
		http.write("Forbidden")
		return
	end

	local slot_raw = http.formvalue("slot")
	local path
	if slot_raw ~= nil and slot_raw ~= "" then
		local slot = tonumber(slot_raw)
		if slot == nil or slot < 0 or slot > 2 then
			http.status(400, "Bad Request")
			http.prepare_content("text/plain; charset=utf-8")
			http.write("bad slot")
			return
		end
		path = CAP_DIR .. "/" .. tostring(slot) .. ".png"
	else
		path = screencap_pick_latest_path()
	end

	if not path then
		http.status(404, "Not Found")
		http.prepare_content("text/plain; charset=utf-8")
		http.write("Not found")
		return
	end

	local data = nixio.fs.readfile(path)
	if not data or #data < 64 or data:byte(1) ~= 0x89 or data:sub(2, 4) ~= "PNG" then
		http.status(404, "Not Found")
		http.prepare_content("text/plain; charset=utf-8")
		http.write("Not found")
		return
	end

	http.prepare_content("image/png")
	http.header("Cache-Control", "no-store, no-cache, must-revalidate")
	http.header("Pragma", "no-cache")
	http.write(data)
end

function tv_info()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local disp = require "luci.dispatcher"
	local uci = require "luci.model.uci".cursor()

	http.prepare_content("application/json")
	if not disp.context or not disp.context.authsession then
		http.status(403, "Forbidden")
		http.write_json({ ok = false, err = "not authenticated" })
		return
	end

	local host, port = get_tv_host_port(uci)
	if host == "" or host == "0.0.0.0" then
		http.write_json({ ok = false, err = "未配置 host（UCI tv_tools.main）" })
		return
	end

	local safe, use_to, timed, state = adb_prepare_connection(sys, host, port)
	if state ~= "device" then
		http.write_json({
			ok = false,
			err = "adb 非 device（当前: " .. (state ~= "" and state or "unknown") .. "）。若刚出现过 protocol fault，请 SSH 执行: adb disconnect " .. safe .. "; adb connect " .. safe,
			display_host = host,
			display_port = port,
			serial = safe,
			state = state,
		})
		return
	end

	local function gp(name)
		name = (name or ""):gsub("[^%w%.%_%-]", "")
		if name == "" then
			return ""
		end
		return trim_exec(adb_shell(sys, safe, "getprop " .. name, 10, use_to))
	end

	local memraw = trim_exec(adb_shell(sys, safe, "cat /proc/meminfo", 18, use_to))

	local rel = gp("ro.build.version.release")
	local sdk = gp("ro.build.version.sdk")
	local patch = gp("ro.build.version.security_patch")
	local sys_line = ""
	if rel ~= "" then
		sys_line = "Android " .. rel
	end
	if sdk ~= "" then
		sys_line = sys_line .. (sys_line ~= "" and " " or "") .. "SDK" .. sdk
	end
	if patch ~= "" then
		sys_line = sys_line .. (sys_line ~= "" and " " or "") .. "安全补丁 " .. patch
	end
	if sys_line == "" then
		sys_line = "—"
	end

	local man = gp("ro.product.manufacturer")
	local brand = gp("ro.product.brand")
	local vendor_brand = "—"
	if man ~= "" and brand ~= "" then
		vendor_brand = man .. " / " .. brand
	elseif brand ~= "" then
		vendor_brand = brand
	elseif man ~= "" then
		vendor_brand = man
	end

	local abi = gp("ro.product.cpu.abi")
	if abi == "" then
		abi = gp("ro.product.cpu.abilist")
	end

	local pow = trim_exec(adb_shell(sys, safe, "dumpsys power", 14, use_to))
	local upraw = adb_shell(sys, safe, "cat /proc/uptime", 8, use_to)
	local boot_line = format_boot_line(gp("ro.boot.verifiedbootstate"), gp("ro.boot.flash.locked"))

	http.write_json({
		ok = true,
		display_host = host,
		display_port = port,
		summary = {
			vendor_brand = vendor_brand,
			model = gp("ro.product.model"),
			system = sys_line,
			abi = abi ~= "" and abi or "—",
			boot = boot_line,
			screen = parse_screen_state(pow),
			uptime = format_uptime_line(upraw),
			memory = format_memory_summary(memraw),
			storage = storage_summary(sys, safe, use_to),
		},
	})
end

local function safe_package_name(s)
	if not s or type(s) ~= "string" or #s < 2 or #s > 220 then
		return nil
	end
	if not s:match("^[%a%d%._%-]+$") then
		return nil
	end
	return s
end

-- POST form：一次返回 user[]、system[]（用户 pm -3 -f 带路径；系统 pm -s -f；去重、/data/app/ 判定卸载更新）
function apps_list()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local disp = require "luci.dispatcher"
	local uci = require "luci.model.uci".cursor()

	http.prepare_content("application/json")
	if not disp.context or not disp.context.authsession then
		http.status(403, "Forbidden")
		http.write_json({ ok = false, err = "not authenticated" })
		return
	end

	http.formvalue("token")

	local host, port = get_tv_host_port(uci)
	if host == "" or host == "0.0.0.0" then
		http.write_json({ ok = false, err = "未配置 host（UCI tv_tools.main）" })
		return
	end

	local safe, use_to, _, state = adb_prepare_connection(sys, host, port)
	if state ~= "device" then
		http.write_json({
			ok = false,
			err = "adb 非 device",
			state = state,
			display_host = host,
			display_port = port,
		})
		return
	end

	local function parse_pm_pkg_lines(out)
		local list = {}
		for line in (out or ""):gmatch("[^\r\n]+") do
			line = trim_exec(line)
			local pkg = line:match("=([^=]+)$") or line:match("^package:(.+)$")
			if pkg and pkg ~= "" then
				pkg = trim_exec(pkg)
				if pkg ~= "" then
					list[#list + 1] = pkg
				end
			end
		end
		return list
	end

	-- pm -f 行为 package:完整路径=包名；用户应用路径常含 ==（随机目录），不能用「首个 =」切分
	local function split_pm_list_package_f_line(line)
		line = trim_exec(line or "")
		if line:sub(1, 8) ~= "package:" then
			return nil, nil
		end
		local rest = line:sub(9)
		local lasteq = nil
		for i = #rest, 1, -1 do
			if rest:sub(i, i) == "=" then
				lasteq = i
				break
			end
		end
		if not lasteq or lasteq < 1 then
			return nil, nil
		end
		local path = trim_exec(rest:sub(1, lasteq - 1))
		local pkg = trim_exec(rest:sub(lasteq + 1))
		if path == "" or pkg == "" then
			return nil, nil
		end
		return pkg, path
	end

	local function parse_pm_lines_f(out)
		local rows = {}
		for line in (out or ""):gmatch("[^\r\n]+") do
			line = trim_exec(line)
			local pkg, path = split_pm_list_package_f_line(line)
			if pkg and path then
				rows[#rows + 1] = { pkg = pkg, path = path }
			end
		end
		return rows
	end

	local t240 = 240
	-- 用户应用：优先 -3 -f 一次拿到 package:apk路径=包名（与系统 -s -f 同格式）；失败再退回无路径的 pm -3
	local out_user = adb_app_shell(sys, safe, "pm list packages -3 -f", t240, use_to)
	local user_rows = parse_pm_lines_f(out_user)
	if #user_rows == 0 then
		local altf = adb_app_shell(sys, safe, "pm list packages --user 0 -3 -f", t240, use_to)
		if #parse_pm_lines_f(altf) > 0 then
			out_user = altf
			user_rows = parse_pm_lines_f(altf)
		end
	end

	local out_sys = adb_app_shell(sys, safe, "pm list packages -s -f", t240, use_to)
	local sys_rows = parse_pm_lines_f(out_sys)
	if #sys_rows == 0 then
		local alt2 = adb_app_shell(sys, safe, "pm list packages --user 0 -s -f", t240, use_to)
		if #parse_pm_lines_f(alt2) > 0 then
			out_sys = alt2
			sys_rows = parse_pm_lines_f(alt2)
		end
	end

	local user_apps = {}
	local user_set = {}
	if #user_rows > 0 then
		local seen = {}
		for _, row in ipairs(user_rows) do
			if not seen[row.pkg] then
				seen[row.pkg] = true
				user_set[row.pkg] = true
				table.insert(user_apps, {
					package = row.pkg,
					path = row.path,
					note = "user",
					removable = true,
					uninstallUpdatePossible = false,
					kind = "user",
				})
			end
		end
	else
		local out_plain = adb_app_shell(sys, safe, "pm list packages -3", t240, use_to)
		if not (out_plain or ""):find("package:", 1, true) then
			out_plain = adb_app_shell(sys, safe, "pm list packages --user 0 -3", t240, use_to)
		end
		out_user = out_plain or out_user
		local seen = {}
		for _, pkg in ipairs(parse_pm_pkg_lines(out_plain or "")) do
			if not seen[pkg] then
				seen[pkg] = true
				user_set[pkg] = true
				table.insert(user_apps, {
					package = pkg,
					path = "—",
					note = "user",
					removable = true,
					uninstallUpdatePossible = false,
					kind = "user",
				})
			end
		end
	end

	local system_apps = {}
	for _, row in ipairs(sys_rows) do
		if not user_set[row.pkg] then
			local in_data = row.path:find("/data/app/", 1, true) ~= nil
			local note = in_data and "sys.update" or "sys"
			table.insert(system_apps, {
				package = row.pkg,
				path = row.path,
				note = note,
				removable = false,
				uninstallUpdatePossible = in_data,
				kind = in_data and "sys_update" or "system",
			})
		end
	end

	if #user_apps == 0 and #system_apps == 0 then
		local uclip = trim_exec(out_user or "")
		local sclip = trim_exec(out_sys or "")
		if #uclip > 700 then
			uclip = uclip:sub(1, 700) .. "…"
		end
		if #sclip > 700 then
			sclip = sclip:sub(1, 700) .. "…"
		end
		http.write_json({
			ok = false,
			err = "未能获取应用列表（pm 无有效输出）。用户侧摘录：\n"
				.. uclip
				.. "\n\n系统侧摘录：\n"
				.. sclip,
		})
		return
	end

	http.write_json({
		ok = true,
		user = user_apps,
		system = system_apps,
	})
end

-- POST form：package= & kind=user|sys_update
function apps_uninstall()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local disp = require "luci.dispatcher"
	local uci = require "luci.model.uci".cursor()

	http.prepare_content("application/json")
	if not disp.context or not disp.context.authsession then
		http.status(403, "Forbidden")
		http.write_json({ ok = false, err = "not authenticated" })
		return
	end

	http.formvalue("token")
	local pkg = safe_package_name(http.formvalue("package"))
	if not pkg then
		http.write_json({ ok = false, err = "非法包名" })
		return
	end

	local kind = http.formvalue("kind") or "user"
	if kind ~= "user" and kind ~= "sys_update" then
		http.write_json({ ok = false, err = "kind 须为 user 或 sys_update" })
		return
	end

	local host, port = get_tv_host_port(uci)
	if host == "" or host == "0.0.0.0" then
		http.write_json({ ok = false, err = "未配置 host（UCI tv_tools.main）" })
		return
	end

	local safe, use_to, timed, state = adb_prepare_connection(sys, host, port)
	if state ~= "device" then
		http.write_json({ ok = false, err = "adb 非 device", state = state })
		return
	end

	local ush = "/usr/bin/tv-tools-adb-uninstall.sh"
	if not nixio.fs.access(ush) then
		http.write_json({ ok = false, err = "缺少 " .. ush .. "，请部署 tv-tools-adb-uninstall.sh" })
		return
	end

	local run = "sh '"
		.. ush:gsub("'", "")
		.. "' '"
		.. safe:gsub("'", "")
		.. "' '"
		.. pkg:gsub("'", "")
		.. "' '"
		.. kind:gsub("'", "")
		.. "' 2>&1"
	local out
	if use_to then
		out = trim_exec(sys.exec("timeout 120 " .. run) or "")
	else
		out = trim_exec(sys.exec(run) or "")
	end

	local ok = out:find("Success", 1, true) ~= nil
	http.write_json({ ok = ok, out = out, package = pkg, kind = kind })
end

-- POST form：package= ，执行 pm clear + force-stop + monkey 启动
function apps_cache_restart()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local disp = require "luci.dispatcher"
	local uci = require "luci.model.uci".cursor()

	http.prepare_content("application/json")
	if not disp.context or not disp.context.authsession then
		http.status(403, "Forbidden")
		http.write_json({ ok = false, err = "not authenticated" })
		return
	end

	http.formvalue("token")
	local pkg = safe_package_name(http.formvalue("package"))
	if not pkg then
		http.write_json({ ok = false, err = "非法包名" })
		return
	end

	local host, port = get_tv_host_port(uci)
	if host == "" or host == "0.0.0.0" then
		http.write_json({ ok = false, err = "未配置 host（UCI tv_tools.main）" })
		return
	end

	local safe, use_to, _, state = adb_prepare_connection(sys, host, port)
	if state ~= "device" then
		http.write_json({ ok = false, err = "adb 非 device", state = state })
		return
	end

	local sh = "/usr/bin/tv-tools-adb-app-refresh.sh"
	if not nixio.fs.access(sh) then
		http.write_json({ ok = false, err = "缺少 " .. sh .. "，请部署 tv-tools-adb-app-refresh.sh" })
		return
	end

	local run = "sh '"
		.. sh:gsub("'", "")
		.. "' '"
		.. safe:gsub("'", "")
		.. "' '"
		.. pkg:gsub("'", "")
		.. "' 2>&1"
	local out
	if use_to then
		out = trim_exec(sys.exec("timeout 180 " .. run) or "")
	else
		out = trim_exec(sys.exec(run) or "")
	end

	local ok = out:find("TVTOOLS_APP_REFRESH_OK", 1, true) ~= nil
	http.write_json({ ok = ok, out = out, package = pkg })
end

-- POST multipart：字段 apk + token；安装后删除临时文件
function apps_install_apk()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local disp = require "luci.dispatcher"
	local uci = require "luci.model.uci".cursor()

	local tmp = "/tmp/tvt_apk_" .. tostring(nixio.getpid()) .. ".apk"
	local fp
	local wrote = false

	http.setfilehandler(function(meta, chunk, eof)
		if not meta then
			return
		end
		if meta.name ~= "apk" then
			return
		end
		if chunk and #chunk > 0 then
			wrote = true
			if not fp then
				fp = io.open(tmp, "wb")
			end
			if fp then
				fp:write(chunk)
			end
		end
		if eof and fp then
			fp:close()
			fp = nil
		end
	end)

	if not disp.context or not disp.context.authsession then
		http.status(403, "Forbidden")
		http.prepare_content("application/json")
		http.write_json({ ok = false, err = "not authenticated" })
		return
	end

	http.formvalue("token")

	http.prepare_content("application/json")

	if not wrote or not nixio.fs.access(tmp) then
		os.remove(tmp)
		http.write_json({ ok = false, err = "未收到 APK 文件" })
		return
	end

	local st = nixio.fs.stat(tmp)
	if not st or not st.size or st.size < 64 then
		os.remove(tmp)
		http.write_json({ ok = false, err = "APK 无效或过小" })
		return
	end

	local fh = io.open(tmp, "rb")
	if not fh then
		os.remove(tmp)
		http.write_json({ ok = false, err = "读 APK 失败" })
		return
	end
	local sig = fh:read(2)
	fh:close()
	if sig ~= "PK" then
		os.remove(tmp)
		http.write_json({ ok = false, err = "不是合法 APK（ZIP）" })
		return
	end

	local host, port = get_tv_host_port(uci)
	if host == "" or host == "0.0.0.0" then
		os.remove(tmp)
		http.write_json({ ok = false, err = "未配置 host（UCI tv_tools.main）" })
		return
	end

	local safe, use_to, timed, state = adb_prepare_connection(sys, host, port)
	if state ~= "device" then
		os.remove(tmp)
		http.write_json({ ok = false, err = "adb 非 device", state = state })
		return
	end

	local inst = "/usr/bin/tv-tools-adb-install.sh"
	if not nixio.fs.access(inst) then
		os.remove(tmp)
		http.write_json({ ok = false, err = "缺少 " .. inst .. "，请部署 tv-tools-adb-install.sh" })
		return
	end

	local run = "sh '" .. inst:gsub("'", "") .. "' '" .. safe .. "' '" .. tmp:gsub("'", "") .. "' 2>&1"
	local out
	if use_to then
		out = trim_exec(sys.exec("timeout 400 " .. run) or "")
	else
		out = trim_exec(sys.exec(run) or "")
	end

	os.remove(tmp)

	local ok = out:find("Success", 1, true) ~= nil
	http.write_json({ ok = ok, out = out })
end

-- Syshell：已登录用户在路由器上执行 shell（与 SSH 类似；带会话 cwd，危险操作仅限管理员）
local SYSHELL_CWD_TAG = "__TVTOOLS_SH_CWD__"

local function syshell_safe_cwd(p)
	if not p or type(p) ~= "string" or p == "" then
		return nil
	end
	p = trim_exec(p)
	if p:sub(1, 1) ~= "/" or p:find("%.%.", 1, true) then
		return nil
	end
	local st = nixio.fs.stat(p)
	if st and st.type == "dir" then
		return p
	end
	return nil
end

function syshell_banner()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local disp = require "luci.dispatcher"

	http.prepare_content("application/json")
	if not disp.context or not disp.context.authsession then
		http.status(403, "Forbidden")
		http.write_json({ ok = false, err = "not authenticated" })
		return
	end

	http.formvalue("token")
	local host = trim_exec(sys.exec("hostname 2>/dev/null") or "") or "OpenWrt"
	local bb = ""
	local bf = io.open("/etc/banner", "r")
	if bf then
		bb = bf:read(12000) or ""
		bf:close()
	end
	if trim_exec(bb) == "" then
		bb = "BusyBox on OpenWrt — Syshell\n"
	end
	bb = bb:gsub("\r\n", "\n"):gsub("\r", "\n")
	http.write_json({ ok = true, host = host, banner = bb })
end

function syshell_exec()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local disp = require "luci.dispatcher"

	http.prepare_content("application/json")
	if not disp.context or not disp.context.authsession then
		http.status(403, "Forbidden")
		http.write_json({ ok = false, err = "not authenticated" })
		return
	end

	http.formvalue("token")

	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		http.write_json({ ok = false, err = "method" })
		return
	end

	local cmd = http.formvalue("cmd")
	if type(cmd) ~= "string" then
		cmd = ""
	end
	cmd = cmd:gsub("\r\n", "\n"):gsub("\r", "\n")
	if cmd:find("%z", 1, true) then
		http.write_json({ ok = false, err = "非法字符" })
		return
	end
	if #cmd > 16384 then
		http.write_json({ ok = false, err = "命令过长（上限 16KB）" })
		return
	end

	local sid = http.formvalue("sid") or ""
	sid = tostring(sid):gsub("[^a-fA-F0-9]", "")
	if #sid < 8 or #sid > 64 then
		sid = "default"
	end

	local cwdfile = "/tmp/tvt_syshell_" .. sid .. ".cwd"
	local cwd = "/root"
	do
		local cf = io.open(cwdfile, "r")
		if cf then
			local l = trim_exec(cf:read("*l") or "")
			cf:close()
			local sc = syshell_safe_cwd(l)
			if sc then
				cwd = sc
			end
		end
	end

	if trim_exec(cmd) == "" then
		http.write_json({ ok = true, out = "", cwd = cwd })
		return
	end

	local uuid = trim_exec(sys.exec("cat /proc/sys/kernel/random/uuid 2>/dev/null") or ""):gsub("[^a-fA-F0-9]", "")
	if uuid == "" then
		uuid = tostring(os.time())
	end
	local pid = tostring(nixio.getpid and nixio.getpid() or 0)
	local script = "/tmp/tvt_syshell_" .. pid .. "_" .. uuid:sub(1, 16) .. ".sh"
	local f = io.open(script, "w")
	if not f then
		http.write_json({ ok = false, err = "无法写入临时脚本" })
		return
	end
	f:write("#!/bin/sh\n")
	f:write("cd -- " .. shell_single_quoted(cwd) .. " 2>/dev/null || cd /\n")
	f:write(cmd)
	f:write("\nprintf '\\n" .. SYSHELL_CWD_TAG .. "%s\\n' \"$PWD\"\n")
	f:close()

	os.execute("chmod 755 " .. shell_single_quoted(script) .. " 2>/dev/null")

	local use_to = trim_exec(sys.exec("command -v timeout 2>/dev/null")) ~= ""
	local run = shell_single_quoted(script) .. " 2>&1"
	if use_to then
		run = "timeout 180 " .. run
	end
	local raw = sys.exec(run) or ""
	pcall(os.remove, script)

	local newcwd = cwd
	local out = raw
	local tagpat = "\n" .. SYSHELL_CWD_TAG .. "(.-)\n?%s*$"
	local tail = raw:match(tagpat)
	if not tail then
		tagpat = SYSHELL_CWD_TAG .. "(.-)\n?%s*$"
		tail = raw:match(tagpat)
	end
	if tail then
		local nc = syshell_safe_cwd(trim_exec(tail))
		if nc then
			newcwd = nc
		end
		out = raw:gsub("\n" .. SYSHELL_CWD_TAG .. ".-\n?%s*$", ""):gsub(SYSHELL_CWD_TAG .. ".-\n?%s*$", "")
		out = trim_exec(out)
	end

	local wf = io.open(cwdfile, "w")
	if wf then
		wf:write(newcwd .. "\n")
		wf:close()
	end

	local maxb = 480000
	if #out > maxb then
		out = out:sub(1, maxb) .. "\n…(输出已截断)\n"
	end

	http.write_json({ ok = true, out = out, cwd = newcwd })
end

local OC_CUSTOM_DIR = "/etc/openclash/custom"
local OC_OVERWRITE = OC_CUSTOM_DIR .. "/openclash_custom_overwrite.sh"
local OC_OVERWRITE_BAK = OC_CUSTOM_DIR .. "/openclash_custom_overwrite.sh.bak.tvtools"
local OC_OVERLAY = OC_CUSTOM_DIR .. "/vgeo-universal-overlay.yaml"
local OC_OVERLAY_BAK = OC_CUSTOM_DIR .. "/vgeo-universal-overlay.yaml.bak.tvtools"
local OC_DEFAULT_OVERWRITE_TEMPLATE = "/usr/share/tv-tools/openclash-default-overwrite.sh"
local OC_DEFAULT_OVERWRITE_LOCAL = OC_CUSTOM_DIR .. "/openclash-default-overwrite.local.sh"
local OC_OVERLAY_TEMPLATE = "/usr/share/tv-tools/vgeo-universal-overlay.yaml"
local OC_VGEO_FULL_TEMPLATE = "/usr/share/tv-tools/vgeo-openclash-overwrite.sh"
local OC_VGEO_USER = OC_CUSTOM_DIR .. "/vgeo-openclash-overwrite.sh"
local OC_MARK_BEGIN = "# >>> TVTOOLS_VGEO_BEGIN >>>"
local OC_MARK_END = "# <<< TVTOOLS_VGEO_END <<<"

local function is_tvtools_vgeo_embed_shell(s)
	if type(s) ~= "string" or trim_exec(s) == "" then
		return false
	end
	if s:find(OC_MARK_BEGIN, 1, true) then
		return true
	end
	if s:match("^#!%s*/bin/sh") and s:find("TVTOOLS_EMBED_PATH", 1, true) then
		return true
	end
	return false
end

local OC_DEFAULT_SCRIPT = [[#!/bin/sh
. /usr/share/openclash/ruby.sh
. /usr/share/openclash/log.sh
. /lib/functions.sh

# This script is called by /etc/init.d/openclash
# Add your custom overwrite scripts here, they will be take effict after the OpenClash own srcipts

LOG_TIP "Start Running Custom Overwrite Scripts..."
LOGTIME=$(echo $(date "+%Y-%m-%d %H:%M:%S"))
LOG_FILE="/tmp/openclash.log"
#Config Path
CONFIG_FILE="$1"

    #Simple Demo:
    #Key Overwrite Demo
    #1--config path
    #2--key name
    #3--value
    #ruby_edit "$CONFIG_FILE" "['redir-port']" "7892"
    #ruby_edit "$CONFIG_FILE" "['secret']" "123456"
    #ruby_edit "$CONFIG_FILE" "['dns']['enable']" "true"
    #ruby_edit "$CONFIG_FILE" "['dns']['proxy-server-nameserver']" "['https://doh.pub/dns-query','https://223.5.5.5:443/dns-query']"

    #Hash Overwrite Demo
    #1--config path
    #2--key name
    #3--hash type value
    #ruby_edit "$CONFIG_FILE" "['dns']['nameserver-policy']" "{'+.msftconnecttest.com'=>'114.114.114.114', '+.msftncsi.com'=>'114.114.114.114', 'geosite:gfw'=>['https://dns.cloudflare.com/dns-query', 'https://dns.google/dns-query#ecs=1.1.1.1/24&ecs-override=true'], 'geosite:cn'=>['114.114.114.114'], 'geosite:geolocation-!cn'=>['https://dns.cloudflare.com/dns-query', 'https://dns.google/dns-query#ecs=1.1.1.1/24&ecs-override=true']}"
    #ruby_edit "$CONFIG_FILE" "['sniffer']" "{'enable'=>true, 'parse-pure-ip'=>true, 'force-domain'=>['+.netflix.com', '+.nflxvideo.net', '+.amazonaws.com', '+.media.dssott.com'], 'skip-domain'=>['+.apple.com', 'Mijia Cloud', 'dlg.io.mi.com', '+.oray.com', '+.sunlogin.net'], 'sniff'=>{'TLS'=>nil, 'HTTP'=>{'ports'=>[80, '8080-8880'], 'override-destination'=>true}}}"

    #Map Edit Demo
    #1--config path
    #2--map name
    #3--key name
    #4--sub key name
    #5--value
    #ruby_map_edit "$CONFIG_FILE" "['proxy-providers']" "HK" "['url']" "http://test.com"

    #Hash Merge Demo
    #1--config path
    #2--key name
    #3--hash
    #ruby_merge_hash "$CONFIG_FILE" "['proxy-providers']" "'TW'=>{'type'=>'http', 'path'=>'./proxy_provider/TW.yaml', 'url'=>'https://gist.githubusercontent.com/raw/tw_clash', 'interval'=>3600, 'health-check'=>{'enable'=>true, 'url'=>'http://cp.cloudflare.com/generate_204', 'interval'=>300}}"
    #ruby_merge_hash "$CONFIG_FILE" "['rule-providers']" "'Reject'=>{'type'=>'http', 'behavior'=>'classical', 'url'=>'https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/refs/heads/master/Clash/Apple.list', 'path'=>'./rule_provider/Apple.list', 'interval'=>86400}"

    #Array Edit Demo
    #1--config path
    #2--key name
    #3--match key name
    #4--match key value
    #5--target key name
    #6--target key value
    #ruby_arr_edit "$CONFIG_FILE" "['proxy-groups']" "['name']" "Proxy" "['type']" "smart"
    #ruby_arr_edit "$CONFIG_FILE" "['dns']['nameserver']" "" "114.114.114.114" "" "119.29.29.29"

    #Array Insert Value Demo:
    #1--config path
    #2--key name
    #3--position(start from 0, end with -1)
    #4--value
    #ruby_arr_insert "$CONFIG_FILE" "['dns']['nameserver']" "0" "114.114.114.114"

    #Array Insert Hash Demo:
    #1--config path
    #2--key name
    #3--position(start from 0, end with -1)
    #4--hash
    #ruby_arr_insert_hash "$CONFIG_FILE" "['proxy-groups']" "0" "{'name'=>'Disney', 'type'=>'select', 'disable-udp'=>false, 'use'=>['TW', 'SG', 'HK']}"
    #ruby_arr_insert_hash "$CONFIG_FILE" "['proxies']" "0" "{'name'=>'HKG 01', 'type'=>'ss', 'server'=>'cc.hd.abc', 'port'=>'12345', 'cipher'=>'aes-128-gcm', 'password'=>'123456', 'udp'=>true, 'plugin'=>'obfs', 'plugin-opts'=>{'mode'=>'http', 'host'=>'microsoft.com'}}"
    #ruby_arr_insert_hash "$CONFIG_FILE" "['listeners']" "0" "{'name'=>'name', 'type'=>'shadowsocks', 'port'=>'12345', 'listen'=>'0.0.0.0', 'rule'=>'sub-rule-1', 'proxy'=>'proxy'}"

    #Array Insert Other Array Demo:
    #1--config path
    #2--key name
    #3--position(start from 0, end with -1)
    #4--array
    #ruby_arr_insert_arr "$CONFIG_FILE" "['dns']['proxy-server-nameserver']" "0" "['https://doh.pub/dns-query','https://223.5.5.5:443/dns-query']"

    #Array Insert From Yaml File Demo:
    #1--config path
    #2--key name
    #3--position(start from 0, end with -1)
    #4--value file path
    #5--value key name in #4 file
    #ruby_arr_add_file "$CONFIG_FILE" "['dns']['fallback-filter']['ipcidr']" "0" "/etc/openclash/custom/openclash_custom_fallback_filter.yaml" "['fallback-filter']['ipcidr']"

    #Delete Array Value Demo:
    #1--config path
    #2--key name
    #3--value
    #ruby_delete "$CONFIG_FILE" "['dns']['nameserver']" "114.114.114.114"

    #Delete Key Demo:
    #1--config path
    #2--key name
    #3--key name
    #ruby_delete "$CONFIG_FILE" "['dns']" "nameserver"
    #ruby_delete "$CONFIG_FILE" "" "dns"

    #Ruby Script Demo:
    #ruby -ryaml -rYAML -I "/usr/share/openclash" -E UTF-8 -e "
    #   begin
    #      Value = YAML.load_file('$CONFIG_FILE');
    #   rescue Exception => e
    #      puts '${LOGTIME} [error] Load File Failed,【' + e.message + '】';
    #   end;

        #General
    #   begin
    #   Thread.new{
    #      Value['redir-port']=7892;
    #      Value['tproxy-port']=7895;
    #      Value['port']=7890;
    #      Value['socks-port']=7891;
    #      Value['mixed-port']=7893;
    #   }.join;

    #   rescue Exception => e
    #      puts '${LOGTIME} [error] Set General Failed,【' + e.message + '】';
    #   ensure
    #      File.open('$CONFIG_FILE','w') {|f| YAML.dump(Value, f)};
    #   end" 2>/dev/null >> $LOG_FILE

exit 0
]]

-- 将 overlay 正文内嵌进覆写脚本（heredoc），运行时 cat 到 /tmp/…$$，Ruby 只读该临时文件；不依赖 /etc/openclash/custom/vgeo-universal-overlay.yaml 参与合并（该文件仍可写入供 TV-Tools 编辑）
local OC_EMBED_ENV = "TVTOOLS_EMBED_PATH"

local function build_oc_inject_block(overlay_body)
	if type(overlay_body) ~= "string" or trim_exec(overlay_body) == "" then
		return nil
	end
	local body = overlay_body:gsub("\r\n", "\n"):gsub("\r", "\n")
	local delim = "TVTOOLS_VGEO_" .. tostring(nixio.getpid and nixio.getpid() or 0) .. "_" .. tostring(os.time()):gsub("%s+", "")
	while body:find("\n" .. delim .. "\n", 1, true) or body:match("^" .. delim .. "\n") or body:match("\n" .. delim .. "$") do
		delim = delim .. "X"
	end
	local parts = {
		"\n",
		OC_MARK_BEGIN,
		"\n",
		"export ",
		OC_EMBED_ENV,
		'="/tmp/tvtools_vgeo_embed.$$"\n',
		"cat > \"$",
		OC_EMBED_ENV,
		"\" <<'",
		delim,
		"'\n",
		body,
		(body:match("\n$") and "" or "\n"),
		delim,
		"\n\n",
		"ruby -ryaml -rYAML -I \"/usr/share/openclash\" -E UTF-8 -e \"\n",
		"begin\n",
		"  cfg = YAML.load_file('$CONFIG_FILE') || {}\n",
		"  ov = YAML.load_file(ENV['",
		OC_EMBED_ENV,
		"']) || {}\n",
		"  cfg['proxy-groups'] ||= []\n",
		"  cfg['rules'] ||= []\n",
		"  pg = ov['prepend-proxy-groups'] || []\n",
		"  pr = ov['prepend-rules'] || []\n",
		"  cfg['proxy-groups'] = pg + cfg['proxy-groups']\n",
		"  cfg['rules'] = pr + cfg['rules']\n",
		"  File.open('$CONFIG_FILE','w') {|f| YAML.dump(cfg, f)}\n",
		"rescue Exception => e\n",
		"  puts '${LOGTIME} [error] Merge VGEO Overlay Failed,【' + e.message + '】'\n",
		"end\n",
		"\" >> \"$LOG_FILE\" 2>&1\n",
		OC_MARK_END,
		"\n",
	}
	return table.concat(parts)
end

-- 由 YAML 拼成「整份」覆写 shell（与默认母版注入方式一致：整文件写入 openclash_custom_overwrite.sh）
local OC_VGEO_SHELL_HEAD = [[#!/bin/sh
. /usr/share/openclash/ruby.sh
. /usr/share/openclash/log.sh
. /lib/functions.sh

# TV-Tools VGEO 整份覆写：内嵌 YAML（heredoc）经 Ruby 合并进 CONFIG_FILE
LOG_TIP "Start Running Custom Overwrite Scripts..."
LOGTIME=$(echo $(date "+%Y-%m-%d %H:%M:%S"))
LOG_FILE="/tmp/openclash.log"
CONFIG_FILE="$1"

]]

local function build_full_vgeo_overwrite_from_yaml(yaml_body)
	local frag = build_oc_inject_block(yaml_body)
	if not frag then
		return nil
	end
	return OC_VGEO_SHELL_HEAD .. frag .. "exit 0\n"
end

local function require_auth_json(http, disp)
	http.prepare_content("application/json")
	if not disp.context or not disp.context.authsession then
		http.status(403, "Forbidden")
		http.write_json({ ok = false, err = "not authenticated" })
		return false
	end
	return true
end

local function write_file(path, content)
	local data = content or ""
	if nixio and nixio.fs and type(nixio.fs.writefile) == "function" then
		local ok = pcall(nixio.fs.writefile, path, data)
		if ok and nixio.fs.access(path) then
			return true
		end
	end
	local f = io.open(path, "w")
	if not f then
		return false
	end
	f:write(data)
	f:close()
	return true
end

local function read_file(path)
	if nixio and nixio.fs and type(nixio.fs.readfile) == "function" then
		local ok, data = pcall(nixio.fs.readfile, path)
		if ok and type(data) == "string" then
			return data
		end
	end
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local c = f:read("*a")
	f:close()
	return c
end

local function load_overlay_template()
	local s = read_file(OC_OVERLAY_TEMPLATE)
	if type(s) ~= "string" or trim_exec(s) == "" then
		return nil
	end
	return s
end

local function load_default_overwrite_template()
	local loc = read_file(OC_DEFAULT_OVERWRITE_LOCAL)
	if type(loc) == "string" and trim_exec(loc) ~= "" then
		return loc
	end
	local s = read_file(OC_DEFAULT_OVERWRITE_TEMPLATE)
	if type(s) ~= "string" or trim_exec(s) == "" then
		return OC_DEFAULT_SCRIPT
	end
	-- 兼容历史短版模板：若缺少常见注释示例块，则使用内置完整模板
	if not s:find("Key Overwrite Demo", 1, true) or not s:find("Hash Overwrite Demo", 1, true) then
		return OC_DEFAULT_SCRIPT
	end
	return s
end

local function overlay_placeholder_text()
	return [[# VGEO overlay 模板未找到
# 期望文件: /usr/share/tv-tools/vgeo-universal-overlay.yaml
#
# 说明：
# - 你当前看到这段文字，是因为路由器上尚未安装模板文件，或安装路径不完整。
# - 可先点击“注入”（若系统中已有模板会写入运行文件），或重新安装包含该模板的 tv-tools 包。
# - 你也可以直接在此编辑后保存到「运行 overlay」目标文件。
]]
end

local function openclash_target_path(target)
	target = tostring(target or "")
	if target == "" then
		target = "runtime"
	end
	if target == "runtime" then
		return "runtime", OC_OVERWRITE, nil
	elseif target == "openclash_default" then
		return "openclash_default", OC_DEFAULT_OVERWRITE_LOCAL, nil
	elseif target == "base_rules" then
		return "base_rules", OC_VGEO_FULL_TEMPLATE, nil
	elseif target == "vgeo_yaml" then
		return "vgeo_yaml", OC_OVERLAY, nil
	end
	return nil, nil, nil
end

local function ensure_dir(path)
	os.execute("mkdir -p '" .. tostring(path):gsub("'", "") .. "' >/dev/null 2>&1")
end

local function ensure_parent_dir(path)
	local p = tostring(path or "")
	local d = p:match("^(.*)/[^/]+$")
	if d and d ~= "" then
		ensure_dir(d)
	end
end

local function backup_once(src, bak)
	if nixio.fs.access(src) and not nixio.fs.access(bak) then
		os.execute("cp -f '" .. src:gsub("'", "") .. "' '" .. bak:gsub("'", "") .. "' >/dev/null 2>&1")
	end
end

local function oc_chmod_plus_x(path)
	local p = tostring(path or ""):gsub("'", "")
	if p == "" then
		return
	end
	os.execute("chmod +x '" .. p .. "' >/dev/null 2>&1")
end

function openclash_backup()
	local http = require "luci.http"
	local disp = require "luci.dispatcher"
	if not require_auth_json(http, disp) then
		return
	end
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		http.write_json({ ok = false, err = "method" })
		return
	end
	http.formvalue("token")
	ensure_dir(OC_CUSTOM_DIR)
	if not nixio.fs.access(OC_OVERWRITE) then
		write_file(OC_OVERWRITE, OC_DEFAULT_SCRIPT)
	end
	os.execute("cp -f '" .. OC_OVERWRITE:gsub("'", "") .. "' '" .. OC_OVERWRITE_BAK:gsub("'", "") .. "' >/dev/null 2>&1")
	if nixio.fs.access(OC_OVERLAY) then
		os.execute("cp -f '" .. OC_OVERLAY:gsub("'", "") .. "' '" .. OC_OVERLAY_BAK:gsub("'", "") .. "' >/dev/null 2>&1")
	end
	http.write_json({
		ok = true,
		msg = "OpenClash 覆写文件已备份",
		files = { overwrite = OC_OVERWRITE_BAK, overlay = OC_OVERLAY_BAK },
	})
end

function openclash_restore_default()
	local http = require "luci.http"
	local disp = require "luci.dispatcher"
	if not require_auth_json(http, disp) then
		return
	end
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		http.write_json({ ok = false, err = "method" })
		return
	end
	http.formvalue("token")
	ensure_dir(OC_CUSTOM_DIR)
	local restored = false
	if nixio.fs.access(OC_OVERWRITE_BAK) then
		os.execute("cp -f '" .. OC_OVERWRITE_BAK:gsub("'", "") .. "' '" .. OC_OVERWRITE:gsub("'", "") .. "' >/dev/null 2>&1")
		restored = true
	else
		write_file(OC_OVERWRITE, OC_DEFAULT_SCRIPT)
	end
	if nixio.fs.access(OC_OVERLAY_BAK) then
		os.execute("cp -f '" .. OC_OVERLAY_BAK:gsub("'", "") .. "' '" .. OC_OVERLAY:gsub("'", "") .. "' >/dev/null 2>&1")
	else
		pcall(os.remove, OC_OVERLAY)
	end
	http.write_json({
		ok = true,
		msg = restored and "已从备份恢复 OpenClash 覆写" or "已恢复为默认覆写脚本",
		files = { overwrite = OC_OVERWRITE, overlay = OC_OVERLAY },
	})
end

function openclash_inject()
	local http = require "luci.http"
	local disp = require "luci.dispatcher"
	if not require_auth_json(http, disp) then
		return
	end
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		http.write_json({ ok = false, err = "method" })
		return
	end
	http.formvalue("token")
	local target = http.formvalue("target") or "runtime"
	local posted = http.formvalue("content")
	local has_post = type(posted) == "string" and trim_exec(posted) ~= ""
	local editor_text = has_post and posted or nil
	ensure_dir(OC_CUSTOM_DIR)
	local inject_expect_mark = false
	if not nixio.fs.access(OC_OVERWRITE) then
		write_file(OC_OVERWRITE, OC_DEFAULT_SCRIPT)
	end
	backup_once(OC_OVERWRITE, OC_OVERWRITE_BAK)
	backup_once(OC_OVERLAY, OC_OVERLAY_BAK)
	if target == "runtime" or target == "openclash_default" then
		local shell = editor_text
		if not shell or trim_exec(shell) == "" then
			if target == "runtime" then
				shell = read_file(OC_OVERWRITE) or load_default_overwrite_template()
			else
				shell = load_default_overwrite_template()
			end
		end
		if not shell or trim_exec(shell) == "" then
			http.write_json({ ok = false, err = "覆写脚本内容为空（文本框为空且无可用回退）" })
			return
		end
		if not write_file(OC_OVERWRITE, shell) then
			http.write_json({ ok = false, err = "写入 overwrite 脚本失败: " .. OC_OVERWRITE })
			return
		end
	elseif target == "base_rules" or target == "vgeo_yaml" then
		local shell = editor_text
		-- base_rules 页 GET 返回的是「已生成的整份 sh」；用户未改框就注入时 POST 仍是旧 sh。
		-- 原逻辑遇 shebang 会跳过 YAML 重建且内容非空不再读母版，导致升级包内 vgeo-universal-overlay.yaml 永远不生效。
		if shell and trim_exec(shell) ~= "" then
			if shell:match("^#!%s*/bin/sh") or shell:find(OC_MARK_BEGIN, 1, true) or shell:find("TVTOOLS_EMBED_PATH", 1, true) then
				shell = nil
			end
		end
		if shell and trim_exec(shell) ~= "" then
			if not shell:match("^#!%s*/bin/sh") and not shell:find(OC_MARK_BEGIN, 1, true) then
				if shell:find("prepend%-proxy%-groups:", 1) or shell:find("prepend%-rules:", 1) then
					shell = build_full_vgeo_overwrite_from_yaml(shell)
				end
			end
		end
		if not shell or trim_exec(shell) == "" then
			if target == "base_rules" then
				shell = read_file(OC_VGEO_USER)
			else
				shell = read_file(OC_OVERLAY)
			end
		end
		-- 若曾点「保存」把整份嵌入 sh 写入 vgeo-openclash-overwrite.sh，此处会挡住母版回退，必须丢弃
		if shell and is_tvtools_vgeo_embed_shell(shell) then
			shell = nil
		end
		-- base_rules 注入不再读 /etc/.../vgeo-universal-overlay.yaml，避免历史副本永远盖住包内母版；改规则请用 vgeo_yaml 目标保存并注入。
		if target == "vgeo_yaml" and shell and trim_exec(shell) ~= "" then
			if not shell:match("^#!%s*/bin/sh") and not shell:find(OC_MARK_BEGIN, 1, true) then
				if shell:find("prepend%-proxy%-groups:", 1) or shell:find("prepend%-rules:", 1) then
					shell = build_full_vgeo_overwrite_from_yaml(shell)
				end
			end
		end
		if not shell or trim_exec(shell) == "" then
			local y = load_overlay_template()
			shell = y and build_full_vgeo_overwrite_from_yaml(y)
		end
		if not shell or trim_exec(shell) == "" then
			http.write_json({ ok = false, err = "无法生成 VGEO 整份覆写（文本框为空且母版 yaml 不可用）: " .. OC_OVERLAY_TEMPLATE })
			return
		end
		if not write_file(OC_OVERWRITE, shell) then
			http.write_json({ ok = false, err = "写入 overwrite 脚本失败: " .. OC_OVERWRITE })
			return
		end
		inject_expect_mark = shell:find(OC_MARK_BEGIN, 1, true) ~= nil
	else
		http.write_json({ ok = false, err = "未知注入目标: " .. tostring(target) })
		return
	end
	oc_chmod_plus_x(OC_OVERWRITE)
	if inject_expect_mark then
		local disk = read_file(OC_OVERWRITE)
		if not disk or not disk:find(OC_MARK_BEGIN, 1, true) then
			http.write_json({
				ok = false,
				err = "注入后校验失败：磁盘上的覆写脚本未包含 TVTOOLS 标记块。请在 SSH 执行: ls -la /etc/openclash/custom/openclash_custom_overwrite.sh; wc -c /etc/openclash/custom/openclash_custom_overwrite.sh; tail -n 30 /etc/openclash/custom/openclash_custom_overwrite.sh",
			})
			return
		end
	end
	local hints = {
		"本次注入：文本框有有效 YAML 时以框内为准。VGEO「整份覆写」回退链用包内母版（不读 /etc 下 vgeo-universal-overlay.yaml）；「vgeo-universal-overlay.yaml」目标才用 /etc 副本。均整文件写入 openclash_custom_overwrite.sh（合并异常见 /tmp/openclash.log）。",
		"本插件写入的覆写脚本是 " .. OC_OVERWRITE .. "（OpenClash 主流程会 source 该文件）。",
		"LuCI「覆写设置」里 /etc/openclash/overwrite/ 下的条目（如 tvtools_vgeo.sh）是另一套：需单独打开开关才会执行，与上述路径不是同一个文件。",
		"注入后若规则未立即变化：请在 OpenClash 中「应用配置」，或勾选「注入后重启 OpenClash」。",
	}
	local restart_req = http.formvalue("restart")
	local restart_launched = false
	if restart_req == "1" or restart_req == "true" then
		os.execute("/etc/init.d/openclash restart >/dev/null 2>&1 &")
		restart_launched = true
		table.insert(hints, "已后台异步执行 /etc/init.d/openclash restart（可能有数秒断流）。")
	end
	http.write_json({
		ok = true,
		msg = "注入完成（按当前下拉模板）",
		target = target,
		files = { overwrite = OC_OVERWRITE, overlay = OC_OVERLAY },
		hints = hints,
		restart_openclash = restart_launched,
		inject_verified = inject_expect_mark or nil,
	})
end

function openclash_script_get()
	local http = require "luci.http"
	local disp = require "luci.dispatcher"
	if not require_auth_json(http, disp) then
		return
	end
	if http.getenv("REQUEST_METHOD") ~= "GET" then
		http.status(405, "Method Not Allowed")
		http.write_json({ ok = false, err = "method" })
		return
	end
	local raw = http.formvalue("target")
	local target_key, path, default_content = openclash_target_path(raw)
	if not target_key then
		http.write_json({ ok = false, err = "unknown target" })
		return
	end
	if target_key == "runtime" then
		local content = read_file(OC_OVERWRITE)
		if not content then
			content = load_default_overwrite_template()
		end
		http.write_json({
			ok = true,
			target = "runtime",
			path = OC_OVERWRITE,
			content = content or "",
			readonly = false,
		})
		return
	end
	if target_key == "openclash_default" then
		local content = load_default_overwrite_template()
		http.write_json({
			ok = true,
			target = "openclash_default",
			path = OC_DEFAULT_OVERWRITE_LOCAL,
			content = content or "",
			readonly = false,
		})
		return
	end
	if target_key == "vgeo_yaml" then
		local content = read_file(OC_OVERLAY)
		if not content or trim_exec(content) == "" then
			content = load_overlay_template()
		end
		if not content or trim_exec(content) == "" then
			content = overlay_placeholder_text()
		end
		http.write_json({
			ok = true,
			target = "vgeo_yaml",
			path = OC_OVERLAY,
			content = content or "",
			readonly = false,
		})
		return
	end
	if target_key == "base_rules" then
		local y = load_overlay_template()
		local content = y and trim_exec(y) ~= "" and build_full_vgeo_overwrite_from_yaml(y)
		if not content or trim_exec(content) == "" then
			content = "# 未找到 VGEO 母版: " .. OC_OVERLAY_TEMPLATE .. "\nexit 0\n"
		end
		http.write_json({
			ok = true,
			target = "base_rules",
			path = OC_VGEO_FULL_TEMPLATE,
			content = content or "",
			readonly = false,
		})
		return
	end
	http.write_json({ ok = false, err = "internal: unhandled target" })
end

function openclash_script_save()
	local http = require "luci.http"
	local disp = require "luci.dispatcher"
	if not require_auth_json(http, disp) then
		return
	end
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		http.write_json({ ok = false, err = "method" })
		return
	end
	http.formvalue("token")
	local t = http.formvalue("target") or "runtime"
	if t == "base_rules" then
		http.write_json({ ok = false, err = "「VGEO 整份覆写」为包内母版预览，请选 vgeo-universal-overlay.yaml 保存规则" })
		return
	end
	local path
	local msg
	if t == "runtime" then
		path = OC_OVERWRITE
		msg = "已保存到运行中覆写脚本"
	elseif t == "base_rules" then
		path = OC_VGEO_USER
		msg = "已保存到 /etc/openclash/custom/vgeo-openclash-overwrite.sh"
	elseif t == "vgeo_yaml" then
		path = OC_OVERLAY
		msg = "已保存到 /etc/openclash/custom/vgeo-universal-overlay.yaml"
	elseif t == "openclash_default" then
		path = OC_DEFAULT_OVERWRITE_LOCAL
		msg = "已保存到 /etc/openclash/custom/openclash-default-overwrite.local.sh（优先于包内默认模板）"
	else
		http.write_json({ ok = false, err = "unknown target" })
		return
	end
	local content = http.formvalue("content")
	if type(content) ~= "string" then
		http.write_json({ ok = false, err = "missing content" })
		return
	end
	if #content > 1024 * 1024 then
		http.write_json({ ok = false, err = "content too large (>1MB)" })
		return
	end
	ensure_parent_dir(path)
	if not write_file(path, content) then
		http.write_json({ ok = false, err = "写入失败: " .. path })
		return
	end
	http.write_json({
		ok = true,
		msg = msg,
		target = t,
		path = path,
		size = #content,
	})
end

function index()
	if not nixio.fs.access("/etc/config/luci") then
		return
	end

	entry({ "admin", "services", "tv-tools", "adb" }, call("adb_key")).leaf = true
	entry({ "admin", "services", "tv-tools", "textinput" }, call("tv_input_text")).leaf = true
	entry({ "admin", "services", "tv-tools", "screencap" }, call("screencap_run")).leaf = true
	entry({ "admin", "services", "tv-tools", "screencap_cfg" }, call("screencap_cfg")).leaf = true
	entry({ "admin", "services", "tv-tools", "capture" }, call("screencap_image")).leaf = true
	entry({ "admin", "services", "tv-tools", "tvinfo" }, call("tv_info")).leaf = true
	entry({ "admin", "services", "tv-tools", "apps", "list" }, call("apps_list")).leaf = true
	entry({ "admin", "services", "tv-tools", "apps", "uninstall" }, call("apps_uninstall")).leaf = true
	entry({ "admin", "services", "tv-tools", "apps", "refresh" }, call("apps_cache_restart")).leaf = true
	entry({ "admin", "services", "tv-tools", "apps", "install" }, call("apps_install_apk")).leaf = true
	entry({ "admin", "services", "tv-tools", "syshell", "banner" }, call("syshell_banner")).leaf = true
	entry({ "admin", "services", "tv-tools", "syshell", "exec" }, call("syshell_exec")).leaf = true
	entry({ "admin", "services", "tv-tools", "openclash", "backup" }, call("openclash_backup")).leaf = true
	entry({ "admin", "services", "tv-tools", "openclash", "restore_default" }, call("openclash_restore_default")).leaf = true
	entry({ "admin", "services", "tv-tools", "openclash", "inject" }, call("openclash_inject")).leaf = true
	entry({ "admin", "services", "tv-tools", "openclash", "script_get" }, call("openclash_script_get")).leaf = true
	entry({ "admin", "services", "tv-tools", "openclash", "script_save" }, call("openclash_script_save")).leaf = true

	local e = entry({ "admin", "services", "tv-tools" }, template("tv_tools/main"), _("TV-Tools"), 90)
	e.dependent = true
end
