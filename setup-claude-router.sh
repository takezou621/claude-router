#!/usr/bin/env bash
# ============================================================================
# setup-claude-router.sh — Claude Code モデル切替環境セットアップスクリプト
# ============================================================================
#
# ■ これは何?
#   Claude Code の /model コマンドで
#     GLM5.2 (z.ai) ⇔ Fable (Anthropic Pro/Max サブスク)
#   を自由に切り替えられるようにするスクリプトです。
#   macOS と Linux (Ubuntu 等, systemd 必須) の両方に対応しています。
#
# ■ 仕組み
#   ローカルプロキシ (127.0.0.1:8787) を常駐させ、リクエストの model 名で振り分けます。
#     - model が glm*     -> https://api.z.ai/api/anthropic (z.ai トークンを自動注入)
#     - model がそれ以外  -> https://api.anthropic.com (サブスクの OAuth をそのまま転送)
#
#   配置されるファイル:
#     ~/.claude/proxy/router.mjs   ルーティングプロキシ本体 (Node.js)
#     ~/.claude/proxy/config.json  z.ai トークン等の設定 (chmod 600 で保護)
#     ~/.claude/proxy/router.log   通信ログ (トークンはマスクされます)
#     ~/.claude/settings.json      ANTHROPIC_BASE_URL をプロキシに向ける (自動バックアップ後にマージ更新)
#     [macOS]  ~/Library/LaunchAgents/local.claude-router.plist   (launchd 常駐)
#     [Linux]  ~/.config/systemd/user/claude-router.service       (systemd --user 常駐)
#
# ■ 事前に必要なもの
#   - Node.js 18 以上  (mac: brew install node / ubuntu: sudo apt install nodejs)
#   - z.ai の API トークン (https://z.ai で取得)
#   - Fable を使う場合: Claude Pro/Max サブスクのアカウント
#
# ■ インストール方法
#   方法1: トークンを環境変数で渡す
#     ZAI_TOKEN=<z.aiのAPIトークン> ./setup-claude-router.sh
#
#   方法2: そのまま実行 (トークンは非表示の対話プロンプトで入力)
#     ./setup-claude-router.sh
#
#   ※ 2回目以降は既存の config.json からトークンを自動引き継ぎするので
#      ZAI_TOKEN の指定は不要です (再インストール・更新が簡単にできます)。
#
#   オプション (環境変数で上書き可能):
#     ROUTER_PORT=8787                              プロキシの待受ポート
#     GLM_MODEL=glm-5.2                             既定の GLM モデル ID
#     GLM_BASE_URL=https://api.z.ai/api/anthropic   z.ai エンドポイント
#
# ■ インストール後にやること
#   1. Claude Code を再起動する (設定の env は起動時にしか読まれません)
#   2. /login で Pro/Max サブスクのアカウントにログイン (Fable 利用に必須)
#   3. /model でモデルを切り替えて使う
#        GLM5.2 を選択 -> z.ai 経由 (安価・高速)
#        Fable  を選択 -> Anthropic 公式 (サブスク枠を消費)
#
# ■ 動作確認
#   tail -f ~/.claude/proxy/router.log
#     GLM:   {"model":"glm-5.2","route":"glm","status":200}          が出れば OK
#     Fable: {"model":"claude-fable-5","route":"anthropic","status":200} が出れば OK
#     ※ Fable で 401 が出る場合は /login を確認してください
#
# ■ アンインストール方法
#   ./setup-claude-router.sh --uninstall
#     - 常駐プロセス (launchd/systemd) を停止・削除します
#     - settings.json は自動では戻しません (画面の案内に従いバックアップから復元)
#     - ~/.claude/proxy/ (トークン含む) は残ります。完全に消す場合:
#         rm -rf ~/.claude/proxy
#
# ■ 注意事項
#   - /model で Fable を選んでも settings.json の "model" ピンにより
#     再起動後は GLM に戻ります。Fable を恒久既定にしたい場合は
#     ~/.claude/settings.json の "model" 行を削除してください。
#   - opus/sonnet/haiku のエイリアス指定はすべて GLM に解決されます
#     (バックグラウンドの軽量呼び出しも GLM 側で処理され、サブスク枠を節約)。
#   - Linux を SSH のみで使う場合、ログアウト後も常駐させるには:
#       sudo loginctl enable-linger $USER
# ============================================================================
set -euo pipefail

# ---------- 定数 ----------
CLAUDE_DIR="${HOME}/.claude"
PROXY_DIR="${CLAUDE_DIR}/proxy"
SETTINGS="${CLAUDE_DIR}/settings.json"
PORT="${ROUTER_PORT:-8787}"
GLM_MODEL="${GLM_MODEL:-glm-5.2}"
GLM_BASE_URL="${GLM_BASE_URL:-https://api.z.ai/api/anthropic}"
LABEL="local.claude-router"                                  # macOS launchd label
SYSTEMD_UNIT="claude-router.service"                          # Linux systemd unit

OS="$(uname -s)"
case "$OS" in
  Darwin) PLATFORM="macos" ;;
  Linux)  PLATFORM="linux" ;;
  *) echo "ERROR: 未対応OS: $OS" >&2; exit 1 ;;
esac

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- アンインストール ----------
uninstall() {
  log "アンインストールを開始します"
  if [ "$PLATFORM" = "macos" ]; then
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null && log "launchd agent 停止" || true
    rm -f "${HOME}/Library/LaunchAgents/${LABEL}.plist"
  else
    systemctl --user disable --now "${SYSTEMD_UNIT}" 2>/dev/null && log "systemd unit 停止" || true
    rm -f "${HOME}/.config/systemd/user/${SYSTEMD_UNIT}"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  # settings.json は最新バックアップから復元を案内(自動では書き換えない)
  local latest_bak
  latest_bak=$(ls -t "${SETTINGS}".bak.* 2>/dev/null | head -1 || true)
  if [ -n "$latest_bak" ]; then
    warn "settings.json は自動では戻しません。必要なら:"
    warn "  cp '$latest_bak' '$SETTINGS'"
  fi
  warn "~/.claude/proxy/ (トークン含む) は残しています。不要なら: rm -rf '$PROXY_DIR'"
  log "アンインストール完了。Claude Code を再起動してください。"
  exit 0
}
[ "${1:-}" = "--uninstall" ] && uninstall

# ---------- 前提チェック ----------
command -v node >/dev/null 2>&1 || die "Node.js が見つかりません。インストールしてください (mac: brew install node / ubuntu: apt install nodejs など)"
NODE_BIN="$(command -v node)"
NODE_MAJOR="$(node -e 'console.log(process.versions.node.split(".")[0])')"
[ "$NODE_MAJOR" -ge 18 ] || die "Node.js 18 以上が必要です (現在: $(node -v))"
log "Node.js: $NODE_BIN ($(node -v))"

if [ "$PLATFORM" = "linux" ]; then
  command -v systemctl >/dev/null 2>&1 || die "systemd (systemctl) が必要です"
fi

# ポート衝突チェック(自分のルーターが既に居る場合はOK)
if curl -s --max-time 2 "http://127.0.0.1:${PORT}/__health" 2>/dev/null | grep -q claude-router; then
  log "既存の claude-router がポート ${PORT} で稼働中(更新モードで続行)"
elif (command -v lsof >/dev/null && lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1) \
  || (command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":${PORT} "); then
  die "ポート ${PORT} が別プロセスに使用されています。ROUTER_PORT=<別ポート> を指定して再実行してください"
fi

# ---------- z.ai トークン ----------
ZAI_TOKEN="${ZAI_TOKEN:-}"
if [ -z "$ZAI_TOKEN" ] && [ -f "${PROXY_DIR}/config.json" ]; then
  # 既存 config から引き継ぎ
  ZAI_TOKEN="$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).glm.token||"")}catch(e){}' "${PROXY_DIR}/config.json")"
  [ -n "$ZAI_TOKEN" ] && log "既存 config.json から z.ai トークンを引き継ぎます"
fi
if [ -z "$ZAI_TOKEN" ]; then
  printf 'z.ai の API トークンを入力してください (入力は非表示): '
  read -rs ZAI_TOKEN; echo
  [ -n "$ZAI_TOKEN" ] || die "トークンが空です"
fi

# ---------- バックアップ ----------
mkdir -p "$CLAUDE_DIR" "$PROXY_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
if [ -f "$SETTINGS" ]; then
  cp -p "$SETTINGS" "${SETTINGS}.bak.${TS}"
  log "バックアップ: ${SETTINGS}.bak.${TS}"
fi

# ---------- router.mjs ----------
cat > "${PROXY_DIR}/router.mjs" <<'ROUTER_EOF'
#!/usr/bin/env node
// Claude Code 用ローカルルーティングプロキシ
// model 名で振り分け: glm* -> z.ai / それ以外(fable, claude-*) -> Anthropic 公式
//   - glm ルート: プロキシが z.ai トークンを注入
//   - anthropic ルート: Claude Code が付けた OAuth Bearer(サブスク)をそのまま転送
// 127.0.0.1 のみで待ち受け、レスポンスは pipe して SSE ストリーミングを保持。

import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { URL } from 'node:url';

const CONFIG_PATH = path.join(os.homedir(), '.claude', 'proxy', 'config.json');
const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));

const PORT = config.port ?? 8787;
const GLM = config.glm;            // { base_url, token, match }
const ANTH = config.anthropic;     // { base_url }

const glmRe = new RegExp(GLM.match ?? '^glm');

// hop-by-hop および自前で再設定するヘッダ。これらは上流/下流いずれでも転送しない。
const DROP = new Set([
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailers', 'transfer-encoding', 'upgrade', 'host', 'content-length',
]);

function log(obj) {
  obj.ts = new Date().toISOString();
  console.log(JSON.stringify(obj));
}

function maskAuth(v) {
  if (!v) return '<none>';
  const s = String(v);
  return s.slice(0, 12) + '…(' + s.length + ')';
}

function pickUpstream(model) {
  if (model && glmRe.test(model)) {
    return { name: 'glm', base: GLM.base_url, injectAuth: true, auth: 'Bearer ' + GLM.token };
  }
  return { name: 'anthropic', base: ANTH.base_url, injectAuth: false };
}

// 上流へ送るリクエストヘッダを構築
function buildReqHeaders(inHeaders, upstream, bodyLen) {
  const out = {};
  for (const [k, v] of Object.entries(inHeaders)) {
    const lk = k.toLowerCase();
    if (DROP.has(lk)) continue;
    if (lk === 'authorization') {
      if (upstream.injectAuth) continue;            // GLM: 後で注入
      out[k] = v;                                    // Anthropic: OAuth を保持
      continue;
    }
    if (lk === 'x-api-key') {
      if (upstream.injectAuth) continue;            // GLM: ドロップ
      out[k] = v;
      continue;
    }
    out[k] = v;
  }
  if (upstream.injectAuth) out['authorization'] = upstream.auth;
  out['content-length'] = String(bodyLen);
  return out;
}

const server = http.createServer(async (clientReq, clientRes) => {
  // ヘルスチェック
  if (clientReq.method === 'GET' && (clientReq.url === '/__health' || clientReq.url === '/')) {
    clientRes.writeHead(200, { 'content-type': 'application/json' });
    clientRes.end(JSON.stringify({ ok: true, service: 'claude-router' }));
    return;
  }

  let model = '';
  try {
    // body をバッファリングして model を取得
    const chunks = [];
    for await (const c of clientReq) chunks.push(c);
    const body = Buffer.concat(chunks);
    if (body.length) {
      try { model = JSON.parse(body.toString('utf8')).model ?? ''; } catch {}
    }

    const upstream = pickUpstream(model);
    const u = new URL(upstream.base);
    const reqHeaders = buildReqHeaders(clientReq.headers, upstream, body.length);
    reqHeaders['host'] = u.host;
    // base URL のパス部分(/api/anthropic 等)とリクエストパスを結合(二重スラッシュ回避)
    const basePath = u.pathname.replace(/\/+$/, '');
    const fullPath = basePath + clientReq.url;

    const upstreamReq = https.request(
      {
        protocol: u.protocol,
        hostname: u.hostname,
        port: u.port || (u.protocol === 'https:' ? 443 : 80),
        method: clientReq.method,
        path: fullPath,
        headers: reqHeaders,
      },
      (upstreamRes) => {
        // レスポンスヘッダは hop-by-hop/content-length を落として転送(Node が再フレーム)
        const respHeaders = {};
        for (const [k, v] of Object.entries(upstreamRes.headers)) {
          if (DROP.has(k.toLowerCase())) continue;
          respHeaders[k] = v;
        }
        clientRes.writeHead(upstreamRes.statusCode ?? 502, respHeaders);
        upstreamRes.pipe(clientRes);   // SSE 含めストリーミングでそのまま通す
        log({
          method: clientReq.method, path: clientReq.url, model: model || '-',
          route: upstream.name, auth: maskAuth(reqHeaders['authorization']),
          status: upstreamRes.statusCode,
        });
      }
    );

    upstreamReq.on('error', (e) => {
      log({ error: String(e), route: upstream.name, model: model || '-' });
      if (!clientRes.headersSent) clientRes.writeHead(502, { 'content-type': 'application/json' });
      try { clientRes.end(JSON.stringify({ error: 'upstream_error', detail: String(e) })); } catch {}
    });

    if (body.length) upstreamReq.end(body); else upstreamReq.end();
  } catch (e) {
    log({ fatal: String(e) });
    if (!clientRes.headersSent) clientRes.writeHead(500, { 'content-type': 'application/json' });
    try { clientRes.end(JSON.stringify({ error: 'proxy_error', detail: String(e) })); } catch {}
  }
});

server.listen(PORT, '127.0.0.1', () => {
  log({ event: 'listening', port: PORT, glm: GLM.base_url, anthropic: ANTH.base_url });
});

server.on('error', (e) => log({ event: 'server_error', error: String(e) }));
ROUTER_EOF
chmod 755 "${PROXY_DIR}/router.mjs"
log "router.mjs を配置"

# ---------- config.json (トークン含む・600) ----------
umask 077
ZAI_TOKEN="$ZAI_TOKEN" PORT="$PORT" GLM_BASE_URL="$GLM_BASE_URL" \
node -e '
const fs = require("fs"), os = require("os"), path = require("path");
const p = path.join(os.homedir(), ".claude", "proxy", "config.json");
fs.writeFileSync(p, JSON.stringify({
  port: Number(process.env.PORT),
  glm: { base_url: process.env.GLM_BASE_URL, token: process.env.ZAI_TOKEN, match: "^glm" },
  anthropic: { base_url: "https://api.anthropic.com" },
}, null, 2) + "\n", { mode: 0o600 });
'
umask 022
chmod 600 "${PROXY_DIR}/config.json"
log "config.json を配置 (chmod 600)"

# ---------- 常駐化 ----------
if [ "$PLATFORM" = "macos" ]; then
  PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
  mkdir -p "${HOME}/Library/LaunchAgents"
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${NODE_BIN}</string>
        <string>${PROXY_DIR}/router.mjs</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>${PROXY_DIR}/router.log</string>
    <key>StandardErrorPath</key>
    <string>${PROXY_DIR}/router.log</string>
</dict>
</plist>
PLIST_EOF
  # 再読込 (既存があれば一旦降ろす)
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  log "launchd agent 起動: ${LABEL}"
else
  UNIT_DIR="${HOME}/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "${UNIT_DIR}/${SYSTEMD_UNIT}" <<UNIT_EOF
[Unit]
Description=Claude Code model routing proxy (glm <-> anthropic)
After=network.target

[Service]
ExecStart=${NODE_BIN} ${PROXY_DIR}/router.mjs
Restart=always
RestartSec=10
StandardOutput=append:${PROXY_DIR}/router.log
StandardError=append:${PROXY_DIR}/router.log

[Install]
WantedBy=default.target
UNIT_EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "${SYSTEMD_UNIT}"
  log "systemd user unit 起動: ${SYSTEMD_UNIT}"
  # SSHのみで使う場合、ログアウト後もユニットを維持するには linger が必要
  if command -v loginctl >/dev/null 2>&1; then
    if ! loginctl show-user "$(whoami)" 2>/dev/null | grep -q '^Linger=yes'; then
      warn "ログアウト後も常駐させるには: sudo loginctl enable-linger $(whoami)"
    fi
  fi
fi

# ---------- ヘルスチェック ----------
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -s --max-time 2 "http://127.0.0.1:${PORT}/__health" | grep -q claude-router; then
    log "プロキシ稼働確認 OK (http://127.0.0.1:${PORT})"
    HEALTH_OK=1
    break
  fi
  sleep 1
done
[ "${HEALTH_OK:-}" = "1" ] || die "プロキシが起動しません。ログを確認: ${PROXY_DIR}/router.log"

# ---------- settings.json 更新 (既存キーは保持してマージ) ----------
PORT="$PORT" GLM_MODEL="$GLM_MODEL" SETTINGS="$SETTINGS" node -e '
const fs = require("fs");
const p = process.env.SETTINGS;
let s = {};
try { s = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
s.env = s.env || {};
s.env.ANTHROPIC_BASE_URL = "http://127.0.0.1:" + process.env.PORT;
s.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = process.env.GLM_MODEL;
s.env.ANTHROPIC_DEFAULT_SONNET_MODEL = process.env.GLM_MODEL;
s.env.ANTHROPIC_DEFAULT_OPUS_MODEL = process.env.GLM_MODEL;
s.env.API_TIMEOUT_MS = s.env.API_TIMEOUT_MS || "3000000";
s.model = process.env.GLM_MODEL;   // 起動時の既定は GLM。不要なら手動でこの行を消す
fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
'
log "settings.json を更新 (既存設定は保持)"

# ---------- ルーティング疎通テスト (GLM側のみ・トークンで実測) ----------
GLM_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
  -X POST "http://127.0.0.1:${PORT}/v1/messages" \
  -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
  -d "{\"model\":\"${GLM_MODEL}\",\"max_tokens\":4,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" || echo "000")
if [ "$GLM_STATUS" = "200" ]; then
  log "GLM ルート疎通 OK (200)"
else
  warn "GLM ルート応答: HTTP ${GLM_STATUS} — トークンやネットワークを確認してください (log: ${PROXY_DIR}/router.log)"
fi

# ---------- 完了 ----------
cat <<DONE_EOF

============================================================
 セットアップ完了
============================================================
 次の手順:
   1. Claude Code を再起動してください (env は起動時に読込)
   2. /login で Pro/Max サブスクのアカウントにログイン
      (Fable は OAuth 必須。GLM もプロキシ経由なのでログイン推奨)
   3. /model で切替:
        - GLM5.2  -> z.ai 経由 (トークンはプロキシが注入)
        - Fable   -> api.anthropic.com (サブスク OAuth)

 確認方法:
   tail -f ${PROXY_DIR}/router.log
   (Fable 送信時に route:"anthropic", status:200 が出れば完全動作)

 注意:
   - /model で Fable を選んでも settings.json の "model" ピンにより
     再起動後は GLM に戻ります。Fable を恒久既定にするなら
     ${SETTINGS} の "model" 行を削除してください。
   - opus/sonnet/haiku エイリアスは GLM に解決されます
     (ANTHROPIC_DEFAULT_*_MODEL)。

 ロールバック:
   $([ -f "${SETTINGS}.bak.${TS}" ] && echo "cp '${SETTINGS}.bak.${TS}' '${SETTINGS}'" || echo "(settings.json は新規作成でした)")
   $0 --uninstall
============================================================
DONE_EOF
