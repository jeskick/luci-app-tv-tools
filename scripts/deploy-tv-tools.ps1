# TV-Tools 部署：停 uhttpd -> 删本插件旧文件与 LuCI 缓存 -> 上传(UTF-8/LF，含 /usr/share/tv-tools 母版) -> 启动 uhttpd
# 用法: .\scripts\deploy-tv-tools.ps1 -RouterIp <ROUTER_IP>

param(
	[Parameter(Mandatory = $true)]
	[string] $RouterIp,
	[string] $User = "root"
)

$ErrorActionPreference = "Stop"
$Remote = "${User}@${RouterIp}"
$Base = Split-Path -Parent $PSScriptRoot

$Files = @(
	@{ Local = Join-Path $Base "luci-app-tv-tools\luasrc\controller\tv_tools.lua"; Remote = "/usr/lib/lua/luci/controller/tv_tools.lua" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\luasrc\view\tv_tools\main.htm"; Remote = "/usr/lib/lua/luci/view/tv_tools/main.htm" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\htdocs\luci-static\tv-tools\tv-tools.css"; Remote = "/www/luci-static/tv-tools/tv-tools.css" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\htdocs\luci-static\tv-tools\tv-tools.js"; Remote = "/www/luci-static/tv-tools/tv-tools.js" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\root\usr\share\tv-tools\vgeo-universal-overlay.yaml"; Remote = "/usr/share/tv-tools/vgeo-universal-overlay.yaml" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\root\usr\share\tv-tools\openclash-default-overwrite.sh"; Remote = "/usr/share/tv-tools/openclash-default-overwrite.sh" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\root\usr\bin\tv-tools-adb-key.sh"; Remote = "/usr/bin/tv-tools-adb-key.sh" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\root\usr\bin\tv-tools-adb-text.sh"; Remote = "/usr/bin/tv-tools-adb-text.sh" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\root\usr\bin\tv-tools-adb-text-inner.sh"; Remote = "/usr/bin/tv-tools-adb-text-inner.sh" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\root\usr\bin\tv-tools-adb-screencap.sh"; Remote = "/usr/bin/tv-tools-adb-screencap.sh" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\root\usr\bin\tv-tools-adb-pkg-list.sh"; Remote = "/usr/bin/tv-tools-adb-pkg-list.sh" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\root\usr\bin\tv-tools-adb-pkg-list-inner.sh"; Remote = "/usr/bin/tv-tools-adb-pkg-list-inner.sh" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\root\usr\bin\tv-tools-adb-install.sh"; Remote = "/usr/bin/tv-tools-adb-install.sh" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\root\usr\bin\tv-tools-adb-uninstall.sh"; Remote = "/usr/bin/tv-tools-adb-uninstall.sh" },
	@{ Local = Join-Path $Base "luci-app-tv-tools\root\usr\bin\tv-tools-adb-app-refresh.sh"; Remote = "/usr/bin/tv-tools-adb-app-refresh.sh" }
)
$ConfigDefault = Join-Path $Base "luci-app-tv-tools\root\etc\config\tv_tools"

foreach ($f in $Files) {
	if (-not (Test-Path $f.Local)) { throw "Missing: $($f.Local)" }
}

function New-TempLfUtf8 {
	param([string] $SourcePath)
	$text = [System.IO.File]::ReadAllText($SourcePath)
	$text = $text -replace "`r`n", "`n" -replace "`r", "`n"
	$t = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tv-tools-deploy-" + [Guid]::NewGuid().ToString("n"))
	$enc = New-Object System.Text.UTF8Encoding $false
	[System.IO.File]::WriteAllText($t, $text, $enc)
	return $t
}

# 路由器无 SFTP 时 scp 常失败；用 ssh 把本地文件内容 stdin 写入远端（BusyBox 可用）
function Send-FileViaSshStdin {
	param(
		[string] $RemoteSpec,
		[string] $LocalPath,
		[string] $RemotePath
	)
	$cmd = "cat > " + $RemotePath
	# -T：避免为管道分配伪终端，远端 BusyBox cat 更稳定
	$p = Start-Process -FilePath "ssh" -ArgumentList @("-T", $RemoteSpec, $cmd) -RedirectStandardInput $LocalPath -NoNewWindow -Wait -PassThru
	if ($p.ExitCode -ne 0) {
		throw "ssh stdin upload failed for $RemotePath (exit $($p.ExitCode))."
	}
}

function Send-OneFile {
	param(
		[string] $RemoteSpec,
		[string] $LocalPath,
		[string] $RemotePath
	)
	$tmp = New-TempLfUtf8 -SourcePath $LocalPath
	try {
		& scp -O $tmp "${RemoteSpec}:${RemotePath}" 2>$null
		if ($LASTEXITCODE -eq 0) { return }
		& scp $tmp "${RemoteSpec}:${RemotePath}" 2>$null
		if ($LASTEXITCODE -eq 0) { return }
		Write-Host "    scp failed (exit $LASTEXITCODE), fallback: ssh + stdin -> $RemotePath"
		Send-FileViaSshStdin -RemoteSpec $RemoteSpec -LocalPath $tmp -RemotePath $RemotePath
	}
	finally {
		Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
	}
}

Write-Host "==> Stop uhttpd; remove TV-Tools files, UCI stub, LuCI caches..."
$one = @'
/etc/init.d/uhttpd stop 2>/dev/null || true
rm -f /usr/lib/lua/luci/controller/tv_tools.lua
rm -rf /usr/lib/lua/luci/view/tv_tools
rm -rf /www/luci-static/tv-tools
rm -rf /tmp/luci-modulecache /tmp/luci-sessions 2>/dev/null || true
rm -f /tmp/luci-indexcache 2>/dev/null || true
mkdir -p /usr/lib/lua/luci/view/tv_tools /www/luci-static/tv-tools/caps /usr/bin /usr/share/tv-tools
'@
$one = $one -replace "`r`n", "`n"

ssh $Remote $one

Write-Host "==> Upload (scp -O / scp / ssh+stdin, UTF-8 no BOM, LF)..."
foreach ($f in $Files) {
	Write-Host "    -> $($f.Remote)"
	Send-OneFile -RemoteSpec $Remote -LocalPath $f.Local -RemotePath $f.Remote
}

if (Test-Path $ConfigDefault) {
	Write-Host '==> UCI tv_tools: upload default only if /etc/config/tv_tools missing...'
	$hasCfg = ssh $Remote "test -f /etc/config/tv_tools && echo yes || echo no"
	if ($hasCfg -match "no") {
		Send-OneFile -RemoteSpec $Remote -LocalPath $ConfigDefault -RemotePath "/etc/config/tv_tools"
	}
	else {
		Write-Host '    skip: /etc/config/tv_tools already exists'
	}
}

Write-Host "==> chmod tv-tools adb scripts + share templates..."
ssh $Remote "chmod 644 /usr/share/tv-tools/vgeo-universal-overlay.yaml /usr/share/tv-tools/openclash-default-overwrite.sh 2>/dev/null; chmod 755 /usr/bin/tv-tools-adb-key.sh /usr/bin/tv-tools-adb-text.sh /usr/bin/tv-tools-adb-text-inner.sh /usr/bin/tv-tools-adb-screencap.sh /usr/bin/tv-tools-adb-pkg-list.sh /usr/bin/tv-tools-adb-pkg-list-inner.sh /usr/bin/tv-tools-adb-install.sh /usr/bin/tv-tools-adb-uninstall.sh /usr/bin/tv-tools-adb-app-refresh.sh 2>/dev/null; true"

Write-Host "==> Start uhttpd..."
ssh $Remote "/etc/init.d/uhttpd start; echo OK"

Write-Host ('Done. http://' + $RouterIp + '/cgi-bin/luci/admin/services/tv-tools')
