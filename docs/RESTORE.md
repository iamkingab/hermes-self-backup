# 恢复指南

服务器挂了 / 重装了 / 换机了，怎么把 Hermes 完整拉回来。

## 前提

- 新机器上**已装好 Hermes**（能启动即可，不需要配置）
- 手上有：
  - 备份仓库地址 + GitHub token
  - **备份时的 GPG 密码**（用于解密密钥层）

> 🔑 **GPG 密码是唯一的硬门槛**。没有它，灵魂层和会话历史能恢复，但密钥层打不开 —— 需要手工重填所有 API key。

## 一键恢复

```bash
# 从备份仓库拿到脚本（或手动下载 restore-hermes.sh）
bash scripts/restore-hermes.sh
```

脚本流程：

1. 提示输入仓库 HTTPS 地址（含 token）
2. 克隆备份到临时目录
3. **停止 Hermes**（避免文件占用）
4. **把现有 `~/.hermes` 改名备份**（可回滚，不会直接删）
5. 还原第 1 层（技能/记忆/脚本/cron）
6. 还原第 2 层（会话历史：合并切片 → 校验 sha256 → `integrity_check`）
7. 还原第 3 层（输入 GPG 密码 → 解密 → 覆盖 config.yaml → 还原 credentials）
8. 打印验证步骤与自动备份重建命令

不满意可以回滚：

```bash
rm -rf ~/.hermes
mv ~/.hermes.before-restore-<时间戳> ~/.hermes
```

## 手动恢复（如果脚本出问题）

### 1. 克隆

```bash
cd /tmp && git clone https://<user>:<TOKEN>@github.com/<user>/<repo>.git hermes-restore
cd hermes-restore
ls -A     # 应看到 skills/ memories/ scripts/ cron/ memory/ secrets/ config.yaml
```

### 2. 第 1 层：灵魂层

```bash
mkdir -p ~/.hermes
for d in skills memories scripts hooks plugins notes plans cron; do
    [ -d "/tmp/hermes-restore/$d" ] && cp -a "/tmp/hermes-restore/$d" ~/.hermes/
done
cp /tmp/hermes-restore/SOUL.md ~/.hermes/ 2>/dev/null
# config.yaml 先放脱敏版，第3层会用完整版覆盖
cp /tmp/hermes-restore/config.yaml ~/.hermes/
```

### 3. 第 2 层：会话历史

```bash
cd /tmp/hermes-restore/memory
ls -la

# 情况 A：未切片
gunzip -c state-recent60d.db.gz > ~/.hermes/state.db

# 情况 B：有切片 → 先合并
cat state-recent60d.db.gz.part-* > state-recent60d.db.gz
# 校验（对照 SLICES.md 里的 sha256）
sha256sum state-recent60d.db.gz
gunzip -c state-recent60d.db.gz > ~/.hermes/state.db
```

**必须验证**：

```bash
sqlite3 ~/.hermes/state.db "PRAGMA integrity_check;"                       # 应输出 ok
sqlite3 ~/.hermes/state.db "SELECT COUNT(*) FROM sessions;"                # 应 > 0
sqlite3 ~/.hermes/state.db "SELECT COUNT(*) FROM messages;"                # 应 > 0
sqlite3 ~/.hermes/state.db "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH '随便一个词';"
```

> ⚠️ 最后一条很关键：**数据在 ≠ 搜索可用**。FTS 索引没重建的话，前三条都正常，但搜索查不出东西。

### 4. 第 3 层：密钥

```bash
cd /tmp/hermes-restore

# 解密（会提示输入密码）
gpg --decrypt -o /tmp/secrets.tar.gz secrets/secrets.enc
# 或从密码文件读
gpg --batch --passphrase-file ~/.hermes/credentials/backup-gpg-pass \
    --decrypt -o /tmp/secrets.tar.gz secrets/secrets.enc

mkdir -p /tmp/secrets && tar xzf /tmp/secrets.tar.gz -C /tmp/secrets
ls -A /tmp/secrets
# 典型内容: .env  auth.json  config.yaml.FULL  credentials/

# 还原
cp /tmp/secrets/.env /tmp/secrets/auth.json ~/.hermes/ 2>/dev/null
cp /tmp/secrets/config.yaml.FULL ~/.hermes/config.yaml    # ← 完整版覆盖脱敏版
mkdir -p ~/.hermes/credentials
cp -a /tmp/secrets/credentials/* ~/.hermes/credentials/ 2>/dev/null
```

**注意**：一定要用 `config.yaml.FULL` 覆盖 `config.yaml`。仓库里的那个是脱敏版（密钥是 `<REDACTED>`），不覆盖的话 Hermes 起不来。

### 5. 启动验证

```bash
hermes start          # 或 systemctl --user start hermes-gateway

# 验证各项
hermes sessions list          # 应看到历史会话
ls ~/.hermes/skills           # 应看到原技能目录
hermes cron list              # 应看到定时任务
hermes doctor                 # 健康检查
```

### 6. 重建自动备份（**别忘了**）

恢复后备份链是断的，必须重建，否则下次出事就真没备份了：

```bash
# 重建 vault
mkdir -p ~/hermes-vault && cd ~/hermes-vault
git init -b main
git remote add origin https://<user>:<TOKEN>@github.com/<user>/<repo>.git
git config user.email "backup@localhost"
git config user.name "Hermes Backup"

# 重建 GPG 密码文件（如果恢复时没自动建）
mkdir -p ~/.hermes/credentials
printf '%s' '<你的GPG密码>' > ~/.hermes/credentials/backup-gpg-pass
chmod 600 ~/.hermes/credentials/backup-gpg-pass

# 重建 cron
crontab -e
```

```cron
0 4 * * * /bin/bash $HOME/.hermes/scripts/hermes-backup.sh >> $HOME/.hermes/logs/backup.log 2>&1
0 */6 * * * /bin/bash $HOME/.hermes/scripts/hermes-backup-watchdog.sh >> $HOME/.hermes/logs/watchdog.log 2>&1
```

跑一次确认：

```bash
bash ~/.hermes/scripts/hermes-backup.sh && tail -5 ~/.hermes/logs/backup.log
```

## 常见问题

**Q: 解密报 `gpg: decryption failed: Bad session key`**
密码错了。GPG 对称加密没有「提示密码错误」的友好信息，一律报这个。

**Q: `git clone` 很慢 / 卡住**
备份仓库通常 100-300MB。国内访问 GitHub 可能只有几十 KB/s，耐心等，或先只拉最新一层：
`git clone --depth 1 <url>`

**Q: `state.db` 恢复了但 Hermes 说数据库损坏**
检查是否漏了切片合并，或 `gunzip` 中途失败（对比 `SLICES.md` 的 sha256）。

**Q: 恢复后 Hermes 起不来，报配置错误**
多半是 `config.yaml` 没被完整版覆盖，密钥位还是 `<REDACTED>`。

**Q: 技能目录里有很多 `.venv` / `node_modules`？**
备份时已排除（可重建）。恢复后按需重装依赖即可。

**Q: 我只想恢复技能，不要别的**
只做第 2 步（第 1 层），跳过其余。技能是纯文本 + 脚本，独立可用。

**Q: GPG 密码丢了怎么办**
密钥层无法恢复。但灵魂层（技能/记忆/cron）和第 2 层（会话历史）**不需要密码**，照常可恢复。之后手工重填 API key 即可 —— 这也是为什么密钥单独放一层。
