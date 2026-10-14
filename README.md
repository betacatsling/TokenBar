# TokenBar

macOS 菜单栏用量工具，汇总本机和配置的 SSH 主机的 AI 用量。保留按 CLI、模型、机器查看与每日趋势。

支持 **Claude Code、Codex、Devin、pi、Gemini CLI、OpenCode、Magpie**。只读采集原始日志和数据库，不采集 API 密钥。

## 快速开始

```bash
./Scripts/build_app.sh
open dist/TokenBar.app
```

## 统计与费用

- Token 分为普通输入、输出、缓存读取、5 分钟缓存写入、1 小时缓存写入；推理 token 按各来源的语义处理，避免重复相加。
- **估算费用**按模型、提供商、缓存期限和日志中已有的计费档位计算；没有可验证费率时显示未计价。计价覆盖率仅针对已采集用量。
- **日志记录费用**单独显示。pi 等客户端记录的费用可能只是客户端估算，既不替代真实账单，也不叠加到牌价估算。
- **已导入账单**单独显示，支持订阅、网关实际扣款、工具服务费、退款等。按账单发生日期筛选，不和 token 估算相加。
- Magpie 中 CLI 转发镜像不再次加入；仅明确标记为 Magpie 自身调用的记录纳入。来源不明记录在设置中提示。
- 已采集的本机日志消失后保留历史，重新解析仍存在的日志时保留这些记录。缓存升级会重扫可用原始日志。
- 远端汇总按主机保存，离线或应用重启时仍可查看上次结果；成功刷新以远端现有日志为准，目前不能恢复远端已删除且未保存的历史。

设置中显示已知采集缺口。Codex 索引里的累计计数不是可安全相加的调用记录，不能用它补齐已删除的 rollout。Cursor、Antigravity、网页聊天及其他未接入机器的 token 仍不自动计入。

## 数据来源

| 来源 | 默认路径 | 处理方式 |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | 按消息与请求身份合并流式快照，跨文件去重，区分缓存期限 |
| Codex | `~/.codex/sessions/`、`archived_sessions/` | 新旧事件、累计重置、父会话重放、断点续扫 |
| Devin | `~/.local/share/devin/cli/sessions.db` | SQLite 只读，按请求去重，读取生成模型和真实生成时间 |
| pi | `~/.pi/agent/sessions/**/*.jsonl` | 跨文件响应去重，保留实际模型、提供商和日志费用 |
| Gemini CLI | `~/.gemini/tmp/*/chats/session-*.json` | 缓存输入不重复加入，输出加独立 thoughts |
| OpenCode | `~/.local/share/opencode/opencode.db`、旧版消息 JSON | 只读数据库与 WAL 更新，按消息身份去重 |
| Magpie | `~/.config/magpie/usage.jsonl` | 自身调用计入，CLI 镜像排除 |
| SSH 主机 | 同上 | 远端聚合，按本机时区归日，仅回传汇总 |

支持现有 `CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`PI_CODING_AGENT_DIR`、`XDG_DATA_HOME`、`GEMINI_CLI_HOME`、`MAGPIE_CONFIG_DIR` 路径设置。

## 价格与账单配置

公开价来自随应用打包的 `model_prices.json`；内置价格只补缺，不覆盖已有目录。`~/.pi/agent/models-store.json` 的网关费率按提供商匹配，避免同名模型跨网关串价。没有明确来源的模型继续标为未计价，不虚构价格。`swe-2` 的历史代理费率仍标为估算。

设置中“供应商价格”和“订阅与实际账单”的“打开文件”分别打开以下文件；首次打开创建空数组，不填入虚构金额：

- `~/Library/Application Support/TokenBar/pricing-overrides.json`
- `~/Library/Application Support/TokenBar/billing.json`

自定义费率每百万 token 计价，日期边界包含当天。以下只是格式示例，费率须替换为自己的合同值：

```json
[
  {
    "model": "your-model",
    "provider": "your-provider",
    "effectiveFrom": "2026-10-01",
    "currency": "USD",
    "price": {"input": 1, "output": 2, "cacheRead": 0.1, "cacheWrite": 1.25, "cacheWrite1h": 2}
  }
]
```

可选限定字段还有 `effectiveUntil`、`pricingTier`、`serviceTier`、`speed`、`inferenceGeo`。未提供 1 小时缓存价格时，这部分不能被当作免费。无效日期、负费率和非 USD 价格会提示。重叠规则优先匹配供应商限定、生效日期较新的规则，再取文件中靠后的规则。

账单每条需要唯一编号；可录入订阅、按量收费、服务费，退款用负数。示例金额仅演示格式：

```json
[
  {"id": "invoice-example", "date": "2026-10-01", "provider": "your-provider", "label": "订阅或实际扣款", "usd": 20}
]
```

文件保存后刷新应用。重复账单编号或无效日期会导致文件不计入，并显示原因。暂只支持美元；导入账单不代表自动对账。

## 验证

```bash
swift build -c release
python3 Scripts/test_codex_collection.py
python3 Scripts/test_additional_collection.py
python3 Scripts/test_pricing.py
.build/release/TokenBar --test-ledger
.build/release/TokenBar --test-resume
.build/release/TokenBar --test-wal-cache
.build/release/TokenBar --verify --models
python3 Scripts/verify.py --models
```

Python 校验复用生产远端采集器，固定预期的测试另外验证正确性。正在写入的日志会使两次扫描结果不同；比较应使用固定日志。诊断和测试不会启动应用的后台扫描。

```bash
dist/tokenbar --render /tmp/tokenbar.png --range all
dist/tokenbar --render /tmp/tokenbar-settings.png --settings
```

渲染使用独立设置，不修改正常应用偏好。要求 macOS 13+、Swift 5.9+；远端采集使用已有 SSH 配置。

## 历史排错记录

以下数据来自早期日志快照，数量、性能与覆盖率不能代表当前完整度；采集行为以以上说明和现有回归测试为准。

### 八个格式陷阱

这些是实测确认的，不是推测——实现时踩过：

1. **Claude Code 写的是流式递增快照，必须按 `message.id` 取最大值。**
   实测 999 个唯一 `message.id` 中 716 个有多条记录且 token 数递增（如 output `1 → 1 → 279`）。直接求和会让总量虚高 **1.71 倍**。

2. **Codex 的 `input_tokens` 已包含 `cached_input_tokens`，两者相加会重复计算。**
   实测某会话 `input=737651574`、`cached=672349696`、`output=1342576`。所以要减掉 cached 和 cache_write 再计入 input，否则本地总量虚高 **37 亿** token。
   （该会话的 `total_tokens=738994150` 比分项之和多出一点；全量看 12,400 个事件里有 1,881 个如此，多出的量随 output 变化但对不上任何一个字段。这是 Codex 侧的记账现象，本工具从不读 `total_tokens`，只累加分项，所以不受影响。）

3. **Codex 不能只读文件尾部的累计值。** 最初的实现读每个 rollout 最后 512 KB 的 `total_token_usage`，理由是「反正是会话累计值，只有最后一条有意义」。三个实测事实推翻了它（全部基于本机 476 个 rollout / 2.70 GB）：

   - **模型归属丢失**：`turn_context` 才带模型名，而 **476 个文件里有 101 个**的 `turn_context` 只出现在 512 KB 窗口之外。这些会话只能退回文件头去猜，而那里只有 `model_provider: "openai"`——是厂商不是模型。约 **49.7%** 的 token 因此落进无法计价的 `gpt-unknown`。
   - **fork 会话被重复计算**：fork / 子代理的 rollout 开头会把父会话的**全部历史抄一遍**，每行都重新打上 fork 时刻的时间戳，所以它末尾的累计值把父会话的 token 也算了进去——而父会话自己的文件已经算过一次。本机 21 个 fork 文件里这部分是 **929,578,493 token，占它们内容的 76.9%**。
   - **压缩会重置计数器**：会话超出上下文窗口后 `total_token_usage` 会从接近 0 重新开始。文件 `rollout-2026-09-05T12-43-18-01a06fe0` 跨 3 天、重置了 2 次（84,966,808 → 80,949，36,574,329 → 212,639），尾部读数只有 26.2M，实际消耗 148.9M——**单文件少算 82%**。376 个非 fork 文件里有 14 个发生过重置。

   当时改为累加每回合增量并使用时间间隔抑制重放。当前实现进一步改为按父会话事件身份识别重放，避免父会话继续增长后误扣 fork 的新增用量。两个独立检验支持这个量是对的：**376 个非 fork 文件里有 362 个**增量之和与文件末尾累计值完全相等；而且增量自带时间戳，于是用量落在**真正发生的那天**（145 个自然日），而不是全压在会话最后活跃的那天。
   代价是要读 2.70 GB 而非几 MB。靠字节级预筛 + 断点续扫把它压了回来：冷扫 13.2 s，增量刷新 **0.03 s**。

4. **Devin 的 `message_nodes` 是 DAG 不是日志，必须按 `message_id` 去重。**
   每一回合都会把整条对话链重新物化成新节点，所以一条 assistant 消息会被存下 2～7 次：`message_id` 相同、`metadata.metrics` 相同，只有 `node_id` 不同。按行累加等于把一次 API 调用收费 7 遍。

   **决定性证据是 `metadata.request_id`**：重复的那些行**共用同一个 `request_id`**。本机 1,317 组重复、server1 6,179 组重复，**两台机器合计 7,496 组，无一例外全部共用一个 request_id，token 数也全部逐字节相同**。一个 request_id 就是一次 API 调用——五行共用一个 request_id，是同一次调用被存了五份，不是五次调用。

   实测按行求和得 249,572,985，按 `message_id` 计一次得 **100,454,948**：虚高 **2.484 倍**。server1 上是 1,256,620,091 → **614,796,451**（2.044 倍，比例随对话形态而变）。

   一个实例（本机，同一个 request_id 存了 5 份）：

   ```
   node_id=22   request_id=d5afde31-…  tokens=(6126, 1181, 7490, 0)
   node_id=23   request_id=d5afde31-…  tokens=(6126, 1181, 7490, 0)
   node_id=137  request_id=d5afde31-…  tokens=(6126, 1181, 7490, 0)
   node_id=223  request_id=d5afde31-…  tokens=(6126, 1181, 7490, 0)
   node_id=309  request_id=d5afde31-…  tokens=(6126, 1181, 7490, 0)
   ```

   `--verify --models` 里 `model.swe-2` 这一行就是去重后的结果。要自己复现这个对比，跑 `Scripts/devin_compare.py`——它把两种算法的每日分项并排打出来，并统计有多少重复组共用 request_id：

   ```bash
   python3 Scripts/devin_compare.py                    # 本机
   ssh server1 'python3 -' < Scripts/devin_compare.py  # server1
   ```

5. **Devin 的两个 `created_at` 语义不同。**
   `message_nodes.created_at` 是秒级 Unix 时间戳；`sessions.created_at` 按毫秒解析会得到 1970 年。

6. **按天归类要用 `metadata.created_at`，不是行上的 `created_at`。**
   这是 DAG 那个坑的连带后果，而且更隐蔽——它不影响总量，只影响每日趋势和「今日」。

   行上的 `created_at` 是**这一行被写入的时间**。因为每回合都会把整条链重新物化一遍，一个副本的行时间戳其实是「后来某一回合」的时间，不是这次调用发生的时间。实测本机中位数晚 **80 分钟**，最多晚 **24.7 小时**——足以跨天。

   `metadata.created_at`（在 blob 里）才是消息真正生成的时间。两台机器上覆盖率都是 **100%**，而且关键性质是：**同一条消息的所有副本，这个字段完全相同**（本机 30 组、server1 1,580 组重复，无一组有分歧），而行时间戳在**每一组**里都不同。也就是说，用 blob 里的时间，归属不再取决于去重恰好留下了哪个副本；用行时间戳，每日曲线会随扫描顺序变化。

   实测错归的量：**本机 5,751,125 token（5.7%）、server1 22,653,826 token（3.7%）**。总量不变，只是在天之间搬动。

   Python 3.8 上还有个附带的坑：server1 写的是**纳秒精度**（`2026-09-12T10:40:29.383418442Z`），而 3.8 的 `fromisoformat` 只接受 3 位或 6 位小数，会直接抛异常。不截断的话 server1 上 **13,034 / 13,046** 条时间戳全部解析失败、静默退回行时间戳——正好把这个修复完全抵消掉。Swift 的 `ISO8601DateFormatter` 三种精度都能解析，已实测。

7. **Devin 的数据库是 WAL 模式，增量缓存必须把 `-wal` 一起算进缓存键。**
   这是最隐蔽的一个：新记录先写进 `sessions.db-wal`，要等到 checkpoint 才并入主文件。实测主文件在 **`49319936` 字节 / mtime `1789477882` 完全不动** 的同时，`-wal` 的 mtime 在推进，且 90 秒内出现 **3 次「主文件 stat 不变但行数已变」** 的窗口（5875→5877、5877→5878、5878→5880）。
   只按主文件的 `(inode, size, mtime)` 做缓存键，就会在这些窗口里**一直返回过期数字**。修法是把 `-wal`/`-shm`/`-journal` 的 stat 一并计入缓存键。

   回归测试（`--test-wal-cache`）用临时库构造这个场景，并断言主文件 stat 确实没变：
   去掉缓存键里的 sidecar 签名后，第二次扫描返回 `60` 而非 `150`——即真的读到了旧值，测试因此**会失败**；修复后 PASS。已验证它非空洞。

8. **Devin 的模型要取 `metadata.generation_model`，不是 `sessions.model`。**
   `sessions.model` 是会话**当前**的设置，不是某次调用实际用的模型。会话中途换模型，之前所有调用都会被追溯改写成新模型；而从没显式设过模型的会话这个字段是空字符串。

   `metadata.generation_model` 在消息 blob 里，记录的是这条消息**实际由谁生成**。实测它在两台机器上的覆盖率都是 **100%**（本机 1,342 条、server1 6,208 条有 usage 的行），所以改用它没有任何覆盖率代价。

   两者的分歧不小——本机 1,342 行里有 190 行不一致，**server1 6,208 行里有 3,354 行（54%）不一致**：

   - server1 上有两个 `model = ''` 的会话，**287,782,189 token**（占全部统计量的 0.65%）因此落进 `unknown`。这些行每一条都带 `generation_model`：`swe-2-high` 190,496,451、`swe-2-max` 97,426,112、`compactor` 1,051,855。blob 内容独立印证了这一点——这两个会话的 system prompt 就写着 *"You are powered by SWE-2 High / Max"*。
   - 本机一个标着 `swe-2-max` 的会话里，有 15,229,304 token 其实是 `swe-2-high` 生成的。

   顺带暴露出第三个模型 `compactor`（Devin 的上下文压缩模型）——它只在 `generation_model` 里出现，`sessions.model` 永远看不到。

   `swe-2-high` / `swe-2-max` 合并成一个 `swe-2`：这两者是同一个模型的不同思考强度，不是两个模型，分成两行等于把一个模型的用量拆成两个占比条。合并只按 `swe-2-` 前缀做，没有推广成「去掉结尾的 `-max`」——`gpt-5.1-codex-max` 是独立模型，有自己的公开价，通用规则会把它错误合并。

### pi 的四个字段语义（实测，56 个文件 / 726 条 usage）

以下是早期 56 文件快照，当前 pi 已需要跨文件去重，且部分日志带有非零费用：726 条 id 全不重复（不需要去重）；`totalTokens` 与 `input+output+cacheRead+cacheWrite` **726 条全部相等**（所以分项互不重叠，直接相加即可）；`reasoning` 是 `output` 的子集（9,849 vs 512,913，从不超出），所以**不另计**；`usage.cost` 恒为 0，没有厂商上报的费用可用。

唯一的坑是模型归属：要用 `responseModel`（网关实际服务的模型）而不是 `model`（请求的模型）。实测 **120 条请求 `x-preview-f-free` 实际由 `ox-alpha-free` 服务**，占 pi 用量的 10.5%。按请求名归属会按错误的模型计价，并且把这种替换完全掩盖掉。

### 断点续扫

Codex 的 rollout 在 App 运行期间还在被追加写入，所以刷新时只解析新增的字节。缓存里存的是 `(resumeOffset, guardLength, guardHash)`——偏移量，加上该偏移量之前 64 字节的 FNV-1a 指纹——再加上序列化的解析器状态（当前模型、fork 抑制标志、去重签名），这样续扫不是从空白状态开始。

两种最容易悄悄算错的情况有专门的回归测试（`--test-resume`）：
- **写到一半的最后一行**（还没有换行符）：本次刷新要算上它，但不能把偏移量推过它，否则下次扫描会再算一遍。测试断言两次结果都是 660。
- **文件被重写**（长度变了但内容不同）：guard 指纹对不上就必须整file 重扫，而不是在错误的基数上追加。

### 一个并发崩溃

`--render` 曾经偶发 **SIGSEGV（exit 139）**，崩溃栈落在 `ScanCache.buckets` 内的
`Dictionary.subscript.getter`。原因是 `AppModel.init` 自己启动了一次后台扫描，而
`--render` 紧接着又在主线程同步扫了一遍，两个线程同时改同一个 Swift `Dictionary`，
把它的存储写坏了。

修法：`ScanCache` 的所有可变状态用 `NSLock` 保护（解析放在锁外，避免长扫描阻塞读取）；
`AppModel` 增加 `autoScan` 参数，harness 传 `false` 从根上避免重叠；
`RemoteCollector.status` 是同一类问题（扫描线程写、主线程读），一并加锁。
