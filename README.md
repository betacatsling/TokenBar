# TokenBar

macOS 菜单栏 Token 统计工具。点击菜单栏图标弹出面板，一屏看清**本机**和 **server1** 上各个 AI CLI 的 token 消耗与费用估算。

支持 4 个 CLI：**Claude Code**、**Codex CLI**、**Devin CLI**、**pi**。

## 快速开始

```bash
./Scripts/build_app.sh     # 构建
open dist/TokenBar.app     # 启动（菜单栏出现图标）
```

首次启动会全量扫描一次（约 15 秒，因为 Codex 日志有 2.7 GB），之后走增量缓存，刷新在 0.6 秒内。

## 面板说明

```
┌────────────────────────────────────────┐
│ [ 今日 | 7 天 | 30 天 | 全部 ]         │  ← 时间范围，作用于下面所有内容
│                                        │
│ 今日用量                      估算费用 │
│ 153.9M tokens                   ≈ $133 │  ← 总量 + 费用估算
│ 153,860,915  82% 已计价 · 46% 估算费率 │  ← 精确值 + 计价覆盖率
│                                        │
│ 近 14 天                   日均 103.0M │
│ ▂ ▂ ▃ ▁ ▁ ▁ ▂ ▁ ▂ ▁ ▁ █ █ ▄            │  ← 每天按 CLI 堆叠，悬停看当天明细
│ 9/13                              今天 │     浅色底带 = 当前时间范围覆盖的天
│ ● Claude  ● Codex  ● Devin  ● pi       │
├────────────────────────────────────────┤
│ [ 按 CLI | 按模型 | 按机器 ]           │  ← 三种视角
│ ● Devin CLI 46%      71.3M  $34.05+~ › │  ← 颜色与趋势图一致，点击展开模型
│   ████████████                         │     + = 部分无公开价，~ = 推算费率
│ ● pi 45%             69.5M  $73.65+  › │
│   ███████████                          │
│ ● Claude Code 5%      7.7M  无公开价 › │  ← 没有价格就说没有，不写 $0
│   █                                    │
├────────────────────────────────────────┤
│ 更新于 刚刚 · 含 server1       ⟳  ⚙  ⏻ │  ← 状态；刷新 / 设置 / 退出
└────────────────────────────────────────┘
```

- **三个标签页**：`按 CLI`（点击行展开该 CLI 的模型明细）、`按模型`（全部模型跨 CLI 合并，按用量排序）、`按机器`（本机 vs server1）。百分比是占当前时间范围总量的份额。
- **每个 CLI 的颜色固定**，趋势图、图例、列表圆点和占比条用的是同一个颜色；这组颜色在浅色和深色外观下都跑过色盲安全校验。
- **⟳** 走增量缓存刷新（本机部分约 0.5 秒），并强制重新拉取一次 server1；要从头全量重扫，去 **⚙** 里点「清空缓存并重扫」。
- **⚙** 里还可以关闭 server1 统计、修改主机名、切换是否计入子代理、调整自动刷新间隔。
- server1 连不上时，面板上会出现一条带图标的提示，说明显示的是上次结果还是本次未统计。
- 菜单栏显示今日用量（可在设置里关掉，关掉后只显示图标）。

## 关于费用估算

费用一律带 `≈` 前缀，**这是估算而非账单**：它算的是按公开牌价这些请求*本该*花多少，而订阅制和折扣网关的实际账单并非如此。

价格表分三层合并，越靠后优先级越高：

1. `Resources/model_prices.json`——LiteLLM 价目表的精简快照（4,147 个模型，含 990 个无歧义的裸名别名），也是 `ccusage` 用的同一张表。内置而非联网拉取：本工具要能离线工作，且同样的输入要给出同样的答案。用 `Scripts/refresh_prices.py` 更新。
2. `~/.pi/agent/models-store.json`——用户网关里配置的真实价格。`glm-5.3`、`kimi-k3`、`qwen3.8-max` 只有这一个来源，公开表里完全没有。
3. 内置的第一方价格，防止外部表的错误条目影响主要模型。

**没有价格就明说没有，而不是记 0**。如果显示 `$0`，几千万 token 看起来就像免费的；面板上这类模型标「无公开价」，只计价了一部分的行标 `+` 表示这是下限。目前 95% 的 token 有价格。

**推算来的费率单独标 `~`**。Devin 的 `swe-2` 没有任何公开定价，但它是由 kimi-k3 后训练而来，所以按 kimi-k3 的费率（3 / 15 / 0.3 / 0）估算。这个费率有两个独立来源相互印证：`~/.pi/agent/models-store.json` 里 `kimi-k3` 在两个 provider 下都是这个数，LiteLLM 的 `moonshot/kimi-k3` 也是 3 / 15 / 0.3。

推算和公开价在 UI 上**不混为一谈**：这类行标 `~`，总计卡片写「2% 估算费率」。这个数字只说明「这些 token 按 kimi-k3 的价算是多少」，不多不少——swe-2 真实怎么计费仍然是未知的。代码里写死而不是运行时去查 `kimi-k3`：链式查找会让 pi 的 store 一被改动就悄悄改变 swe-2 的费用。

Devin 的 `compactor`（上下文压缩模型）没有列入推算——它和任何已定价模型都没有公开的关系，所以保持「无公开价」，占 Devin 本机 token 的 0.06%。

查找是**精确匹配**（小写化、去掉 `[1m]` 之类的变体后缀、再试 `provider/` 前缀之后的裸名）。曾经用的最长前缀匹配有 bug：`gpt-5` 会匹配上 `gpt-5.6-sol`，按错误的代次计价。

## 数据来源

全部**只读**扫描，不修改任何 CLI 的日志。

| CLI | 路径 | 解析方式 |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | 按 `message.id` 取最大值去重 |
| Codex CLI | `~/.codex/sessions/` + `archived_sessions/` | 全量解析每回合增量，可断点续扫 |
| Devin CLI | `~/.local/share/devin/cli/sessions.db` | SQLite 只读 URI，按 `message_id` 去重，模型取 `generation_model`，按天用 `metadata.created_at` |
| pi | `~/.pi/agent/sessions/*/*.jsonl` | 直接累加 |
| server1 | 同上（远端） | SSH 远端聚合 |

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

   现在改为累加每回合的 `last_token_usage` 增量，丢弃连续重复，并按 **1 秒间隔**（`ccusage` 用的同一阈值）抑制开头那串抄来的记录。两个独立检验支持这个量是对的：**376 个非 fork 文件里有 362 个**增量之和与文件末尾累计值完全相等；而且增量自带时间戳，于是用量落在**真正发生的那天**（145 个自然日），而不是全压在会话最后活跃的那天。
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

pi 是四个里最干净的，但结论是验证出来的而不是假设的：726 条 id 全不重复（不需要去重）；`totalTokens` 与 `input+output+cacheRead+cacheWrite` **726 条全部相等**（所以分项互不重叠，直接相加即可）；`reasoning` 是 `output` 的子集（9,849 vs 512,913，从不超出），所以**不另计**；`usage.cost` 恒为 0，没有厂商上报的费用可用。

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


## 验证

两套独立实现交叉比对——Swift 采集器与 `Scripts/verify.py` 分开编写（Python 那份是照着磁盘格式重写的，不是从 Swift 翻译过来的，否则同样的错会犯两遍），两者一致才有意义。两边输出同样的 `key: value` 行，可直接 diff。

```bash
dist/tokenbar --verify           # Swift 实现，冷扫描
dist/tokenbar --verify --warm    # 走缓存，测增量性能
dist/tokenbar --verify --models  # 加上逐模型总量
python3 Scripts/verify.py --models   # 独立的 Python 参照实现
```

实测结果（本机，2026-09-16，两轮背靠背运行）：

| 数据源 | Swift | Python 参照 |
|---|---|---|
| claude-code | 169,244,438 | 169,244,438 ✓ |
| codex | 4,283,002,276 | 4,283,002,276 ✓ |
| devin | 100,454,948 | 100,454,948 ✓ |
| pi | 70,324,337 | 70,324,337 ✓ |
| **合计** | **4,623,025,999** | **4,623,025,999 ✓** |

逐键 diff：**45/45 个键完全一致**（4 个 `cli.*` + 14 个 `day.*` + **26 个 `model.*`** + `total_tokens`）。

`model.*` 是后加的：模型归属在 `cli.*` 和 `day.*` 里完全看不出来，而归属恰恰是最容易错的地方（陷阱 8 那个 2.88 亿 token 的 `unknown` 就是归属错误，不是数量错误）。不把逐模型总量纳入 diff，这类 bug 就是交叉验证的盲区。

第三份实现 `remote_collect.py` 对着本机数据跑，同样复现 devin 100,454,948（`swe-2` 100,393,421 / `compactor` 61,527）。

Claude Code 的去重比率：朴素求和 313,435,468 vs 去重后 174,775,856 = **1.793×**（`--verify` 每次都会打出这三行；日志在持续写入，绝对值会变，比例稳定在 1.7～1.8）。

> 这些数字在变动：本机的 Devin / Claude Code 正在持续写入。上表是某一瞬间的快照，逐字段一致才是有意义的信号。

性能（2.7 GB Codex 日志 + 530 MB Claude 日志，release 构建）：

| | 冷扫描 | 增量刷新 |
|---|---|---|
| Codex（2.70 GB） | 13.2 s | **0.03 s** |
| 全部四个 CLI | 15.0 s | **0.53 s** |

改成全量解析后冷扫描比原来的尾部读取慢（约 10 s → 15 s），这是换取正确性的代价；日常走的增量路径反而更快。

其他验证开关：

```bash
dist/tokenbar --test-wal-cache                 # WAL 缓存键回归测试（见陷阱 6）
dist/tokenbar --test-resume                    # 断点续扫回归测试
dist/tokenbar --render out.png --range today   # 渲染面板为 PNG，便于检查布局
dist/tokenbar --render out.png --tab model     # 渲染指定标签页
dist/tokenbar --render out.png --dark          # 深色外观
dist/tokenbar --render out.png --expand codex  # 展开某个 CLI 的模型明细
dist/tokenbar --render out.png --settings      # 渲染设置面板
dist/tokenbar --render out.png --host bogus    # 验证 server1 离线降级
python3 Scripts/refresh_prices.py --dry-run    # 看价格表会怎么变，不写文件
```

`--render` 使用独立的 UserDefaults suite，不会污染真实配置。

## server1 采集

通过 SSH 把 `remote_collect.py` 从 stdin 喂给远端 `python3` 执行，**只回传聚合后的 JSON**（约 43 KB），不传 530 MB 原始日志。不在服务器上安装任何常驻服务。

利用 `~/.ssh/config` 里已有的 `ControlMaster` 复用连接。远端结果缓存 10 分钟；SSH 不通时面板显示「server1 离线」并保留上次结果，不会卡死。

## 项目结构

```
Sources/TokenBar/
  TokenBarApp.swift          @main，MenuBarExtra
  AppModel.swift             扫描调度与发布
  Verify.swift               --verify / --render / --test-* 诊断
  Core/
    UsageRecord.swift        统一数据模型
    Aggregator.swift         分组、区间过滤、快照
    Pricing.swift            三层价格表与费用估算
    ScanCache.swift          流式行读取 + 断点续扫缓存
    Settings.swift           偏好设置
    Formatting.swift         数字格式化
  Collectors/                四个本地 + 一个远端
  Views/                     面板（三个标签页）、设置、趋势图、配色与共享样式
  Resources/
    remote_collect.py        推送到 server1 执行
    model_prices.json        LiteLLM 价目表快照
Scripts/
  build_app.sh               构建 .app
  verify.py                  独立参照实现
  devin_compare.py           Devin 去重前后对比 + request_id 证据
  refresh_prices.py          更新价目表快照
```

## 环境要求

- macOS 13+
- Swift 5.9+（**只需 Command Line Tools，无需安装 Xcode**）
- server1 统计需要 `~/.ssh/config` 中配好免密登录

## 已知限制

- **费用是估算。** 见上文；目前 95% 的 token 有公开价格。`swe-2` 按 kimi-k3 费率推算并标 `~`；其余（`gpt-reserve`、`gpt-5.3-codex-spark`、Devin 的 `compactor` 等）标注为「无公开价」而不是计 0。
- **Devin 的每日归属依赖 `metadata.created_at`。** 这个字段目前 100% 存在；万一某天缺失，该行会退回行上的 `created_at`，那条记录就可能落在晚几小时的那一天（总量不受影响）。
- **Codex 在一次回合内切换模型时，该回合归给切换后的模型。** 归属来自最近一条 `turn_context`，这是日志里能拿到的最细粒度。
- **本机日志正在被实时写入**，所以两次运行的数字天然会有差异。判断实现是否正确要看两套独立实现的**逐字段一致性**，而不是某个绝对值。
- `--verify` 默认冷扫描以得到可复现的数字；加 `--warm` 走缓存。
