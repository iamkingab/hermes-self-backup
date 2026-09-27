# Hermes Self-Backup

把整个 [Hermes Agent](https://github.com/NousResearch/hermes-agent) **备份到私有 GitHub 仓库**，服务器挂了 / 重装了 / 换机了，能把「它」完整拉回来。

> 备份的不只是配置文件 —— 是 **技能、记忆、定时任务、脚本、会话历史、API 密钥**。
> 也就是：它的能力、习惯、和跟你聊过的所有事。

## 为什么需要这个

跑在服务器上的 AI Agent（Hermes 这类）有个特点：**它是「养」出来的**。

- 几十上百个技能（skill），是长期踩坑攒下来的
- 记忆文件里是用户的偏好、环境细节、工作习惯
- 会话历史里有全部上下文
- `config.yaml` 里配好了十几个服务商和渠道

这些东西**丢一次就是几个月的重建**。而服务器会挂、会欠费、会因为网络环境换机房 —— 尤其当你跑在**国内家宽 / 便宜 VPS / 会频繁更换的机器**上时。

本项目的目标：**让 Agent 变成一个可携带的「人格文件」，随时能在新机器上复活。**

## 三层架构

全量 `~/.hermes` 有几 GB，塞不进 Git（单文件 100MB 限制、仓库建议 <1GB）。所以分层：

| 层 | 内容 | 加密 | 说明 |
|---|---|---|---|
| **1 灵魂层** | `skills/` `memories/` `scripts/` `cron/jobs.json` `config.yaml`(脱敏) `SOUL.md` | 否 | 「它之所以是它」——恢复后立即可用 |
| **2 记忆层** | `state.db` 近 N 天会话历史 | 否 | 「聊过什么」，需可检索 → 含 FTS 索引 |
| **3 机密层** | `.env` `auth.json` `config.yaml` 完整版 `credentials/` | **GPG AES-256** | 一步到位恢复，不用重填几十个 key |

体积陷阱已排除（`.venv` `node_modules` `__pycache__` `.curator_backups` 等），技能目录通常从 **513M → 56M**。

## 快速开始

### 0. 依赖

```bash
# Debian/Ubuntu
sudo apt install -y git gpg rsync sqlite3 python3 curl
```

### 1. 建私有仓库

```bash
gh repo create hermes-backup --private      # 或网页上建
```

### 2. 初始化 vault

```bash
mkdir -p ~/hermes-vault && cd ~/hermes-vault
git init -b main
git remote add origin https://<USER>:<TOKEN>@github.com/<USER>/hermes-backup.git
git config user.email "backup@localhost"
git config user.name "Hermes Backup"
```

> ⚠️ **必须**先完成这步。备份脚本会检查 vault 是否为 git 仓库，否则直接退出。

### 3. 设置 GPG 密码（机密层用）

```bash
mkdir -p ~/.hermes/credentials
while :; do read -rsp "输入 GPG 密码(至少8位): " P; echo; [ ${#P} -ge 8 ] && break; echo "太短"; done
while :; do read -rsp "再输一次: " P2; echo; [ "$P" = "$P2" ] && break; echo "不一致"; done
printf '%s' "$P" > ~/.hermes/credentials/backup-gpg-pass
chmod 600 ~/.hermes/credentials/backup-gpg-pass
unset P P2
```

**注意**：
- 打字时**屏幕不显示**是正常的（`read -s`）
- **不要加引号**，引号会成为密码的一部分
- 这个密码**必须自己保存好**（密码管理器/纸条）—— 丢了就打不开密钥层
- 多台机器请**各用不同密码**，一台泄漏不牵连其他

### 4. 首次备份

```bash
cp scripts/hermes-backup.sh ~/.hermes/scripts/
chmod +x ~/.hermes/scripts/hermes-backup.sh
bash ~/.hermes/scripts/hermes-backup.sh
```

看到 `✅ 备份成功完成` 即成功。日志在 `~/.hermes/logs/backup.log`。

### 5. 配置自动备份

```bash
crontab -e
```

```cron
# 每天 04:00 全量备份
0 4 * * * /bin/bash $HOME/.hermes/scripts/hermes-backup.sh >> $HOME/.hermes/logs/backup.log 2>&1

# 每 6 小时看门狗（正常静默，故障才输出）
0 */6 * * * /bin/bash $HOME/.hermes/scripts/hermes-backup-watchdog.sh >> $HOME/.hermes/logs/watchdog.log 2>&1
```

> 多台机器请**错开时间**（如 04:00 / 04:30 / 05:00），避免同时上传挤带宽。

### 6. 验证备份真的可用（**别跳过**）

```bash
bash scripts/restore-hermes.sh      # 在另一个目录演练一遍
```

或手动：

```bash
cd /tmp && git clone <REPO_URL> drill && cd drill
# 第2层：合并切片 → 校验 → 查数据
cat memory/state-recent60d.db.gz.part-* > /tmp/s.db.gz   # 若有切片
gunzip -c /tmp/s.db.gz > /tmp/s.db
sqlite3 /tmp/s.db "PRAGMA integrity_check;
                   SELECT COUNT(*) FROM sessions;
                   SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH '关键词';"
# 第3层：解密
gpg --batch --passphrase-file ~/.hermes/credentials/backup-gpg-pass \
    --decrypt -o /tmp/sec.tar secrets/secrets.enc && tar tf /tmp/sec.tar
```

## 灾难恢复

新机器上装好 Hermes 后：

```bash
bash scripts/restore-hermes.sh
# 按提示输入仓库地址；需要时输入 GPG 密码
```

脚本会：克隆 → 停 Hermes → 备份现有配置（可回滚）→ 还原三层 → 验证完整性 → 打印后续步骤。

详见 [docs/RESTORE.md](docs/RESTORE.md)。

## 文件说明

| 文件 | 作用 |
|---|---|
| `scripts/hermes-backup.sh` | 主备份脚本（三层 + 切片 + 推送） |
| `scripts/hermes-backup-watchdog.sh` | 看门狗，零假警报设计 |
| `scripts/restore-hermes.sh` | 一键灾难恢复 |
| `scripts/notify-feishu.py` | 飞书告警通知（可选） |
| `scripts/verify-backup-integrity.sh` | 独立校验已备份的数据 |
| `docs/ARCHITECTURE.md` | 设计说明与踩坑记录 |
| `docs/RESTORE.md` | 详细恢复步骤 |

## 配置项（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `HERMES_DIR` | `~/.hermes` | Hermes 目录 |
| `VAULT` | `~/hermes-vault` | 备份仓库本地路径 |
| `BACKUP_DAYS` | `60` | 会话历史保留天数 |
| `SLICE_SIZE` | `90m` | 切片大小 |
| `GPG_PASS_FILE` | `~/.hermes/credentials/backup-gpg-pass` | 密码文件 |
| `MAX_AGE_H` | `30` | 看门狗告警阈值（小时） |

## 安全说明

- **明文密钥永不进仓库**。`config.yaml` 自动脱敏（密钥 → `<REDACTED>`），真实密钥只存在于 GPG 加密的 `secrets/secrets.enc`
- `.gitignore` 显式排除 `.env` `auth.json` `credentials/` `*.pem` `*.key`，同时**放行** `secrets/*.enc`
- 仓库**必须设为 Private**
- GitHub token 建议用 **fine-grained token**，只给单个仓库的 Contents 读写权限

## 已知踩坑（都验证过）

<details>
<summary><b>state.db 时间列跨版本不一致</b></summary>

老版本 Hermes 的 `sessions` 表有 `last_activity_at`，新版本只有 `started_at`/`ended_at`。
硬编码 `COALESCE(last_activity_at, started_at, 0)` 在新库上**直接抛 `no such column`**（`COALESCE` 不会跳过不存在的列）。
本脚本用 `PRAGMA table_info` **动态探测**，两种 schema 通吃。
</details>

<details>
<summary><b>「假成功」——最危险的坑</b></summary>

如果只判断「临时文件非空」，python 导出失败时会产生一个 0 字节/极小文件，脚本照样打 `✓ 已导出: 4.0K`。
结果：**日志一片绿，实际一层完全没备份**。

修复：捕获 python 退出码 + 校验导出库 `sessions`/`messages` 计数 > 0，并把计数打进日志便于肉眼核对。
</details>

<details>
<summary><b>FTS 索引必须显式重建</b></summary>

Hermes 用 FTS5 虚拟表 + trigram 视图。复制表结构时要先建虚拟表、再建视图、跳过影子表，最后 `INSERT INTO messages_fts(messages_fts) VALUES('rebuild')`。
不做这步，恢复后**全文搜索不可用**（但数据在，容易漏检）。
</details>

<details>
<summary><b>多跳 SSH 必须转发 agent</b></summary>

路径是「本机 → 跳板 → 目标机」时，**两段 ssh 都要带 `-A`**，否则第二跳报 `Permission denied (publickey)`，错误信息看起来像目标机密钥没配，实则是本地没转发。
</details>

<details>
<summary><b>巨型 heredoc 会被拦</b></summary>

`ssh host 'bash -s' <<'EOF' ... EOF` 太长会被安全解析器阻止。
正确做法：本地写成 `.sh` → `scp` 过去 → `ssh host 'bash /tmp/x.sh'`。
</details>

## License

MIT
