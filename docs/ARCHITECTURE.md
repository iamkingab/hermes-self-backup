# 设计说明与踩坑记录

这份文档记录「为什么这么设计」以及**实际踩过的坑**。写给未来的维护者（包括我自己）。

## 核心问题

Hermes 这类 Agent 的「自我」存在于多个地方：

```
~/.hermes/
├── skills/         ← 能力（长期积累，最不可替代）
├── memories/       ← 用户偏好、环境事实
├── state.db        ← 全部会话历史（含上下文、决策过程）
├── cron/jobs.json  ← 定时任务定义
├── scripts/        ← 自建运维脚本
└── config.yaml     ← 服务商/渠道/密钥配置
```

难点在于**体积**与**安全**互相拉扯：

- 全量 4.5GB，直接进 Git 不可能（单文件 100MB 限制）
- 但密钥必须进备份，否则恢复后要手工重填几十个 key
- 密钥又不能明文进仓库（GitHub 私有仓库也不安全，token 泄漏/误转公开）

→ 解法是**分层 + 差异化处理**：小而关键的不加密进版本控制，大而可重建的排除，敏感的单向加密。

## 三个关键决策

### 1. 为什么密钥要加密进仓库，而不是「恢复时手填」

早期方案是「config.yaml 只存占位符，密钥恢复时手工填」。但实际环境里：

- 一个 Hermes 可能配了 10+ 个服务商、20+ 个渠道
- 各类 token（GitHub / 飞书 / 云厂商 / 邮件 / 网盘）分散在不同文件
- 真出事时（服务器突然挂），你**根本没有那份清单**

→ 结论：密钥必须一起备份，用对称加密保护。GPG AES-256 + 用户自持密码，GitHub 只看到密文。

### 2. 为什么不用 age/openssl，用 GPG

- `gpg --symmetric` 一行搞定，无需管理密钥对
- `--passphrase-file` 天然支持脚本非交互
- 所有 Linux 发行版自带
- 解密回验（加密后立刻解一遍比对）很方便

### 3. 为什么切片是 90MB 而不是 95MB

GitHub 单文件硬限制 **100MB**（超过直接拒收整个 push），推荐上限 **50MB**。
gzip 后的大小会有波动，90MB 留了安全余量且减少切片数。

必须生成 `SLICES.md` 记录每片 sha256 —— 否则恢复时**无法验证是否损坏**，而损坏的数据库往往还能「打开」，只是数据缺失，极难发现。

## 踩坑记录

### 坑 1：假成功（最危险）

**现象**：日志显示

```
[..] 【第2层】导出近60天会话历史...
   ✓ 会话历史已导出压缩: 4.0K
[..]   ✓ 未切片，已记录校验和
```

一切正常的样子。但实际 `state.db` 导出**失败了**，python 抛了异常，产物是个空 gzip。

**根因**两层叠加：

1. heredoc 里 `python3 ... <<'PYEOF'` 的**退出码没被检查**，后续命令照常执行
2. 判断条件是 `if [ -s "$SQLITE_TMP" ]`（文件非空），空库也是「非空」

**教训**：任何「临时文件非空即成功」的判断都不可靠。必须
① 检查退出码 ② 检查内容语义（`SELECT COUNT(*)` > 0）③ 把计数打进日志。

**通用原则**：日志里出现「看起来太大/太小的数字」（4.0K 对于一个有几百会话的库）时，**必须停下来追究**。那个数字就是警报。

### 坑 2：schema 跨版本漂移

老版 Hermes：`sessions` 表有 `last_activity_at`
新版 Hermes：只有 `started_at` / `ended_at`

```sql
-- ❌ 在新库上直接报 no such column
SELECT id FROM sessions WHERE COALESCE(last_activity_at, started_at, 0) >= ?

-- ✅ 动态探测
_icols = [c[1] for c in s.execute('PRAGMA table_info(sessions)')]
_tc = [c for c in ('last_activity_at','started_at','ended_at') if c in _icols]
_texpr = "COALESCE(" + ", ".join(_tc) + ", 0)"
```

**关键认知**：`COALESCE` **不会**跳过不存在的列 —— 它在 SQL 编译期就失败了，不是运行时取「下一个非 NULL」。

这个坑和坑 1 是**叠加**的：schema 漂移导致导出崩溃，崩溃又被假成功掩盖。两个 bug 互相掩护，日志全绿。

### 坑 3：FTS 索引不重建 → 静默失效

Hermes 的全文搜索用 FTS5：

- `messages_fts`（标准分词）
- `messages_fts_trigram`（子串匹配，依赖一个 **视图** `messages_fts_trigram_src`）

复制时必须按顺序：

1. 先建虚拟表（`CREATE VIRTUAL TABLE ...`）—— 必须最先，否则后续触发器报错
2. 再建视图 —— trigram 依赖它
3. 复制普通表结构 —— **跳过** `messages_fts*` 影子表（自动生成）
4. 复制索引/触发器
5. 最后 `INSERT INTO messages_fts(messages_fts) VALUES('rebuild')`

用 `sqlite_master.sql LIKE 'CREATE VIRTUAL%'` 判断虚拟表，**不能**用 `name NOT LIKE 'messages_fts%'`（会把虚拟表本身也过滤掉）。

漏做第 5 步的后果：数据都在，但**搜索查不出任何东西**。这种「部分失效」比全失败更危险。

### 坑 4：多跳 SSH 忘转发 agent

```
本机 → 跳板 → 目标机
```

第二跳报 `Permission denied (publickey)`。错误信息看起来像「目标机没配我的公钥」，实际是**本地 agent 没转发**，跳板上没有可用密钥。

```bash
eval "$(ssh-agent -s)"; ssh-add ~/.ssh/id_ed25519
ssh -A jump 'ssh -A user@target "cmd"'     # ← 两个 -A，缺一不可
```

**排查建议**：看到 `Permission denied (publickey)` 先别改对端的 `authorized_keys`，先确认本地 agent 有密钥（`ssh-add -l`）。

### 坑 5：链路抖动被误判为故障

国内家宽 / 跨境链路常见：`Connection timed out during banner exchange`（rc=255）、命令超时（rc=124）。

**第一次失败不代表故障**。必须包重试（3-5 次，间隔 6-10s）再下结论。否则会误判成「对端服务挂了」，浪费大量时间排查不存在的问题。

### 坑 6：巨型 heredoc 被安全拦截

```bash
ssh host 'bash -s' <<'EOF'
  ...几百行...
EOF
```

会被命令解析器判定为可疑载荷而阻止。

**正确做法**：本地 `write_file` → `scp` → `ssh host 'bash /tmp/x.sh'`。

### 坑 7：git remote 的真相

脚本里声明了 `REPO="user/repo"` 但**从未使用** —— 实际推送靠 vault 目录自己的 `.git/config` remote。

风险：如果哪天用 `$REPO` 重建 remote，会把 A 机器的备份推进 B 机器的仓库，**互相覆盖**。

**建议**：要么真的用它（每次 push 前 `git remote set-url`），要么删掉这个变量避免误导。

## 多机部署

一台机器一个仓库：

| 机器 | 仓库 | 备份时间 |
|---|---|---|
| A | `hermes-backup-a` | 04:00 |
| B | `hermes-backup-b` | 04:30 |
| C | `hermes-backup-c` | 05:00 |

原因：
- 不同机器的 `config.yaml` / `state.db` / `cron/jobs.json` 完全不通用，混在一个仓库会互相覆盖
- 时间错开避免同时上传挤带宽

**远程代办优于「把文档发给对方」**：如果机器间有免密 SSH，从一台远程操作其他机器，能保证行为绝对一致（同一份脚本），且避免脚本在两个环境里产生行为差异。

## 看门狗设计原则：零假警报

告警系统最大的失败模式不是「漏报」，而是**因为误报太多被忽略**。

所以看门狗：

- 正常时 **完全静默**（无输出，cron 自然不发消息）
- 只在**确凿证据**下才输出：上次成功时间戳过期 / vault 丢失 / 日志有失败标记 / 远程 `pushed_at` 停滞 / 会话历史文件异常小
- **不**做「猜测性告警」（如「网络看起来慢」）

阈值保守：备份每天一次，30 小时没成功才算异常（容忍一次失败+重试）。
