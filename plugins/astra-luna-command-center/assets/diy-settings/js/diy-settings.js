/* astra-Diy settings UI — Base URL + API Key auto-fetch models into a dropdown */
(function () {
  const STORAGE_KEY = "astra-diy-settings-v1";
  const MODELS_KEY = "astra-diy-models-cache-v1";
  const CUSTOM = "__custom__";
  const DEFAULT_DIY_PATH =
    "C:\\Users\\Administrator\\.codex\\skills\\astra-command-center\\.astra-luna-state\\diy.json";

  const $ = (id) => document.getElementById(id);

  const els = {
    baseUrl: $("baseUrl"),
    apiKey: $("apiKey"),
    provider: $("provider"),
    appid: $("appid"),
    aesKey: $("aesKey"),
    wxEnv: $("wxEnv"),
    wechatFields: $("wechatFields"),
    modelSelect: $("modelSelect"),
    model: $("model"),
    modelCustomRow: $("modelCustomRow"),
    modelHint: $("modelHint"),
    temperature: $("temperature"),
    timeoutSec: $("timeoutSec"),
    enabled: $("enabled"),
    replaceLuna: $("replaceLuna"),
    statusLine: $("statusLine"),
    jsonPreview: $("jsonPreview"),
    cliPreview: $("cliPreview"),
    testOutput: $("testOutput"),
    modelList: $("modelList"),
    modelChips: $("modelChips"),
    badgeRoute: $("badgeRoute"),
    statEnabled: $("statEnabled"),
    statReady: $("statReady"),
    statReplace: $("statReplace"),
    statRoute: $("statRoute"),
  };

  let fetchedModels = [];
  let fetchTimer = null;
  let lastFetchKey = "";

  function toast(msg, type) {
    let node = document.querySelector(".toast");
    if (!node) {
      node = document.createElement("div");
      node.className = "toast";
      document.body.appendChild(node);
    }
    node.textContent = msg;
    node.className = "toast show " + (type || "");
    clearTimeout(node._t);
    node._t = setTimeout(() => {
      node.className = "toast " + (type || "");
    }, 2600);
  }

  function normalizeBaseUrl(raw) {
    let url = String(raw || "").trim().replace(/\/+$/, "");
    if (!url) return "";
    if (!/^https?:\/\//i.test(url)) {
      url = "https://" + url;
    }
    // WeChat chatbot hosts: strip OpenAI path suffix
    if (/weixin\.qq\.com/i.test(url)) {
      return url.replace(/\/openai(\/v\d+)?$/i, "").replace(/\/v\d+$/i, "").replace(/\/+$/, "");
    }
    if (/\/v\d+$/i.test(url) || /\/v\d+\//i.test(url)) return url;
    return url + "/v1";
  }

  function selectedProvider() {
    const p = (els.provider && els.provider.value) || "openai-compatible";
    // User explicitly chose OpenAI-compatible → never force wechat-chatapi
    return p;
  }

  function isWechatHost() {
    return /weixin\.qq\.com/i.test(els.baseUrl.value || "");
  }

  function isWechatV2Only() {
    // ONLY when user explicitly picks the official /v2 provider
    return selectedProvider() === "wechat-chatapi";
  }

  function isWechatGateway() {
    // SpiderCode-style: weixin host + OpenAI-compatible (default for this URL)
    return isWechatHost() && !isWechatV2Only();
  }

  function isWechat() {
    return isWechatHost() || isWechatV2Only();
  }

  function collect() {
    let baseUrl = "";
    try {
      baseUrl = normalizeBaseUrl(els.baseUrl.value);
    } catch (e) {
      throw e;
    }
    let provider = selectedProvider();
    if (provider === "openai-compatible" && isWechatHost()) {
      // keep user's OpenAI-compatible choice; mark gateway for display only
      provider = "wechat-openai-gateway";
    }
    return {
      provider: provider,
      enabled: els.enabled.checked,
      replace_luna: els.replaceLuna.checked,
      base_url: baseUrl,
      api_key: els.apiKey.value.trim(),
      appid: els.appid ? els.appid.value.trim() : "",
      aes_key: els.aesKey ? els.aesKey.value.trim() : "",
      env: els.wxEnv ? (els.wxEnv.value.trim() || "online") : "online",
      model: currentModelValue(),
      temperature: Number(els.temperature.value || 0.2),
      timeout_sec: Number(els.timeoutSec.value || 900),
      updated_at: new Date().toISOString(),
    };
  }

  function isReady(cfg) {
    const provider = String(cfg.provider || "");
    const v2 = provider === "wechat-chatapi";
    if (v2) {
      return !!(cfg.enabled && cfg.base_url && cfg.api_key && cfg.model && cfg.appid);
    }
    // OpenAI-compatible / wechat gateway: NO appid required
    return !!(cfg.enabled && cfg.base_url && cfg.api_key && cfg.model);
  }

  function routeText(cfg) {
    if (isReady(cfg) && cfg.replace_luna) {
      const provider = String(cfg.provider || "");
      if (provider === "wechat-chatapi") {
        return "diy-openai/wechat-v2 → " + cfg.model;
      }
      return "diy-openai → " + cfg.model;
    }
    return "local-worker / gpt-5.6-luna";
  }

  function cliCommand(cfg) {
    const key = cfg.api_key ? cfg.api_key : "<API_KEY>";
    const base = cfg.base_url || "<BASE_URL>";
    const model = cfg.model || "<MODEL>";
    let provider = cfg.provider || "openai-compatible";
    if (provider === "wechat-openai-gateway") provider = "openai-compatible";
    const lines = [
      'powershell -NoProfile -ExecutionPolicy Bypass -File "C:\\Users\\Administrator\\.codex\\skills\\astra-command-center\\scripts\\astra-luna.ps1" diy-set `',
      `  -Provider "${provider}" \``,
      `  -BaseUrl "${base}" \``,
      `  -ApiKey "${key}" \``,
    ];
    // APPID/AESKey ONLY for explicit official /v2 provider
    if (String(cfg.provider || "") === "wechat-chatapi") {
      lines.push(`  -AppId "${cfg.appid || "<APPID>"}" \``);
      lines.push(`  -AesKey "${cfg.aes_key || "<AES_KEY>"}" \``);
      lines.push(`  -WxEnv "${cfg.env || "online"}" \``);
    }
    lines.push(`  -Model "${model}" \``);
    lines.push(`  -Enabled ${cfg.enabled ? "true" : "false"} \``);
    lines.push(`  -ReplaceLuna ${cfg.replace_luna ? "true" : "false"} \``);
    lines.push(`  -Temperature ${cfg.temperature} \``);
    lines.push(`  -TimeoutSec ${cfg.timeout_sec}`);
    lines.push("");
    lines.push("# 然后测试 / 列模型");
    lines.push('powershell -NoProfile -ExecutionPolicy Bypass -File "C:\\Users\\Administrator\\.codex\\skills\\astra-command-center\\scripts\\astra-luna.ps1" diy-test');
    lines.push('powershell -NoProfile -ExecutionPolicy Bypass -File "C:\\Users\\Administrator\\.codex\\skills\\astra-command-center\\scripts\\astra-luna.ps1" diy-models');
    lines.push("");
    lines.push(`# 也可将导出的 diy.json 覆盖到:\n# ${DEFAULT_DIY_PATH}`);
    return lines.join("\n");
  }

  function syncWechatFields() {
    const v2 = isWechatV2Only();
    const gateway = isWechatGateway();
    // APPID/AESKey fields ONLY for official /v2
    if (els.wechatFields) els.wechatFields.hidden = !v2;
    if (els.modelHint) {
      if (v2) {
        els.modelHint.innerHTML =
          "官方微信 /v2 协议：需要 <strong>APPID + Token + EncodingAESKey</strong>。Model 可填机器人显示名。";
      } else if (gateway) {
        els.modelHint.innerHTML =
          "与 SpiderCode 相同的 OpenAI 兼容网关：填 Base URL + API Key + Model（如 <code>Deepseek-v4-flash</code>），<strong>无需 APPID</strong>。";
      }
    }
  }

  function maskKey(key) {
    const k = String(key || "");
    if (!k) return "";
    if (k.length <= 8) return "*".repeat(k.length);
    return k.slice(0, 3) + "*".repeat(Math.max(3, k.length - 7)) + k.slice(-4);
  }

  function currentModelValue() {
    const sel = els.modelSelect.value;
    if (sel === CUSTOM) return els.model.value.trim();
    return (sel || "").trim();
  }

  function cfgModelFromForm() {
    try {
      return currentModelValue() || (els.model && els.model.value.trim()) || "";
    } catch {
      return (els.model && els.model.value.trim()) || "";
    }
  }

  function previewPayload(cfg) {
    const shown = Object.assign({}, cfg);
    shown.api_key = cfg.api_key ? maskKey(cfg.api_key) : "";
    shown.models_available = fetchedModels.length;
    return shown;
  }

  function fillModelSelect(models, preferred) {
    const list = Array.isArray(models) ? models.slice() : [];
    fetchedModels = list;
    const prev = preferred != null ? String(preferred) : currentModelValue();

    els.modelSelect.innerHTML = "";
    const ph = document.createElement("option");
    ph.value = "";
    if (list.length === 0) {
      ph.textContent = "— 请先填写 Base URL 与 API Key，将自动获取可用模型 —";
    } else {
      ph.textContent = `— 请选择模型（共 ${list.length} 个）—`;
    }
    els.modelSelect.appendChild(ph);

    for (const id of list) {
      const opt = document.createElement("option");
      opt.value = id;
      opt.textContent = id;
      els.modelSelect.appendChild(opt);
    }

    const customOpt = document.createElement("option");
    customOpt.value = CUSTOM;
    customOpt.textContent = "自定义 model id…";
    els.modelSelect.appendChild(customOpt);

    if (prev && list.includes(prev)) {
      els.modelSelect.value = prev;
      els.modelCustomRow.hidden = true;
    } else if (prev && prev !== CUSTOM) {
      // saved value not in current provider list — keep as custom
      els.modelSelect.value = CUSTOM;
      els.model.value = prev;
      els.modelCustomRow.hidden = false;
    } else {
      els.modelSelect.value = "";
      els.modelCustomRow.hidden = true;
    }

    if (list.length > 0) {
      els.modelHint.innerHTML =
        `已从 API 获取 <strong>${list.length}</strong> 个可用模型，请在下拉列表中选择。` +
        `若列表为空或不对，可点「刷新模型」，或选「自定义 model id…」手填。`;
    }
  }

  function cacheModels(models, baseUrl, keyMask) {
    try {
      localStorage.setItem(
        MODELS_KEY,
        JSON.stringify({
          base_url: baseUrl,
          api_key_masked: keyMask,
          models: models,
          at: new Date().toISOString(),
        })
      );
    } catch (_) {}
  }

  function loadCachedModels() {
    try {
      return JSON.parse(localStorage.getItem(MODELS_KEY) || "null");
    } catch {
      return null;
    }
  }

  function render() {
    let cfg;
    try {
      cfg = collect();
    } catch (e) {
      cfg = {
        enabled: els.enabled.checked,
        replace_luna: els.replaceLuna.checked,
        base_url: els.baseUrl.value.trim(),
        api_key: els.apiKey.value.trim(),
        model: currentModelValue(),
        temperature: Number(els.temperature.value || 0.2),
        timeout_sec: Number(els.timeoutSec.value || 900),
      };
    }

    const ready = isReady(cfg);
    els.statEnabled.textContent = cfg.enabled ? "是" : "否";
    els.statReady.textContent = ready ? "是" : "否（缺字段）";
    els.statReplace.textContent = cfg.replace_luna ? "是" : "否";
    els.statRoute.textContent = routeText(cfg);
    els.badgeRoute.textContent =
      "worker: " + (ready && cfg.replace_luna ? cfg.model : "gpt-5.6-luna");
    els.jsonPreview.textContent = JSON.stringify(previewPayload(cfg), null, 2);
    els.cliPreview.textContent = cliCommand(cfg);
  }

  function saveLocal(cfg) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(cfg));
  }

  function loadLocal() {
    try {
      return JSON.parse(localStorage.getItem(STORAGE_KEY) || "null");
    } catch {
      return null;
    }
  }

  function applyToForm(cfg) {
    if (!cfg) return;
    els.baseUrl.value = cfg.base_url || "";
    if (typeof cfg.api_key === "string" && cfg.api_key && !cfg.api_key.includes("*")) {
      els.apiKey.value = cfg.api_key;
    }
    els.temperature.value = cfg.temperature != null ? cfg.temperature : 0.2;
    els.timeoutSec.value = cfg.timeout_sec != null ? cfg.timeout_sec : 900;
    els.enabled.checked = cfg.enabled !== false;
    els.replaceLuna.checked = cfg.replace_luna !== false;
    els.model.value = cfg.model || "";
  }

  async function copyText(text, label) {
    try {
      await navigator.clipboard.writeText(text);
      toast((label || "已复制") + "到剪贴板", "ok");
    } catch {
      const ta = document.createElement("textarea");
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      ta.remove();
      toast((label || "已复制") + "到剪贴板", "ok");
    }
  }

  function authHeaders(key) {
    return {
      "Content-Type": "application/json",
      Accept: "application/json",
      Authorization: "Bearer " + key,
    };
  }

  async function httpJson(url, options, timeoutMs) {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeoutMs || 20000);
    try {
      const res = await fetch(url, Object.assign({}, options, { signal: ctrl.signal }));
      const text = await res.text();
      let data = null;
      try {
        data = text ? JSON.parse(text) : null;
      } catch {
        data = null;
      }
      return { status: res.status, ok: res.ok, data, text };
    } finally {
      clearTimeout(t);
    }
  }

  function extractModelIds(data) {
    const ids = [];
    if (!data) return ids;
    const items = data.data || data.models || [];
    if (Array.isArray(items)) {
      for (const it of items) {
        if (typeof it === "string") ids.push(it);
        else if (it && it.id) ids.push(String(it.id));
      }
    }
    return ids;
  }

  function renderModelChips(ids) {
    els.modelList.hidden = !ids || ids.length === 0;
    els.modelChips.innerHTML = "";
    for (const id of ids || []) {
      const chip = document.createElement("button");
      chip.type = "button";
      chip.className = "chip";
      chip.textContent = id;
      chip.title = "点击选中该模型";
      chip.addEventListener("click", () => {
        if (Array.from(els.modelSelect.options).some((o) => o.value === id)) {
          els.modelSelect.value = id;
          els.modelCustomRow.hidden = true;
          render();
          toast("已选择模型: " + id, "ok");
        }
      });
      els.modelChips.appendChild(chip);
    }
  }

  function setTestOutput(obj) {
    els.testOutput.textContent =
      typeof obj === "string" ? obj : JSON.stringify(obj, null, 2);
  }

  async function fetchModelsIntoDropdown(opts) {
    const options = opts || {};
    let baseUrl = "";
    let apiKey = "";
    try {
      baseUrl = normalizeBaseUrl(els.baseUrl.value);
    } catch (e) {
      if (options.silent !== false) toast(e.message, "err");
      return false;
    }
    apiKey = els.apiKey.value.trim();
    if (!baseUrl || !apiKey) {
      if (options.silent !== false) {
        els.modelHint.textContent =
          "填写 Base URL 与 API Key 后，将自动从 API 获取可用模型到下拉列表。";
        toast("请先填写 Base URL 与 API Key", "err");
      }
      return false;
    }

    const preferred = options.preferredModel != null ? options.preferredModel : currentModelValue();
    els.modelHint.textContent = "正在从 API 获取可用模型…";
    setTestOutput({ stage: "models", message: "拉取模型列表…", base_url: baseUrl });

    try {
      const result = await httpJson(
        baseUrl + "/models",
        { method: "GET", headers: authHeaders(apiKey) },
        Math.min((Number(els.timeoutSec.value) || 900) * 1000, 30000)
      );
      const ids = extractModelIds(result.data);
      if (result.ok) {
        fillModelSelect(ids, preferred);
        cacheModels(ids, baseUrl, maskKey(apiKey));
        renderModelChips(ids);
        setTestOutput({
          ok: true,
          http_status: result.status,
          count: ids.length,
          models: ids,
          message: "模型已填充到下拉列表",
        });
        els.statusLine.textContent =
          ids.length > 0
            ? `已获取 ${ids.length} 个可用模型，请在 Model 下拉列表中选择。`
            : "接口成功，但模型列表为空。可选手动填写 model id。";
        toast(`已获取 ${ids.length} 个模型`, "ok");
        render();
        return true;
      }

      fillModelSelect([], preferred);
      renderModelChips([]);
      const hint =
        result.status === 401 || result.status === 403
          ? "API Key 被拒绝，无法获取模型列表"
          : result.status === 404
            ? "404：Base URL 可能缺少 /v1 或路径不对"
            : "获取模型失败 HTTP " + result.status;
      els.modelHint.textContent = hint + "。可手动输入 model id。";
      setTestOutput({
        ok: false,
        http_status: result.status,
        base_url: baseUrl,
        hint: hint,
        raw: result.data || result.text,
      });
      if (options.silent !== false) toast(hint, "err");
      return false;
    } catch (e) {
      const msg = String(e && e.message ? e.message : e);
      const cached = loadCachedModels();
      if (cached && Array.isArray(cached.models) && cached.models.length) {
        fillModelSelect(cached.models, preferred);
        renderModelChips(cached.models);
        els.modelHint.textContent =
          "在线获取失败（可能 CORS/网络），已显示上次缓存的模型列表。本机请用 diy-models 验证。";
        setTestOutput({
          ok: false,
          error: msg,
          used_cache: true,
          models_count: cached.models.length,
          note: "浏览器跨域失败时，请用插件 CLI：diy-models",
        });
      } else {
        fillModelSelect([], preferred);
        renderModelChips([]);
        els.modelHint.textContent =
          "获取模型失败（CORS/网络）。可手动输入 model id，或在 PowerShell 运行 diy-models。";
        setTestOutput({
          ok: false,
          error: msg,
          note: "浏览器直连失败时，请用插件 CLI：diy-models 后把 model 填进下拉/自定义框",
        });
      }
      if (options.silent !== false) toast("获取模型失败", "err");
      return false;
    }
  }

  function scheduleAutoFetch() {
    clearTimeout(fetchTimer);
    fetchTimer = setTimeout(() => {
      const base = els.baseUrl.value.trim();
      const key = els.apiKey.value.trim();
      if (!base || !key) return;
      let norm = "";
      try {
        norm = normalizeBaseUrl(base);
      } catch {
        return;
      }
      const stamp = norm + "|" + maskKey(key);
      if (stamp === lastFetchKey && fetchedModels.length > 0) return;
      lastFetchKey = stamp;
      fetchModelsIntoDropdown({ silent: true, preferredModel: currentModelValue() });
    }, 600);
  }

  // events
  $("btnToggleKey").addEventListener("click", () => {
    const showing = els.apiKey.type === "text";
    els.apiKey.type = showing ? "password" : "text";
    $("btnToggleKey").textContent = showing ? "显示" : "隐藏";
  });

  els.baseUrl.addEventListener("input", () => {
    syncWechatFields();
    render();
    if (!isWechat()) scheduleAutoFetch();
  });
  if (els.provider) {
    els.provider.addEventListener("change", () => {
      syncWechatFields();
      render();
      if (!isWechat()) scheduleAutoFetch();
    });
  }
  els.apiKey.addEventListener("input", () => {
    render();
    if (!isWechat()) scheduleAutoFetch();
  });
  ["temperature", "timeoutSec", "enabled", "replaceLuna", "model", "appid", "aesKey", "wxEnv"].forEach((id) => {
    const node = $(id);
    if (!node) return;
    node.addEventListener("input", render);
    node.addEventListener("change", render);
  });

  els.modelSelect.addEventListener("change", () => {
    if (els.modelSelect.value === CUSTOM) {
      els.modelCustomRow.hidden = false;
      els.model.focus();
    } else {
      els.modelCustomRow.hidden = true;
      els.model.value = "";
    }
    render();
  });

  $("btnSave").addEventListener("click", () => {
    try {
      const cfg = collect();
      if (!cfg.base_url) throw new Error("请填写 Base URL");
      if (!cfg.api_key) throw new Error("请填写 API Key / Token");
      if (!cfg.model) throw new Error("请填写 Model（如 Deepseek-v4-flash）");
      // ONLY official /v2 provider requires APPID — OpenAI-compatible gateway does NOT
      if (String(cfg.provider || "") === "wechat-chatapi" && !cfg.appid) {
        throw new Error("仅「微信对话开放平台 /v2」需要 APPID；OpenAI 兼容网关不用填");
      }
      saveLocal(cfg);
      render();
      const ready = isReady(cfg);
      els.statusLine.textContent = ready
        ? "配置已保存。OpenAI 兼容模式只需 Base URL + API Key + Model。可点「生成 CLI」或在 PowerShell diy-test 验证（浏览器可能 CORS）。"
        : "已保存，但仍缺字段（OpenAI 兼容：Base URL + API Key + Model）。";
      toast(ready ? "保存成功" : "已保存（尚未就绪）", ready ? "ok" : "");
    } catch (e) {
      toast(e.message || String(e), "err");
    }
  });

  $("btnTest").addEventListener("click", async () => {
    let cfg;
    try {
      cfg = collect();
    } catch (e) {
      toast(e.message, "err");
      return;
    }
    if (!cfg.base_url || !cfg.api_key) {
      toast("请先填写 Base URL 与 API Key/Token", "err");
      return;
    }
    if (isWechatV2Only()) {
      setTestOutput({
        provider: "wechat-chatapi-v2",
        message: "官方 /v2 协议需本机 CLI（签名+AES），浏览器无法完成",
        command: 'powershell -File "C:\\Users\\Administrator\\.codex\\skills\\astra-command-center\\scripts\\astra-luna.ps1" diy-test',
        config: previewPayload(cfg),
      });
      els.statusLine.textContent = "请用 PowerShell 运行 diy-test 验证 /v2 协议。";
      toast("请用 CLI diy-test", "");
      return;
    }
    const model = cfg.model || "Deepseek-v4-flash";
    setTestOutput({
      stage: "chat/completions",
      message: "连接中...",
      base_url: cfg.base_url,
      model: model,
    });
    const t0 = Date.now();
    try {
      // For WeChat gateway / OpenAI-compatible: POST chat/completions is the real probe
      const body = {
        model: model,
        messages: [{ role: "user", content: "ping" }],
        max_tokens: 16,
        stream: false,
      };
      const result = await httpJson(
        normalizeBaseUrl(cfg.base_url).replace(/\/+$/, "") + "/chat/completions",
        {
          method: "POST",
          headers: authHeaders(cfg.api_key),
          body: JSON.stringify(body),
        },
        Math.min(cfg.timeout_sec * 1000, 60000)
      );
      let content = "";
      if (result.ok && result.data && Array.isArray(result.data.choices) && result.data.choices[0]) {
        const msg = result.data.choices[0].message || {};
        content = String(msg.content || result.data.choices[0].text || "");
      }
      const out = {
        ok: !!result.ok,
        stage: "chat/completions",
        http_status: result.status,
        latency_ms: Date.now() - t0,
        base_url: normalizeBaseUrl(cfg.base_url),
        model: (result.data && result.data.model) || model,
        content_preview: content.slice(0, 200),
        usage: result.data && result.data.usage,
        provider: isWechatGateway() ? "wechat-openai-gateway" : "openai-compatible",
        note: result.ok
          ? "通道正常（与 SpiderCode 相同：Bearer + chat/completions）"
          : (result.text || "请求失败").slice(0, 300),
      };
      if (!result.ok) out.raw = result.data || result.text;
      setTestOutput(out);
      els.statusLine.textContent = out.ok
        ? "测试通过：接口可用，模型已响应。可点「保存配置」后在 Codex 使用 diy-openai。"
        : "测试失败：HTTP " + result.status;
      toast(out.ok ? "连接测试通过" : "连接测试失败", out.ok ? "ok" : "err");
      render();
    } catch (e) {
      const msg = String(e && e.message ? e.message : e);
      const out = {
        ok: false,
        stage: "chat/completions",
        error: msg,
        note: /cors|failed to fetch|network/i.test(msg)
          ? "浏览器 CORS 限制。请以 CLI diy-test 为准（插件内已可测通）。"
          : msg,
        command: 'powershell -File "C:\\Users\\Administrator\\.codex\\skills\\astra-command-center\\scripts\\astra-luna.ps1" diy-test',
      };
      setTestOutput(out);
      els.statusLine.textContent = "浏览器侧测试失败时，请用 CLI diy-test 确认。";
      toast("浏览器测试失败，可看 CLI", "err");
    }
  });

  $("btnRefreshModels").addEventListener("click", () => {
    if (isWechatGateway()) {
      const known = cfgModelFromForm() || "Deepseek-v4-flash";
      if (els.modelSelect) {
        els.modelSelect.innerHTML = "";
        const ph = document.createElement("option");
        ph.value = "";
        ph.textContent = "— 微信网关无标准模型目录，已填入可用模型 —";
        els.modelSelect.appendChild(ph);
        const opt = document.createElement("option");
        opt.value = known;
        opt.textContent = known;
        els.modelSelect.appendChild(opt);
        const customOpt = document.createElement("option");
        customOpt.value = "__custom__";
        customOpt.textContent = "自定义 model id…";
        els.modelSelect.appendChild(customOpt);
        els.modelSelect.value = known;
        if (els.modelCustomRow) els.modelCustomRow.hidden = true;
      }
      setTestOutput({
        provider: "wechat-openai-gateway",
        models: [known],
        note: "与 SpiderCode 相同：Base URL + API Key + Deepseek-v4-flash，无需 APPID",
      });
      toast("已填入 " + known, "ok");
      render();
      return;
    }
    if (isWechatV2Only()) {
      if (els.modelSelect) {
        els.modelSelect.innerHTML =
          '<option value="">— 微信官方 /v2 无 OpenAI 模型目录 —</option><option value="__custom__">自定义 model id…</option>';
        els.modelSelect.value = "__custom__";
        els.modelCustomRow.hidden = false;
      }
      setTestOutput({
        provider: "wechat-chatapi-v2",
        models: ["wechat-bot"],
        note: "官方 /v2 需 APPID+Token+AESKey",
      });
      toast("v2 协议请手填 model", "");
      return;
    }
    lastFetchKey = "";
    fetchModelsIntoDropdown({ silent: false, preferredModel: currentModelValue() });
  });

  $("btnClear").addEventListener("click", () => {
    els.apiKey.value = "";
    els.enabled.checked = false;
    els.modelSelect.value = "";
    els.model.value = "";
    els.modelCustomRow.hidden = true;
    fetchedModels = [];
    lastFetchKey = "";
    fillModelSelect([], "");
    renderModelChips([]);
    localStorage.removeItem(STORAGE_KEY);
    render();
    els.statusLine.textContent =
      "已清除本页配置并禁用 DIY。磁盘上的 diy.json 需用 diy-clear 或手动删除。";
    toast("本页配置已清除", "ok");
  });

  $("btnCli").addEventListener("click", () => {
    try {
      const cfg = collect();
      els.cliPreview.textContent = cliCommand(cfg);
      copyText(els.cliPreview.textContent, "CLI ");
    } catch (e) {
      toast(e.message, "err");
    }
  });

  $("btnCopyCli").addEventListener("click", () => {
    copyText(els.cliPreview.textContent, "CLI ");
  });

  $("btnCopyJson").addEventListener("click", () => {
    try {
      const cfg = collect();
      copyText(JSON.stringify(cfg, null, 2), "JSON ");
    } catch (e) {
      toast(e.message, "err");
    }
  });

  $("btnExport").addEventListener("click", () => {
    try {
      const cfg = collect();
      const blob = new Blob([JSON.stringify(cfg, null, 2) + "\n"], {
        type: "application/json;charset=utf-8",
      });
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = "diy.json";
      a.click();
      URL.revokeObjectURL(a.href);
      els.statusLine.textContent =
        "已下载 diy.json。请覆盖到: " + DEFAULT_DIY_PATH + " 然后运行 diy-show / diy-test。";
      toast("已导出 diy.json", "ok");
    } catch (e) {
      toast(e.message, "err");
    }
  });

  $("btnLoad").addEventListener("click", () => $("fileImport").click());
  $("fileImport").addEventListener("change", async (ev) => {
    const file = ev.target.files && ev.target.files[0];
    if (!file) return;
    try {
      const text = await file.text();
      const data = JSON.parse(text);
      applyToForm(data);
      render();
      // after import, try to auto-fetch models for the imported key/base
      if (data.base_url && data.api_key) {
        await fetchModelsIntoDropdown({
          silent: true,
          preferredModel: data.model || "",
        });
      } else if (data.model) {
        fillModelSelect(fetchedModels, data.model);
      }
      toast("已导入 diy.json", "ok");
    } catch (e) {
      toast("导入失败: " + e.message, "err");
    }
    ev.target.value = "";
  });

  // init
  const saved = loadLocal();
  if (saved) {
    applyToForm(saved);
    if (els.provider && saved.provider) els.provider.value = saved.provider;
    if (els.appid && saved.appid) els.appid.value = saved.appid;
    if (els.aesKey && saved.aes_key && !String(saved.aes_key).includes("*")) els.aesKey.value = saved.aes_key;
    if (els.wxEnv && saved.env) els.wxEnv.value = saved.env;
  }
  syncWechatFields();
  if (!isWechat()) {
    const cached = loadCachedModels();
    if (cached && Array.isArray(cached.models)) {
      fillModelSelect(cached.models, saved && saved.model);
      renderModelChips(cached.models);
      if (cached.models.length) {
        els.modelHint.innerHTML =
          `已载入缓存模型列表（${cached.models.length} 个）。修改 Base URL / API Key 后会自动重新获取。`;
      }
    } else {
      fillModelSelect([], saved && saved.model);
    }
  }
  render();
  if (els.baseUrl.value.trim() && els.apiKey.value.trim() && !isWechat()) {
    scheduleAutoFetch();
  }
})();
