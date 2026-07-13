# Claude Code モデル切替セットアップ (GLM5.2 ⇔ Fable)

Claude Code の `/model` で **GLM5.2 (z.ai)** と **Fable (Anthropic サブスク)** を切り替えられる環境を、macOS / Ubuntu(Linux) に1コマンドで構築するスクリプト。

## 仕組み

```
Claude Code ──► 127.0.0.1:8787 (router.mjs, 常駐)
                     │
                     ├─ model が glm*      ──► https://api.z.ai/api/anthropic
                     │                          (プロキシが z.ai トークンを注入)
                     └─ model が fable 等  ──► https://api.anthropic.com
                                                (Claude Code の OAuth Bearer を透過)
```

- 常駐化: macOS = launchd LaunchAgent (`local.claude-router`) / Linux = systemd --user (`claude-router.service`)
- z.ai トークンは `~/.claude/proxy/config.json` (chmod 600) にのみ保存
- 実行前に `~/.claude/settings.json` を自動バックアップ (`settings.json.bak.<timestamp>`)
- 既存の settings.json の設定はマージ保持(上書きは env の該当キーと model のみ)

## 前提

- Node.js 18+ (`brew install node` / `sudo apt install nodejs`)
- Linux は systemd 必須
- z.ai の API トークン
- Fable 利用には Claude Pro/Max サブスクアカウント

## インストール

```bash
ZAI_TOKEN=<z.aiトークン> ./setup-claude-router.sh
# トークン未指定なら対話プロンプト(非表示入力)
```

オプション(環境変数):

| 変数 | 既定 | 説明 |
|---|---|---|
| `ZAI_TOKEN` | (対話入力) | z.ai API トークン。既存 config があれば引き継ぎ |
| `ROUTER_PORT` | `8787` | プロキシの待受ポート |
| `GLM_MODEL` | `glm-5.2` | 既定 GLM モデル ID |
| `GLM_BASE_URL` | `https://api.z.ai/api/anthropic` | z.ai エンドポイント |

## セットアップ後

1. **Claude Code を再起動** (env は起動時読込)
2. `/login` で Pro/Max サブスクアカウントにログイン (Fable に必須)
3. `/model` で切替

動作確認:

```bash
tail -f ~/.claude/proxy/router.log
# GLM:   {"model":"glm-5.2","route":"glm","status":200}
# Fable: {"model":"claude-fable-5","route":"anthropic","auth":"Bearer sk-an…","status":200}
```

## 注意事項

- `/model` で Fable を選んでも、settings.json の `"model": "glm-5.2"` ピンにより**再起動後は GLM に戻る**。Fable を恒久既定にするなら settings.json の `model` 行を削除。
- opus/sonnet/haiku のエイリアスは `ANTHROPIC_DEFAULT_*_MODEL` により GLM に解決される(バックグラウンドの軽量呼び出しも GLM 側で処理されコスト節約になる)。
- Linux で SSH 利用のみの場合、ログアウト後も常駐させるには `sudo loginctl enable-linger $USER`。
- Fable リクエストで稀に 400→即リトライ 200 のペアがログに出るが、クライアントの自動リトライで成功しており正常。

## アンインストール / ロールバック

```bash
./setup-claude-router.sh --uninstall
# settings.json を戻す場合:
cp ~/.claude/settings.json.bak.<timestamp> ~/.claude/settings.json
# トークンごと削除する場合:
rm -rf ~/.claude/proxy
```

## トラブルシューティング

| 症状 | 確認 |
|---|---|
| プロキシが起動しない | `cat ~/.claude/proxy/router.log` / ポート衝突は `ROUTER_PORT` 変更 |
| GLM が 401 | z.ai トークンを確認し再実行(config を上書き) |
| Fable が 401 | `/login` 済みか確認。log の `auth` が `<none>` なら OAuth 未付与 |
| 設定が反映されない | Claude Code を再起動したか確認 |
