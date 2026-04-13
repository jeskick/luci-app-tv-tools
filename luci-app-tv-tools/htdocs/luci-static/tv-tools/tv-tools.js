/**
 * TV-Tools — 标签切换与日志（前端模块化入口，后续可拆分为多文件由构建合并）
 */
(function () {
	"use strict";

	var tvAppsTabEnter = null;
	var tvSyshellEnter = null;
	var tvOpenclashTabEnter = null;

	function logLine(msg) {
		var el = document.getElementById("tv-tools-log");
		if (!el) return;
		var d = new Date();
		function z(n) {
			return n < 10 ? "0" + n : String(n);
		}
		var t = z(d.getHours()) + ":" + z(d.getMinutes()) + ":" + z(d.getSeconds());
		el.textContent += "[" + t + "] " + msg + "\n";
		el.scrollTop = el.scrollHeight;
	}

	/** 结构化日志（后续功能复用）；过长自动截断 */
	function logDetail(label, obj, maxLen) {
		maxLen = maxLen || 2400;
		var s;
		try {
			s = obj === undefined ? "(undefined)" : JSON.stringify(obj);
		} catch (e) {
			s = String(obj);
		}
		if (s.length > maxLen) {
			s = s.slice(0, maxLen) + "…(截断 " + (s.length - maxLen) + "+ 字符)";
		}
		logLine(label + ": " + s);
	}

	function logHttpMeta(prefix, r, ms) {
		var st = r ? r.status + " " + (r.statusText || "") : "?";
		logLine(prefix + ": HTTP " + st + (ms != null ? " | 耗时 " + ms + "ms" : ""));
	}

	/** 单图预览：不传 slot，由服务端选「当天最新或最后一次」 */
	function captureUrlViewer(capBase, v) {
		if (!capBase) return "";
		var tok = getLuciToken();
		var sep = capBase.indexOf("?") >= 0 ? "&" : "?";
		return (
			capBase +
			sep +
			"v=" +
			encodeURIComponent(String(v != null ? v : Date.now())) +
			(tok ? "&token=" + encodeURIComponent(tok) : "")
		);
	}

	function trySaveCapToDevice(capBase) {
		if (!capBase) return;
		var url = captureUrlViewer(capBase, Date.now());
		fetch(url, { credentials: "same-origin" })
			.then(function (r) {
				if (!r.ok) throw new Error("HTTP " + r.status);
				return r.blob();
			})
			.then(function (blob) {
				var name = "tv-screenshot.png";
				var file = null;
				try {
					file = new File([blob], name, { type: "image/png" });
				} catch (e) {
					file = null;
				}
				if (file && navigator.share && typeof navigator.canShare === "function") {
					try {
						if (navigator.canShare({ files: [file] })) {
							return navigator.share({ files: [file] });
						}
					} catch (e2) {
						/* 回退下载 */
					}
				}
				var a = document.createElement("a");
				var objUrl = URL.createObjectURL(blob);
				a.href = objUrl;
				a.download = "tv-screenshot-" + Date.now() + ".png";
				document.body.appendChild(a);
				a.click();
				a.remove();
				setTimeout(function () {
					URL.revokeObjectURL(objUrl);
				}, 2500);
			})
			.catch(function (e) {
				logLine("屏幕快照: 保存失败 | " + (e && e.message ? e.message : e));
			});
	}

	function initSyshell(root) {
		var bannerUrl = root.getAttribute("data-syshell-banner-url") || "";
		var execUrl = root.getAttribute("data-syshell-exec-url") || "";
		var screen = document.getElementById("tv-syshell-screen");
		var inp = document.getElementById("tv-syshell-cmd");
		var promptEl = document.getElementById("tv-syshell-prompt");
		if (!screen || !inp || !promptEl || !execUrl) return;

		var sidKey = "tvt_syshell_sid_v1";
		var sid = localStorage.getItem(sidKey);
		if (!sid || !/^[a-fA-F0-9]{16,64}$/.test(sid)) {
			sid = "";
			if (window.crypto && crypto.getRandomValues) {
				var arr = new Uint8Array(16);
				crypto.getRandomValues(arr);
				for (var ri = 0; ri < arr.length; ri++) {
					var hx = arr[ri].toString(16);
					sid += hx.length < 2 ? "0" + hx : hx;
				}
			} else {
				for (var rj = 0; rj < 16; rj++) sid += ((Math.random() * 16) | 0).toString(16);
			}
			localStorage.setItem(sidKey, sid);
		}

		var host = "OpenWrt";
		var cwd = "/root";
		var bannerDone = false;
		var firstEnter = true;

		function setPrompt() {
			var c = cwd;
			if (c.length > 36) c = "…" + c.slice(-32);
			promptEl.textContent = "root@" + host + ":" + c + "# ";
		}

		function appendText(t) {
			if (t) screen.appendChild(document.createTextNode(t));
			screen.scrollTop = screen.scrollHeight;
		}

		function loadBanner(cb) {
			if (bannerDone) {
				if (cb) cb();
				return;
			}
			if (!bannerUrl) {
				bannerDone = true;
				if (cb) cb();
				return;
			}
			var tok = getLuciToken();
			var sep = bannerUrl.indexOf("?") >= 0 ? "&" : "?";
			var u = bannerUrl + sep + "token=" + encodeURIComponent(tok || "");
			fetch(u, { credentials: "same-origin" })
				.then(function (r) {
					return r.text().then(function (text) {
						var j;
						try {
							j = JSON.parse(text);
						} catch (e) {
							j = null;
						}
						if (j && j.ok) {
							if (j.host) host = String(j.host);
							if (j.banner) {
								appendText(String(j.banner));
								if (!/\n$/.test(j.banner)) appendText("\n");
							}
						}
						bannerDone = true;
						setPrompt();
						if (cb) cb();
					});
				})
				.catch(function () {
					bannerDone = true;
					setPrompt();
					if (cb) cb();
				});
		}

		function runLine(line) {
			var raw = line.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
			if (!raw.trim()) return;
			var trimmed = raw.trim();
			if (/^clear\s*$/i.test(trimmed)) {
				screen.textContent = "";
				setPrompt();
				inp.focus();
				return;
			}
			appendText(promptEl.textContent + raw + "\n");
			var body =
				"cmd=" + encodeURIComponent(raw) + "&sid=" + encodeURIComponent(sid);
			var tok2 = getLuciToken();
			if (tok2) body += "&token=" + encodeURIComponent(tok2);
			fetch(execUrl, {
				method: "POST",
				credentials: "same-origin",
				headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
				body: body,
			})
				.then(function (r) {
					return r.text().then(function (text) {
						var j;
						try {
							j = JSON.parse(text);
						} catch (e) {
							appendText("（响应非 JSON）\n");
							return;
						}
						if (j && j.ok) {
							if (j.out) appendText(j.out + (/\n$/.test(j.out) ? "" : "\n"));
							if (j.cwd) cwd = String(j.cwd);
						} else {
							appendText((j && j.err ? j.err : "执行失败") + "\n");
						}
						setPrompt();
					});
				})
				.catch(function (e) {
					appendText("请求失败: " + (e && e.message ? e.message : e) + "\n");
					setPrompt();
				})
				.finally(function () {
					screen.scrollTop = screen.scrollHeight;
					inp.focus();
				});
		}

		inp.addEventListener("keydown", function (ev) {
			if (ev.key === "Enter" && !ev.shiftKey) {
				ev.preventDefault();
				var line = inp.value;
				inp.value = "";
				runLine(line);
			}
		});

		setPrompt();

		tvSyshellEnter = function () {
			if (firstEnter) {
				firstEnter = false;
				screen.textContent = "";
				loadBanner(function () {
					inp.focus();
				});
			} else {
				loadBanner();
				inp.focus();
			}
		};
	}

	function initTabs(root) {
		var tabs = root.querySelectorAll(".tv-tools__tab");
		var panels = root.querySelectorAll(".tv-tools__panel");

		function activate(name) {
			tabs.forEach(function (btn) {
				var on = btn.getAttribute("data-tab") === name;
				btn.classList.toggle("is-active", on);
				btn.setAttribute("aria-selected", on ? "true" : "false");
			});
			panels.forEach(function (p) {
				var on = p.getAttribute("data-panel") === name;
				if (on) {
					p.removeAttribute("hidden");
					p.classList.add("is-visible");
				} else {
					p.setAttribute("hidden", "");
					p.classList.remove("is-visible");
				}
			});
		}

		var currentTab = "home-tv";
		var capBusy = false;
		var capCfgUrl = root.getAttribute("data-screencap-cfg-url") || "";
		var capAutoEl = document.getElementById("tv-cap-auto");
		var capIntervalEl = document.getElementById("tv-cap-interval");
		var capSaveEl = document.getElementById("tv-cap-save");
		var capTimer = null;
		var capPanelActive = false;
		var capAutoOn = root.getAttribute("data-cap-auto-refresh") !== "0";
		var capIntervalMs = parseInt(root.getAttribute("data-cap-interval-ms") || "2000", 10);
		if (!isFinite(capIntervalMs)) capIntervalMs = 2000;
		if (capIntervalMs < 1000) capIntervalMs = 1000;
		if (capIntervalMs > 10000) capIntervalMs = 10000;

		function capTimerStop() {
			if (capTimer) {
				clearInterval(capTimer);
				capTimer = null;
			}
		}

		function capTimerStart() {
			capTimerStop();
			if (!capPanelActive || !capAutoOn) return;
			capTimer = setInterval(function () {
				if (!capPanelActive || !capAutoOn || document.hidden) return;
				runScreencap("自动刷新");
			}, capIntervalMs);
		}

		function capCfgSyncUi() {
			if (capAutoEl) capAutoEl.checked = !!capAutoOn;
			if (capIntervalEl) capIntervalEl.value = String(capIntervalMs);
		}

		function capCfgSave() {
			if (!capCfgUrl) return Promise.resolve();
			var tok = getLuciToken();
			var body =
				"auto=" +
				encodeURIComponent(capAutoOn ? "1" : "0") +
				"&interval_ms=" +
				encodeURIComponent(String(capIntervalMs));
			if (tok) body += "&token=" + encodeURIComponent(tok);
			return fetch(capCfgUrl, {
				method: "POST",
				credentials: "same-origin",
				headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
				body: body,
			})
				.then(function (r) {
					return r.text().then(function (text) {
						var j;
						try {
							j = JSON.parse(text);
						} catch (e) {
							j = { ok: false, err: "非 JSON", raw: text };
						}
						return j;
					});
				})
				.then(function (j) {
					if (j && j.ok) {
						capAutoOn = String(j.auto || "0") === "1";
						capIntervalMs = parseInt(j.interval_ms || capIntervalMs, 10) || capIntervalMs;
						if (capIntervalMs < 1000) capIntervalMs = 1000;
						if (capIntervalMs > 10000) capIntervalMs = 10000;
						capCfgSyncUi();
						capTimerStart();
						logLine("屏幕快照: 已保存自动刷新配置");
					} else {
						logLine("屏幕快照: 保存配置失败 — " + (j && j.err ? j.err : "?"));
					}
				})
				.catch(function (e) {
					logLine("屏幕快照: 保存配置异常 | " + (e && e.message ? e.message : e));
				});
		}

		function refreshCapView(capBase) {
			var img = document.getElementById("tv-cap-img");
			if (!img || !capBase) return;
			img.src = captureUrlViewer(capBase, Date.now());
		}

		function runScreencap(reason) {
			var scUrl = root.getAttribute("data-screencap-url") || "";
			var capBase = root.getAttribute("data-capture-url") || "";
			if (!scUrl) {
				logLine("屏幕快照: 未配置 data-screencap-url");
				return;
			}
			if (capBusy) {
				logLine("屏幕快照: 进行中，跳过 (" + reason + ")");
				return;
			}
			capBusy = true;

			var tok = getLuciToken();
			var body = tok ? "token=" + encodeURIComponent(tok) : "";
			var t0 = Date.now();
			logLine("屏幕快照: " + reason + " | POST " + scUrl);

			fetch(scUrl, {
				method: "POST",
				credentials: "same-origin",
				headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
				body: body,
			})
				.then(function (r) {
					var ms = Date.now() - t0;
					logHttpMeta("屏幕快照", r, ms);
					return r.text().then(function (text) {
						var j;
						try {
							j = JSON.parse(text);
						} catch (e) {
							return { ok: false, err: "非 JSON", _raw: text };
						}
						return j;
					});
				})
				.then(function (j) {
					logDetail("屏幕快照: 响应", j);
					if (j && j.ok) {
						logLine("屏幕快照: 成功 seq=" + (j.seq != null ? j.seq : "?") + " slot=" + (j.slot != null ? j.slot : "?"));
					} else {
						logLine("屏幕快照: 失败 — " + (j && j.err ? j.err : "?"));
					}
					refreshCapView(capBase);
				})
				.catch(function (e) {
					logLine("屏幕快照: 异常 | " + (e && e.message ? e.message : e));
					refreshCapView(capBase);
				})
				.finally(function () {
					capBusy = false;
				});
		}

		capCfgSyncUi();
		if (capAutoEl) {
			capAutoEl.addEventListener("change", function () {
				capAutoOn = !!capAutoEl.checked;
				capTimerStart();
			});
		}
		if (capIntervalEl) {
			capIntervalEl.addEventListener("change", function () {
				var v = parseInt(capIntervalEl.value || "2000", 10);
				if (!isFinite(v)) v = 2000;
				if (v < 1000) v = 1000;
				if (v > 10000) v = 10000;
				capIntervalMs = v;
				capTimerStart();
			});
		}
		if (capSaveEl) {
			capSaveEl.addEventListener("click", function () {
				capCfgSave();
			});
		}
		document.addEventListener("visibilitychange", function () {
			if (document.hidden) {
				capTimerStop();
			} else {
				capTimerStart();
			}
		});

		var capImg = document.getElementById("tv-cap-img");
		if (capImg) {
			capImg.addEventListener("error", function () {
				this.classList.add("tv-cap__img--empty");
			});
			capImg.addEventListener("load", function () {
				this.classList.remove("tv-cap__img--empty");
			});
			(function bindCapLongPress() {
				var img = capImg;
				var holdMs = 550;
				var timer = null;
				var sx = 0;
				var sy = 0;
				function clearT() {
					if (timer) {
						clearTimeout(timer);
						timer = null;
					}
				}
				img.addEventListener("pointerdown", function (ev) {
					clearT();
					if (ev.button != null && ev.button !== 0) return;
					sx = ev.clientX;
					sy = ev.clientY;
					timer = setTimeout(function () {
						timer = null;
						trySaveCapToDevice(root.getAttribute("data-capture-url") || "");
					}, holdMs);
				});
				img.addEventListener("pointermove", function (ev) {
					if (!timer) return;
					if (Math.abs(ev.clientX - sx) > 16 || Math.abs(ev.clientY - sy) > 16) clearT();
				});
				img.addEventListener("pointerup", clearT);
				img.addEventListener("pointercancel", clearT);
				img.addEventListener("lostpointercapture", clearT);
			})();
		}

		var nav = root.querySelector(".tv-tools__tabs");
		if (nav) {
			nav.addEventListener("click", function (ev) {
				var t = ev.target;
				var btn = t.closest ? t.closest(".tv-tools__tab") : null;
				if (!btn || !nav.contains(btn)) return;
				var name = btn.getAttribute("data-tab");
				if (!name) return;
				var prevTab = currentTab;
				activate(name);
				currentTab = name;
				logLine("切换标签: " + name);
				if (name === "syshell") {
					root.classList.add("tv-tools--shell-focus");
					if (tvSyshellEnter) tvSyshellEnter();
				} else {
					root.classList.remove("tv-tools--shell-focus");
				}
				if (name === "screenshot") {
					capPanelActive = true;
					runScreencap(prevTab === "screenshot" ? "再次点击标签刷新" : "进入标签自动截图");
					capTimerStart();
				} else if (prevTab === "screenshot") {
					capPanelActive = false;
					capTimerStop();
				}
				if (name === "apps" && tvAppsTabEnter) {
					tvAppsTabEnter();
				}
				if (name === "openclash-tools" && tvOpenclashTabEnter) {
					tvOpenclashTabEnter();
				}
			});
		}

		activate("home-tv");
	}

	function initLogClear() {
		var btn = document.getElementById("tv-tools-log-clear");
		var el = document.getElementById("tv-tools-log");
		if (btn && el) {
			btn.addEventListener("click", function () {
				el.textContent = "";
				logLine("日志已清空");
			});
		}
	}

	function getLuciToken() {
		var el = document.querySelector('input[name="token"]');
		return el && el.value ? el.value : "";
	}

	function initRemoteKeys(root) {
		var box = root.querySelector("#tv-remote-keys");
		if (!box) return;
		var adbUrl = root.getAttribute("data-adb-url") || "";
		box.addEventListener("click", function (ev) {
			var b = ev.target.closest(".tv-remote__btn");
			if (!b || !box.contains(b)) return;
			var k = b.getAttribute("data-key") || "";
			var label = (b.textContent || "").replace(/\s+/g, " ").trim();
			if (!adbUrl) {
				logLine("遥控: 未配置 data-adb-url");
				return;
			}
			var body = "key=" + encodeURIComponent(k);
			var tok = getLuciToken();
			if (tok) body += "&token=" + encodeURIComponent(tok);
			var t0 = Date.now();
			logLine("遥控: 请求开始 | key=" + k + (label ? " | 按钮=" + label : "") + " | POST " + adbUrl);
			fetch(adbUrl, {
				method: "POST",
				credentials: "same-origin",
				headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
				body: body,
			})
				.then(function (r) {
					var ms = Date.now() - t0;
					logHttpMeta("遥控", r, ms);
					return r.text().then(function (text) {
						var j;
						try {
							j = JSON.parse(text);
						} catch (e) {
							j = { ok: false, parseErr: true, raw: text };
						}
						return { j: j, httpOk: r.ok };
					});
				})
				.then(function (x) {
					var j = x.j;
					if (j && !j.parseErr) {
						logDetail("遥控: 响应 JSON", { ok: j.ok, out: j.out, err: j.err });
					} else {
						logLine("遥控: 响应非 JSON，原文前 500 字: " + String(j.raw || "").slice(0, 500));
					}
					if (j && j.ok) logLine("遥控: 业务成功 key=" + k);
					else logLine("遥控: 业务失败 key=" + k);
				})
				.catch(function (e) {
					logLine("遥控: 网络/异常 | " + (e && e.message ? e.message : String(e)));
				});
		});
	}

	function esc(s) {
		var d = document.createElement("div");
		d.textContent = s == null ? "" : String(s);
		return d.innerHTML;
	}

	function escAttr(s) {
		return String(s == null ? "" : s)
			.replace(/&/g, "&amp;")
			.replace(/"/g, "&quot;")
			.replace(/</g, "&lt;");
	}

	function copyToClipboard(text) {
		if (!text) return;
		if (navigator.clipboard && navigator.clipboard.writeText) {
			navigator.clipboard.writeText(text).then(
				function () {
					logLine("已复制: " + (text.length > 96 ? text.slice(0, 96) + "…" : text));
				},
				function () {
					logLine("复制失败");
				}
			);
			return;
		}
		var ta = document.createElement("textarea");
		ta.value = text;
		ta.setAttribute("readonly", "");
		ta.style.position = "fixed";
		ta.style.left = "-9999px";
		document.body.appendChild(ta);
		ta.select();
		try {
			document.execCommand("copy");
			logLine("已复制");
		} catch (e) {
			logLine("复制失败");
		}
		document.body.removeChild(ta);
	}

	function initAppsPanel(root) {
		var listUrl = root.getAttribute("data-apps-list-url") || "";
		var uninstallUrl = root.getAttribute("data-apps-uninstall-url") || "";
		var refreshAppUrl = root.getAttribute("data-apps-refresh-url") || "";
		var installUrl = root.getAttribute("data-apps-install-url") || "";
		var tbody = document.getElementById("tv-apps-tbody");
		var refreshBtn = document.getElementById("tv-apps-refresh");
		var userSelectEl = document.getElementById("tv-apps-user-select");
		var appRefreshBtn = document.getElementById("tv-apps-cache-restart");
		var installBtn = document.getElementById("tv-apps-install");
		var fileInput = document.getElementById("tv-apps-apk");
		var filterBtns = root.querySelectorAll(".tv-apps__filter");
		var filterUserBtn = document.getElementById("tv-apps-filter-user");
		var filterSysBtn = document.getElementById("tv-apps-filter-system");
		var searchEl = document.getElementById("tv-apps-search");
		var appsTable = document.getElementById("tv-apps-table");
		if (!tbody || !listUrl) return;

		function setAppsFilterCounts(nUser, nSys) {
			var nu = typeof nUser === "number" && nUser >= 0 ? nUser : 0;
			var ns = typeof nSys === "number" && nSys >= 0 ? nSys : 0;
			var lu = filterUserBtn && filterUserBtn.getAttribute("data-apps-filter-label");
			var ls = filterSysBtn && filterSysBtn.getAttribute("data-apps-filter-label");
			if (filterUserBtn) filterUserBtn.textContent = (lu || "用户应用") + "[" + nu + "]";
			if (filterSysBtn) filterSysBtn.textContent = (ls || "系统应用") + "[" + ns + "]";
		}

		var currentScope = "user";
		var appsFirstEnter = true;
		var appsCache = [];
		var fullApps = { user: [], system: [] };
		var appRefreshBusy = false;

		function syncUserSelect() {
			if (!userSelectEl) return;
			var prev = userSelectEl.value || "";
			var rows = fullApps.user || [];
			if (!rows.length) {
				userSelectEl.innerHTML = '<option value="">（暂无用户应用）</option>';
				userSelectEl.value = "";
				if (appRefreshBtn) appRefreshBtn.disabled = true;
				return;
			}
			var html = [];
			for (var i = 0; i < rows.length; i++) {
				var pkg = rows[i] && rows[i].package ? rows[i].package : "";
				if (!pkg) continue;
				html.push(
					'<option value="' + escAttr(pkg) + '">' + esc(pkg) + "</option>"
				);
			}
			userSelectEl.innerHTML = html.join("");
			if (prev) {
				for (var pi = 0; pi < userSelectEl.options.length; pi++) {
					if (userSelectEl.options[pi].value === prev) {
						userSelectEl.value = prev;
						break;
					}
				}
			}
			if (!userSelectEl.value && userSelectEl.options.length > 0) {
				userSelectEl.selectedIndex = 0;
			}
			if (appRefreshBtn) appRefreshBtn.disabled = userSelectEl.options.length === 0;
		}

		function syncCacheFromScope() {
			appsCache = currentScope === "system" ? fullApps.system : fullApps.user;
		}

		function updateAppsTableScopeClass() {
			if (!appsTable) return;
			appsTable.classList.toggle("tv-apps__table--scope-user", currentScope === "user");
			appsTable.classList.toggle("tv-apps__table--scope-system", currentScope === "system");
		}

		function renderRows(apps) {
			if (!apps || !apps.length) {
				return;
			}
			var html = [];
			for (var i = 0; i < apps.length; i++) {
				var a = apps[i];
				var pkg = a.package || "";
				var note = a.note != null ? String(a.note) : "—";
				var path = a.path || "";
				var actHtml;
				if (a.removable) {
					actHtml =
						'<button type="button" class="tv-tools__btn tv-apps__uninstall" data-kind="user" data-pkg="' +
						escAttr(pkg) +
						'">卸载</button>';
				} else if (a.uninstallUpdatePossible) {
					actHtml =
						'<button type="button" class="tv-tools__btn tv-apps__uninstall tv-apps__uninstall--update" data-kind="sys_update" data-pkg="' +
						escAttr(pkg) +
						'">卸载更新</button>';
				} else {
					actHtml = '<span class="tv-apps__act-none">—</span>';
				}
				html.push(
					'<tr class="tv-apps__tr">' +
						'<td class="tv-apps__pkg tv-apps__copy" data-copy="' +
						escAttr(pkg) +
						'" title="点击复制包名">' +
						esc(pkg) +
						"</td>" +
						'<td class="tv-apps__note tv-apps__ellip tv-apps__copy" data-copy="' +
						escAttr(note) +
						'" title="点击复制说明">' +
						esc(note) +
						"</td>" +
						'<td class="tv-apps__path tv-apps__copy tv-apps__ellip" data-copy="' +
						escAttr(path) +
						'" title="点击复制完整路径">' +
						esc(path) +
						"</td>" +
						'<td class="tv-apps__act">' +
						actHtml +
						"</td></tr>"
				);
			}
			tbody.innerHTML = html.join("");
		}

		/** 模糊匹配：关键词去空白后按「子序列」匹配整行（字符依次出现即可，不必连续） */
		function rowMatchesFuzzy(a, rawQ) {
			var q = (rawQ || "").trim().toLowerCase().replace(/\s+/g, "");
			if (!q) return true;
			var hay = (
				(a.package || "") +
				" " +
				String(a.note == null ? "" : a.note) +
				" " +
				(a.path || "")
			)
				.toLowerCase()
				.replace(/\s+/g, "");
			var hi = 0;
			for (var qi = 0; qi < q.length; qi++) {
				var c = q.charAt(qi);
				hi = hay.indexOf(c, hi);
				if (hi === -1) return false;
				hi++;
			}
			return true;
		}

		function applyListFilter() {
			var qRaw = searchEl && searchEl.value ? searchEl.value : "";
			var src = appsCache;
			var filtered = src;
			if (qRaw.trim()) {
				filtered = src.filter(function (a) {
					return rowMatchesFuzzy(a, qRaw);
				});
			}
			if (!filtered.length) {
				if (src.length) {
					tbody.innerHTML =
						'<tr><td colspan="4" class="tv-apps__empty">无匹配项（可清空搜索或换关键词）</td></tr>';
				} else {
					tbody.innerHTML =
						'<tr><td colspan="4" class="tv-apps__empty">暂无数据（或未连接 / 列表为空）</td></tr>';
				}
				return;
			}
			renderRows(filtered);
		}

		function fetchAppsList(reason) {
			var tok = getLuciToken();
			var body = tok ? "token=" + encodeURIComponent(tok) : "";
			fullApps = { user: [], system: [] };
			appsCache = [];
			setAppsFilterCounts(0, 0);
			tbody.innerHTML = '<tr><td colspan="4" class="tv-apps__loading">加载中…</td></tr>';
			var t0 = Date.now();
			logLine("应用列表: " + (reason || "请求") + " | 拉取 user+system");
			fetch(listUrl, {
				method: "POST",
				credentials: "same-origin",
				headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
				body: body,
			})
				.then(function (r) {
					logHttpMeta("应用列表", r, Date.now() - t0);
					return r.text().then(function (text) {
						var j;
						try {
							j = JSON.parse(text);
						} catch (e) {
							return { ok: false, err: "非 JSON", _raw: text };
						}
						return j;
					});
				})
				.then(function (j) {
					if (j && j.ok) {
						fullApps.user = j.user || [];
						fullApps.system = j.system || [];
						var nu = fullApps.user.length;
						var ns = fullApps.system.length;
						setAppsFilterCounts(nu, ns);
						syncUserSelect();
						logLine("应用列表: 用户 " + nu + " 条 · 系统 " + ns + " 条");
						syncCacheFromScope();
						updateAppsTableScopeClass();
						applyListFilter();
					} else {
						fullApps = { user: [], system: [] };
						appsCache = [];
						setAppsFilterCounts(0, 0);
						syncUserSelect();
						logLine("应用列表: 失败 — " + (j && j.err ? j.err : "?"));
						tbody.innerHTML =
							'<tr><td colspan="4" class="tv-apps__err">' +
							esc(j && j.err ? j.err : "加载失败") +
							"</td></tr>";
					}
				})
				.catch(function (e) {
					fullApps = { user: [], system: [] };
					appsCache = [];
					setAppsFilterCounts(0, 0);
					syncUserSelect();
					logLine("应用列表: 异常 | " + (e && e.message ? e.message : e));
					tbody.innerHTML =
						'<tr><td colspan="4" class="tv-apps__err">请求异常</td></tr>';
				});
		}

		tvAppsTabEnter = function () {
			if (appsFirstEnter) {
				appsFirstEnter = false;
				fetchAppsList("进入应用管理");
			}
		};

		if (refreshBtn) {
			refreshBtn.addEventListener("click", function () {
				fetchAppsList("刷新");
			});
		}

		filterBtns.forEach(function (b) {
			b.addEventListener("click", function () {
				var sc = b.getAttribute("data-apps-scope") || "user";
				currentScope = sc;
				filterBtns.forEach(function (x) {
					x.classList.toggle("is-active", x === b);
				});
				if (searchEl) searchEl.value = "";
				syncCacheFromScope();
				updateAppsTableScopeClass();
				applyListFilter();
				logLine("应用列表: 切换视图 | " + (sc === "system" ? "系统应用" : "用户应用"));
			});
		});

		if (searchEl) {
			searchEl.addEventListener("input", function () {
				applyListFilter();
			});
		}

		function copyFromAppsCell(copyEl) {
			if (!copyEl || !tbody.contains(copyEl)) return;
			var c = copyEl.getAttribute("data-copy");
			if (c) copyToClipboard(c);
		}

		tbody.addEventListener("click", function (ev) {
			if (ev.target.closest && ev.target.closest(".tv-apps__uninstall")) return;
			var copyEl = ev.target.closest ? ev.target.closest(".tv-apps__copy") : null;
			copyFromAppsCell(copyEl);
		});

		/* 手机端：touchend 轻点复制（带位移阈值，避免与滚动冲突）；preventDefault 减少与 click 重复 */
		var appsCopyTouch = { x: 0, y: 0 };
		tbody.addEventListener(
			"touchstart",
			function (ev) {
				if (!ev.touches || !ev.touches[0]) return;
				appsCopyTouch.x = ev.touches[0].clientX;
				appsCopyTouch.y = ev.touches[0].clientY;
			},
			{ passive: true }
		);
		tbody.addEventListener(
			"touchend",
			function (ev) {
				if (ev.target.closest && ev.target.closest(".tv-apps__uninstall")) return;
				var copyEl = ev.target.closest ? ev.target.closest(".tv-apps__copy") : null;
				if (!copyEl || !tbody.contains(copyEl)) return;
				if (!ev.changedTouches || !ev.changedTouches[0]) return;
				var x = ev.changedTouches[0].clientX;
				var y = ev.changedTouches[0].clientY;
				if (Math.abs(x - appsCopyTouch.x) > 14 || Math.abs(y - appsCopyTouch.y) > 14) return;
				ev.preventDefault();
				copyFromAppsCell(copyEl);
			},
			{ passive: false }
		);

		tbody.addEventListener("click", function (ev) {
			var ub = ev.target.closest(".tv-apps__uninstall");
			if (!ub || !tbody.contains(ub)) return;
			var pkg = ub.getAttribute("data-pkg") || "";
			var kind = ub.getAttribute("data-kind") || "user";
			if (!pkg || !uninstallUrl) return;
			var msg =
				kind === "sys_update"
					? "确定卸载该应用的「系统更新包」？将尽量恢复为 ROM 内置版本（与系统设置中卸载更新类似）。\n包名：" + pkg
					: "确定卸载用户应用「" + pkg + "」？";
			if (!confirm(msg)) return;
			var tok = getLuciToken();
			var body =
				"package=" + encodeURIComponent(pkg) + "&kind=" + encodeURIComponent(kind);
			if (tok) body += "&token=" + encodeURIComponent(tok);
			logLine("卸载: POST | package=" + pkg + " | kind=" + kind);
			fetch(uninstallUrl, {
				method: "POST",
				credentials: "same-origin",
				headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
				body: body,
			})
				.then(function (r) {
					return r.text().then(function (text) {
						var j;
						try {
							j = JSON.parse(text);
						} catch (e) {
							j = { ok: false, out: text };
						}
						return j;
					});
				})
				.then(function (j) {
					if (j && j.ok) logLine("卸载成功: " + pkg);
					else
						logLine(
							"卸载失败: " +
								pkg +
								" | " +
								(j && j.out ? String(j.out).slice(0, 400) : j && j.err ? j.err : "")
						);
					fetchAppsList("卸载后刷新");
				})
				.catch(function (e) {
					logLine("卸载: 异常 | " + (e && e.message ? e.message : e));
				});
		});

		var installBusy = false;
		if (installBtn && fileInput && installUrl) {
			installBtn.addEventListener("click", function () {
				if (installBusy) return;
				var f = fileInput.files && fileInput.files[0];
				if (!f) {
					logLine("安装: 请先选择 APK 文件");
					return;
				}
				if (!/\.apk$/i.test(f.name || "")) {
					logLine("安装: 请选择 .apk 文件");
					return;
				}
				installBusy = true;
				var fd = new FormData();
				var tok2 = getLuciToken();
				if (tok2) fd.append("token", tok2);
				fd.append("apk", f, f.name || "upload.apk");
				logLine("安装: 上传并安装… | " + (f.name || "apk"));
				fetch(installUrl, { method: "POST", credentials: "same-origin", body: fd })
					.then(function (r) {
						return r.text().then(function (text) {
							var j;
							try {
								j = JSON.parse(text);
							} catch (e) {
								j = { ok: false, out: text };
							}
							return j;
						});
					})
					.then(function (j) {
						if (j && j.ok) logLine("安装: 成功");
						else
							logLine(
								"安装: 失败 | " +
									(j && j.out ? String(j.out).slice(0, 600) : j && j.err ? j.err : "")
							);
						fileInput.value = "";
						fetchAppsList("安装后刷新");
					})
					.catch(function (e) {
						logLine("安装: 异常 | " + (e && e.message ? e.message : e));
					})
					.finally(function () {
						installBusy = false;
					});
			});
		}

		if (appRefreshBtn && userSelectEl && refreshAppUrl) {
			appRefreshBtn.addEventListener("click", function () {
				if (appRefreshBusy) return;
				var pkg = userSelectEl.value || "";
				if (!pkg) {
					logLine("缓存/重启: 请先选择用户应用");
					return;
				}
				var tok = getLuciToken();
				var body = "package=" + encodeURIComponent(pkg);
				if (tok) body += "&token=" + encodeURIComponent(tok);
				appRefreshBusy = true;
				appRefreshBtn.disabled = true;
				logLine("缓存/重启: 开始 | " + pkg);
				fetch(refreshAppUrl, {
					method: "POST",
					credentials: "same-origin",
					headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
					body: body,
				})
					.then(function (r) {
						return r.text().then(function (text) {
							var j;
							try {
								j = JSON.parse(text);
							} catch (e) {
								j = { ok: false, out: text };
							}
							return j;
						});
					})
					.then(function (j) {
						if (j && j.ok) {
							logLine("缓存/重启: 成功 | " + pkg);
						} else {
							logLine(
								"缓存/重启: 失败 | " +
									pkg +
									" | " +
									(j && j.out ? String(j.out).slice(0, 500) : j && j.err ? j.err : "")
							);
						}
					})
					.catch(function (e) {
						logLine("缓存/重启: 异常 | " + (e && e.message ? e.message : e));
					})
					.finally(function () {
						appRefreshBusy = false;
						appRefreshBtn.disabled = !userSelectEl.value;
					});
			});
		}
	}

	function initOpenclashTools(root) {
		var injectUrl = root.getAttribute("data-openclash-inject-url") || "";
		var scriptGetUrl = root.getAttribute("data-openclash-script-get-url") || "";
		var scriptSaveUrl = root.getAttribute("data-openclash-script-save-url") || "";
		var btnInject = document.getElementById("tv-oc-inject");
		var btnSaveScript = document.getElementById("tv-oc-save-script");
		var editor = document.getElementById("tv-oc-script-editor");
		var editorHl = document.getElementById("tv-oc-script-editor-hl");
		var targetSel = document.getElementById("tv-oc-file-target");
		var chkRestart = document.getElementById("tv-oc-restart");
		if (!btnInject || !btnSaveScript || !editor || !editorHl || !targetSel) return;

		var busy = false;
		var loadedOnce = false;
		function syncOcEditorChrome() {
			var noSave = targetSel.value === "base_rules";
			btnSaveScript.disabled = busy || noSave;
			btnInject.disabled = busy;
			editor.disabled = busy;
			targetSel.disabled = busy;
			if (chkRestart) chkRestart.disabled = busy;
		}
		function setBusy(v) {
			busy = !!v;
			syncOcEditorChrome();
		}
		function targetLabel(v) {
			if (v === "openclash_default") return "openclash-default-overwrite.sh";
			if (v === "base_rules") return "VGEO 整份覆写";
			if (v === "vgeo_yaml") return "vgeo-universal-overlay.yaml";
			if (v === "runtime") return "openclash_custom_overwrite.sh（运行中）";
			return "openclash_custom_overwrite.sh";
		}
		function escHtml(s) {
			return String(s == null ? "" : s)
				.replace(/&/g, "&amp;")
				.replace(/</g, "&lt;")
				.replace(/>/g, "&gt;");
		}
		function highlightShell(text) {
			var lines = String(text || "").split("\n");
			var out = [];
			for (var i = 0; i < lines.length; i++) {
				var l = lines[i];
				var cidx = l.indexOf("#");
				var code = cidx >= 0 ? l.slice(0, cidx) : l;
				var cmt = cidx >= 0 ? l.slice(cidx) : "";
				var h = escHtml(code)
					.replace(/("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/g, '<span class="tv-oc__tok-str">$1</span>')
					.replace(/\b(if|then|else|elif|fi|for|in|do|done|case|esac|while|until|function|return|exit|local)\b/g, '<span class="tv-oc__tok-kw">$1</span>')
					.replace(/\b(\d+)\b/g, '<span class="tv-oc__tok-num">$1</span>');
				if (cmt) h += '<span class="tv-oc__tok-comment">' + escHtml(cmt) + "</span>";
				out.push(h);
			}
			return out.join("\n");
		}
		function highlightYaml(text) {
			var lines = String(text || "").split("\n");
			var out = [];
			for (var i = 0; i < lines.length; i++) {
				var l = lines[i];
				if (/^\s*#/.test(l)) {
					out.push('<span class="tv-oc__tok-comment">' + escHtml(l) + "</span>");
					continue;
				}
				var h = escHtml(l)
					.replace(/^(\s*[- ]*)([A-Za-z0-9_.-]+)(\s*:)/, '$1<span class="tv-oc__tok-key">$2</span>$3')
					.replace(/("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/g, '<span class="tv-oc__tok-str">$1</span>')
					.replace(/\b(true|false|null)\b/gi, '<span class="tv-oc__tok-kw">$1</span>')
					.replace(/\b(\d+)\b/g, '<span class="tv-oc__tok-num">$1</span>');
				out.push(h);
			}
			return out.join("\n");
		}
		function renderHighlight() {
			var txt = editor.value || "";
			var t = targetSel.value || "";
			var html;
			if (t === "openclash_default" || t === "base_rules" || t === "runtime") html = highlightShell(txt);
			else if (t === "vgeo_yaml") html = highlightYaml(txt);
			else html = highlightShell(txt);
			editorHl.innerHTML = html + "\n";
			editorHl.scrollTop = editor.scrollTop;
			editorHl.scrollLeft = editor.scrollLeft;
		}
		function postAction(url, actionLabel) {
			if (!url) {
				logLine(actionLabel + ": URL 未配置");
				return Promise.resolve();
			}
			if (busy) return Promise.resolve();
			setBusy(true);
			var tok = getLuciToken();
			var body = tok ? "token=" + encodeURIComponent(tok) : "";
			var t0 = Date.now();
			logLine("OpenClash-Tools: " + actionLabel + " 开始");
			return fetch(url, {
				method: "POST",
				credentials: "same-origin",
				headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
				body: body,
			})
				.then(function (r) {
					logHttpMeta("OpenClash-Tools " + actionLabel, r, Date.now() - t0);
					return r.text().then(function (text) {
						var j;
						try {
							j = JSON.parse(text);
						} catch (e) {
							j = { ok: false, err: "非 JSON", raw: text };
						}
						return j;
					});
				})
				.then(function (j) {
					logDetail("OpenClash-Tools " + actionLabel + " 响应", j);
					if (j && j.ok) {
						logLine("OpenClash-Tools: " + actionLabel + " 成功" + (j.msg ? " | " + j.msg : ""));
					} else {
						logLine("OpenClash-Tools: " + actionLabel + " 失败 — " + (j && j.err ? j.err : "?"));
					}
				})
				.catch(function (e) {
					logLine("OpenClash-Tools: " + actionLabel + " 异常 | " + (e && e.message ? e.message : e));
				})
				.finally(function () {
					setBusy(false);
				});
		}

		function loadScript(forceRuntime) {
			if (!scriptGetUrl) {
				logLine("OpenClash-Tools: 脚本读取 URL 未配置");
				return Promise.resolve();
			}
			if (busy) return Promise.resolve();
			setBusy(true);
			var tok = getLuciToken();
			var target = forceRuntime ? "" : targetSel.value || "";
			var q = target ? "target=" + encodeURIComponent(target) : "";
			if (tok) q += (q ? "&" : "") + "token=" + encodeURIComponent(tok);
			var sep = scriptGetUrl.indexOf("?") >= 0 ? "&" : "?";
			var url = q ? scriptGetUrl + sep + q : scriptGetUrl;
			var t0 = Date.now();
			logLine("OpenClash-Tools: 读取 " + targetLabel(target || "openclash_runtime"));
			return fetch(url, { method: "GET", credentials: "same-origin" })
				.then(function (r) {
					logHttpMeta("OpenClash-Tools 读取脚本", r, Date.now() - t0);
					return r.text().then(function (text) {
						var j;
						try {
							j = JSON.parse(text);
						} catch (e) {
							j = { ok: false, err: "非 JSON", raw: text };
						}
						return j;
					});
				})
				.then(function (j) {
					if (j && j.ok) {
						editor.value = j.content || "";
						editor.readOnly = false;
						logLine("OpenClash-Tools: 已加载 " + targetLabel(j.target || target || "runtime"));
						renderHighlight();
					} else {
						logLine("OpenClash-Tools: 读取失败 — " + (j && j.err ? j.err : "?"));
					}
				})
				.catch(function (e) {
					logLine("OpenClash-Tools: 读取异常 | " + (e && e.message ? e.message : e));
				})
				.finally(function () {
					setBusy(false);
				});
		}

		function saveScript() {
			if (!scriptSaveUrl) {
				logLine("OpenClash-Tools: 脚本保存 URL 未配置");
				return Promise.resolve();
			}
			if (busy) return Promise.resolve();
			setBusy(true);
			var tok = getLuciToken();
			var body =
				"target=" +
				encodeURIComponent(targetSel.value || "runtime") +
				"&content=" +
				encodeURIComponent(editor.value || "");
			if (tok) body += "&token=" + encodeURIComponent(tok);
			var t0 = Date.now();
			logLine("OpenClash-Tools: 保存 | 目标=" + targetLabel(targetSel.value || ""));
			return fetch(scriptSaveUrl, {
				method: "POST",
				credentials: "same-origin",
				headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
				body: body,
			})
				.then(function (r) {
					logHttpMeta("OpenClash-Tools 保存脚本", r, Date.now() - t0);
					return r.text().then(function (text) {
						var j;
						try {
							j = JSON.parse(text);
						} catch (e) {
							j = { ok: false, err: "非 JSON", raw: text };
						}
						return j;
					});
				})
				.then(function (j) {
					if (j && j.ok) {
						logLine("OpenClash-Tools: " + (j.msg || "已保存") + (j.size != null ? " | " + j.size + " bytes" : ""));
					} else {
						logLine("OpenClash-Tools: 保存失败 — " + (j && j.err ? j.err : "?"));
					}
				})
				.catch(function (e) {
					logLine("OpenClash-Tools: 保存异常 | " + (e && e.message ? e.message : e));
				})
				.finally(function () {
					setBusy(false);
				});
		}

		btnInject.addEventListener("click", function () {
			if (!confirm("确认注入当前选择模板到 OpenClash？")) return;
			if (!injectUrl) {
				logLine("OpenClash-Tools: 注入 URL 未配置");
				return;
			}
			if (busy) return;
			setBusy(true);
			var tok = getLuciToken();
			var target = targetSel.value || "runtime";
			var body =
				"target=" +
				encodeURIComponent(target) +
				"&content=" +
				encodeURIComponent(editor.value || "");
			if (tok) body += "&token=" + encodeURIComponent(tok);
			if (chkRestart && chkRestart.checked) body += "&restart=1";
			var t0 = Date.now();
			logLine("OpenClash-Tools: 注入开始 | 模板=" + targetLabel(target));
			fetch(injectUrl, {
				method: "POST",
				credentials: "same-origin",
				headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
				body: body,
			})
				.then(function (r) {
					logHttpMeta("OpenClash-Tools 注入", r, Date.now() - t0);
					return r.text().then(function (text) {
						var j;
						try {
							j = JSON.parse(text);
						} catch (e) {
							j = { ok: false, err: "非 JSON", raw: text };
						}
						return j;
					});
				})
				.then(function (j) {
					logDetail("OpenClash-Tools 注入 响应", j);
					if (j && j.ok) {
						logLine("OpenClash-Tools: 注入成功");
						if (j.files && j.files.overwrite) {
							logLine("OpenClash-Tools: 生效覆写脚本 → " + j.files.overwrite);
						}
						if (j.hints && j.hints.length) {
							for (var hi = 0; hi < j.hints.length; hi++) {
								logLine("OpenClash-Tools: " + j.hints[hi]);
							}
						}
						if (j.inject_verified) {
							logLine("OpenClash-Tools: 已校验磁盘脚本含 TVTOOLS 注入标记");
						}
					} else {
						logLine("OpenClash-Tools: 注入失败 — " + (j && j.err ? j.err : "?"));
					}
				})
				.catch(function (e) {
					logLine("OpenClash-Tools: 注入异常 | " + (e && e.message ? e.message : e));
				})
				.finally(function () {
					setBusy(false);
				});
		});
		btnSaveScript.addEventListener("click", function () {
			saveScript();
		});
		targetSel.addEventListener("change", function () {
			loadScript();
		});
		editor.addEventListener("input", renderHighlight);
		editor.addEventListener("scroll", function () {
			editorHl.scrollTop = editor.scrollTop;
			editorHl.scrollLeft = editor.scrollLeft;
		});

		tvOpenclashTabEnter = function () {
			if (!loadedOnce) {
				loadedOnce = true;
				targetSel.value = "runtime";
				loadScript();
			}
		};
	}

	function initTvInfo(root) {
		var url = root.getAttribute("data-tvinfo-url") || "";
		var dl = document.getElementById("tv-base-dl");
		var stateEl = document.getElementById("tv-adb-state");
		if (!url || !dl) return;

		function row(dt, dd) {
			return "<dt>" + esc(dt) + "</dt><dd>" + esc(dd) + "</dd>";
		}

		function applyTvInfo(j) {
			if (!j || !j.ok) {
				var host = j && j.display_host ? String(j.display_host).trim() : "";
				var port = j && j.display_port ? String(j.display_port).trim() : "";
				var ipMuted =
					host !== ""
						? '<span class="tv-home__tag tv-home__tag--host tv-home__tag--host-muted">' +
						  esc(port && port !== "5555" ? host + ":" + port : host) +
						  "</span>"
						: "";
				if (stateEl)
					stateEl.innerHTML =
						'<span class="tv-home__tag tv-home__tag--muted">' +
						esc(j && j.err ? j.err : "未连接") +
						"</span>" +
						ipMuted;
				dl.innerHTML = row("状态", esc(j && j.err ? j.err : "未连接"));
				return;
			}
			var host = (j.display_host || "").trim();
			var port = (j.display_port || "").trim();
			var ipTag =
				host !== ""
					? '<span class="tv-home__tag tv-home__tag--host">' +
					  esc(port && port !== "5555" ? host + ":" + port : host) +
					  "</span>"
					: "";
			if (stateEl) {
				stateEl.innerHTML =
					'<span class="tv-home__tag tv-home__tag--ok">已连接</span>' + ipTag;
			}
			var s = j.summary || {};
			dl.innerHTML =
				row("厂商/品牌", s.vendor_brand || "—") +
				row("型号", s.model || "—") +
				row("系统", s.system || "—") +
				row("ABI", s.abi || "—") +
				row("Boot类型", s.boot || "—") +
				row("屏幕", s.screen || "—") +
				row("运行时间", s.uptime || "—") +
				row("内存", s.memory || "—") +
				row("存储", s.storage || "—");
		}

		function fetchTvInfo() {
			var tok = getLuciToken();
			var body = tok ? "token=" + encodeURIComponent(tok) : "";
			logLine("电视信息: 页面加载后自动拉取 | POST " + url + (tok ? " | 已附 token" : " | 无 token"));
			var t0 = Date.now();
			var ac = new AbortController();
			var timer = setTimeout(function () {
				ac.abort();
			}, 40000);
			fetch(url, {
				method: "POST",
				credentials: "same-origin",
				headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
				body: body,
				signal: ac.signal,
			})
				.then(function (r) {
					var ms = Date.now() - t0;
					logHttpMeta("电视信息", r, ms);
					return r.text().then(function (text) {
						var j;
						try {
							j = JSON.parse(text);
						} catch (e) {
							logLine(
								"电视信息: JSON 解析失败 | " +
									(e && e.message ? e.message : e) +
									" | 原文前 800 字符:\n" +
									(text || "").slice(0, 800)
							);
							j = {
								ok: false,
								err: "非 JSON（可能是登录页/Lua 报错）",
								_raw_preview: (text || "").slice(0, 400),
							};
						}
						return j;
					});
				})
				.then(function (j) {
					if (j && j.ok) {
						logDetail("电视信息: 成功 payload（含 summary）", {
							display_host: j.display_host,
							display_port: j.display_port,
							summary: j.summary,
						});
						logLine("电视信息: 界面已更新");
					} else {
						logDetail("电视信息: 失败 payload", j);
						logLine("电视信息: 失败 — " + (j && j.err ? j.err : "未知原因"));
					}
					applyTvInfo(j);
				})
				.catch(function (e) {
					var msg =
						e && e.name === "AbortError"
							? "请求超时（40s），可能 LuCI/adb 阻塞"
							: e && e.message
								? e.message
								: String(e);
					logLine("电视信息: 异常中断 | " + msg);
					applyTvInfo({ ok: false, err: msg });
				})
				.finally(function () {
					clearTimeout(timer);
				});
		}

		setTimeout(fetchTvInfo, 400);
	}

	function initTextInput(root) {
		var url = root.getAttribute("data-textinput-url") || "";
		var inp = document.getElementById("tv-text-to-tv");
		if (!url || !inp) return;
		inp.addEventListener("keydown", function (ev) {
			if (ev.key !== "Enter") return;
			ev.preventDefault();
			var v = inp.value || "";
			if (!v.trim()) {
				logLine("文本发送: 内容为空，跳过");
				return;
			}
			var tok = getLuciToken();
			var body = "text=" + encodeURIComponent(v);
			if (tok) body += "&token=" + encodeURIComponent(tok);
			var t0 = Date.now();
			logLine("文本发送: 开始 | 字符数=" + v.length + " | POST " + url);
			fetch(url, {
				method: "POST",
				credentials: "same-origin",
				headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
				body: body,
			})
				.then(function (r) {
					var ms = Date.now() - t0;
					logHttpMeta("文本发送", r, ms);
					return r.text().then(function (text) {
						var j;
						try {
							j = JSON.parse(text);
						} catch (e) {
							logLine("文本发送: JSON 解析失败 | " + (text || "").slice(0, 600));
							j = { ok: false, err: "非 JSON" };
						}
						return j;
					});
				})
				.then(function (j) {
					logDetail("文本发送: 响应", j);
					if (j && j.ok) {
						logLine("文本发送: 成功，已清空输入框");
						inp.value = "";
					} else {
						logLine("文本发送: 失败 — " + (j && j.err ? j.err : "?"));
					}
				})
				.catch(function (e) {
					logLine("文本发送: 异常 | " + (e && e.message ? e.message : String(e)));
				});
		});
	}

	function boot() {
		var root = document.getElementById("tv-tools-app");
		if (!root) return;
		initSyshell(root);
		initTabs(root);
		initLogClear();
		initRemoteKeys(root);
		initTextInput(root);
		initTvInfo(root);
		initAppsPanel(root);
		initOpenclashTools(root);
		logLine("TV-Tools: 界面已加载 | 路径 " + (location.pathname || "") + (location.search || ""));
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", boot);
	} else {
		boot();
	}
})();
