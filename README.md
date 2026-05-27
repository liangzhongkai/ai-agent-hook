# 先知池 · PROPHET HOOK

> *Every swap is a prophecy. The pool remembers who was right.*

A Uniswap v4 hook submission for **OKX X Layer / Uniswap / Flap — "Hook the Future" Hackathon**
([rules](https://web3.okx.com/zh-hans/xlayer/build-x-hackathon/hook)).

---

## 一句话机制

每一笔 swap 都是一份隐式的方向性预测。Hook 在每个 epoch 结束时用 **池子自身的 tick 行为**
作为真相回收答案，**猜对的交易者瓜分被猜错者掏出的费用**，并铸造一张随成绩成长的链上 SVG「先知卡」SBT。

## 为什么这是一个新机制（不是已有协议的移植）

| 维度 | 现有 Hook 流派 | 本机制 |
|---|---|---|
| 动态费率 (CodesenSys/Bunni) | 用 EWMA 算 σ 调费 | 不是「调费」，而是 **把固定费用按事后真相重新分配** |
| Bonding curve (SATO) | 用确定数学替换 AMM 曲线 | **保留 AMM**，把"预测对错"作为 **第二价值流** 叠加 |
| NFT-from-swap (uPEG) | 余额跨过整数 → 生成图像 | NFT 是 **能力履历**（命中率/连胜/夺冠），不是装饰 |
| 链上 AI (Slonks) | 把模型推理装进 hook | 把市场的 **群体智慧** 装进 hook，pool 自己就是 oracle |

核心创新点：**第一个把 prediction market 隐式嵌入 spot AMM 的 hook**——不需要单独 UI、不需要事件 oracle、不需要外部价格源。

## 项目结构

```
src/
  ProphetHook.sol      ← 核心 hook，所有 epoch / 计分 / pot 抽水逻辑
  ProphetCard.sol      ← 灵魂绑定 NFT，链上 SVG 渲染先知卡（致敬 uPEG）
  AlphaToken.sol       ← $ALPHA 治理 / 奖励代币（带 1 亿硬顶）
  AlphaStaking.sol     ← $ALPHA 质押（多币种奖励 + 计分乘数 + 抽水折扣）
  AgentRegistry.sol    ← AI Agent 注册 + 质押，注册的 agent 享受 1.00x~1.50x 计分乘数
  base/BaseHook.sol    ← v4 BaseHook 标准基类
script/
  Deploy.s.sol         ← 一键部署到 X Layer testnet / mainnet（含 HookMiner 找盐）
  Demo.s.sol           ← 本地端到端模拟：10 个 stage 看完整飞轮（详见 RUNBOOK.md）
  DeployHelpers.sol    ← 测试 / 脚本共用部署逻辑
  HookMiner.sol        ← CREATE2 地址挖矿
test/
  ProphetHook.t.sol    ← 37 项集成测试（生命周期 / 计分 / 领取 / 派发 / 70-20-10 / stake 加成）
  AlphaStaking.t.sol   ← 11 项质押 / 多币种奖励 / 折扣曲线测试
  ProphetCard.t.sol    ← SBT / SVG 渲染测试
  AlphaToken.t.sol     ← Mint / 上限 / 授权测试
  AgentRegistry.t.sol  ← 注册 / 解押 / 罚没测试
  utils/ProphetHookTestBase.sol  ← v4 Deployers 接线
```

---

## 机制详解

### 1. 累加器代替历史日志（O(1)/swap）

每笔 swap 仅触发两个 SSTORE。每个 `(pool, epoch, trader)` 维护：

```
netSize       = Σ  sign_i · |Δin_i|
weightedEntry = Σ  sign_i · |Δin_i| · tick_i
```

其中 `sign = +1`（买 token0，做多）/ `-1`（卖 token0，做空）。

### 2. Epoch 结算

epoch 结束后，任何人可调用 `settleEpoch()`，记录当前池子 tick 作为 `settledTick`。

```
score = settledTick · netSize − weightedEntry
      = Σ sign_i · |Δin_i| · (settledTick − tick_i)
```

含义：**你只在事后价格朝你预测方向走的部分得分**。完美的闭式解，O(1) 计算。

### 3. 三方分润的奖励模型（v1.5 新增）

`payoutPot` 不再 winner-takes-all，而是按 **70 / 20 / 10** 把 pot 拆给三方：

| 份额 | 去向 | 实现方式 |
|---|---|---|
| **70%** | Top Prophet | `poolManager.take` 直接打给上一 epoch 的冠军 |
| **20%** | **LPs**（所有当前在区间内的） | `poolManager.donate` → 增 `feeGrowthGlobal`，所有 in-range LP 自动按份额拿 |
| **10%** | **$ALPHA 质押者** | 转到 `AlphaStaking` 并触发 `notifyReward`，按 stake 比例累计 |

容灾：
- LP 不在区间（流动性深度=0）→ 20% 自动归入 prophet 份额（不丢失）
- 没有质押者 / 质押合约未设 → 10% 同样归入 prophet 份额
- **没有人正分** → 整池滚入下一 epoch，pot 永不卡死

这是回应「LP 总被割」痛点的关键改动：**信息劣势方（LP）从隐式被收割变成显式被补贴**，
LP 卖给「事后看是对的」交易者 → 这笔交易的 20% 又回到 LP 的 fee 增长里。

另外仍保留：
- **$ALPHA emission**：所有正分玩家按 `score/1e6`（每 epoch 单玩家 ≤1000 ALPHA）按比例铸币。

### 4. 先知卡 SBT（致敬 uPEG）

每个玩家终身一张 NFT，每次 `claim()` 累计：`totalClaims / wins / championships / streak / lifetimeScore`。

链上 SVG 渲染、tier 自动晋级：

| Tier | 条件 | 配色 |
|---|---|---|
| The Fool | 默认 | 灰 |
| The Magician | ≥3 胜 | 绿 |
| The Hierophant | ≥10 胜 | 紫 |
| The Star | ≥1 次夺冠 | 青 |
| The World | ≥5 次夺冠 | 金 |

soulbound（不可转）—— 防止刷分账号被倒卖。

### 5. AI Agent 集成（继承本项目灵魂）

`AgentRegistry` 注册的 agent，根据其 reputation 获得 **1.00× ~ 1.50× 计分乘数**：

```
multiplier = 1.00 + reputation/10000 × 0.50
```

这给了 AI agent 一个无许可的竞技场：链上、可证的预测准确率排行榜。**预测越准 → 信誉越高 → 乘数越大 → 收益越高**。

### 5.5. $ALPHA 质押的双重效用（v1.5 新增 · 让代币真的被需要）

质押 $ALPHA 到 `AlphaStaking`，立即解锁三档效用，且 **agent 乘数与 stake 乘数可叠加**：

| 效用 | 公式 | 100k ALPHA 满档 |
|---|---|---|
| **① 计分乘数** | `1.00x + min(stake, 100k)/100k × 1.00x` | **2.00x**（与 1.50x agent 乘数叠加 → 最高 3.00x） |
| **② 抽水折扣** | `discount_bps = min(stake, 100k)/100k × 5000` | swap 自己的 prophet skim **直接打 5 折** |
| **③ 分红权** | 拿 epoch pot 的 **10%**，按 stake 比例瓜分（多池多币种自动累计） | 任意时刻调 `staking.claim(currency)` 提取 |

防闪电贷：质押立刻生效但 **解押有 1 天冷却**（`requestUnstake` → 24h 后 `unstake`）。

**飞轮闭环**：
```
swap 多 → pot 多 → 质押者分红多 → 锁仓深 → 流通量小
   ↑                                        ↓
   ← 折扣 + 乘数 → 更多 trader 想拿 → 二级市场买盘
```

`$ALPHA` 因此从"治理代币"升级为「能减交易成本 + 放大收益 + 拿真金白银分红」的 **效用代币**，
飞轮的初始动能就是这 3 个用例。

### 6. 抗操纵设计

- 单 trader 单 epoch 计分仓位封顶（`PER_EPOCH_NOTIONAL_CAP = 2^96-1`）—— 防巨鲸
- `MIN_SIZE_TO_COUNT = 1000` —— 过滤 dust 刷分
- pot 派发设 `CLAIM_WINDOW_EPOCHS = 1` 宽限期 —— 让更高分玩家有机会反超
- 完全不可变 / 无 admin 路径修改历史 score —— 只有 oracle/registry 切换等参数级开关
- 若无人正分：pot 自动滚入下一 epoch，**保证 pot 永远不被锁死**

---

## Hook 权限

```
beforeInitialize | afterInitialize | beforeSwap | afterSwap | beforeSwapReturnDelta
```

地址需含上述 5 位 flag。`HookMiner` 已为 X Layer testnet 配好 CREATE2 挖矿。

---

## 部署到 X Layer

```bash
# 必要变量
export PRIVATE_KEY=0x...
export POOL_MANAGER=0xA0B4c6737C0D4942A353368AD86eBbf24503Fbba   # 可选，覆盖默认值

# 测试网
forge script script/Deploy.s.sol:DeployXLayer \
  --rpc-url xlayer_testnet --broadcast -vvvv

# 主网
forge script script/Deploy.s.sol:DeployXLayer \
  --rpc-url xlayer_mainnet --broadcast -vvvv
```

部署完成后初始化新池子的标准三步：

```solidity
// 1) 注册 epoch 长度 / 抽水比 / LP 基准费率（一次性，仅可设一次）
hook.configurePool(key, 1024, 50, 2500);   // 1024 block / 0.50% / LP 0.25%

// 2) 用 dynamic fee 标志初始化池子（fee 必须设为 LPFeeLibrary.DYNAMIC_FEE_FLAG）
poolManager.initialize(key, SQRT_PRICE_1_1);

// 3) 添加流动性，开局！
poolManager.modifyLiquidity(key, params, "");
```

---

## 本地开发

```bash
# 编译
forge build

# 跑测试（73 项）
forge test -vv

# 跑某一测试
forge test --match-test test_claim_correctDirection_yieldsPositiveScore -vvvv

# 在内存里把整个飞轮跑一遍（部署 → swap → settle → claim → 70/20/10 → staker 提取）
forge script script/Demo.s.sol:Demo -vv
```

> 完整手动验证 / 测试网部署 / cast 交互步骤详见 **[RUNBOOK.md](./RUNBOOK.md)**。

## X Layer 网络配置

| 参数 | 值 |
|---|---|
| 网络名称 | X Layer Testnet |
| RPC URL | https://testrpc.xlayer.tech |
| Chain ID | 195 |
| 货币符号 | OKB |
| 区块浏览器 | https://www.okx.com/explorer/xlayer-test |
| Faucet | https://web3.okx.com/zh-hans/xlayer/faucet |

主网 RPC：`https://rpc.xlayer.tech`

---

## 与 SATO / uPEG / Slonks 的对照

| | SATO | uPEG | Slonks | **Prophet** |
|---|---|---|---|---|
| 切入点 | 替换 AMM 曲线 | afterSwap → SVG mint | hook 内 AI 推理 | beforeSwap 累加器 + skim |
| 新资产 | sato 代币 | unicorn NFT | slonk NFT + $SLOP | Prophet Card SBT + $ALPHA |
| Truth source | 数学公式 | 交易 fingerprint | 模型权重 | **池子的下一段 tick** |
| Admin 风险 | 无 | 无 | 无 | 仅有可替换组件指针，不能修改任何 epoch 历史 |
| Memetic | "数字稀缺" | "链上独角兽" | "AI 残次品" | "每笔 swap 都是一份预言" |

---

## 路线图（赛事后）

- **TWAP settlement**：将 `settleEpoch` 改为最近 N 个 block 的 TWAP，进一步抗操纵
- **Prophet Pass NFT 二级市场**：放开 SBT 的「委托使用权」让排行榜可被订阅
- **Cross-pool prophets**：单卡积累跨多个池子的成绩
- **Agent battle rooms**：开放只允许注册 agent 参与的 high-stakes 池子，AI agent vs AI agent
- **$ALPHA buyback-burn**：把 staker 份额自动 swap 成 $ALPHA 再 burn，让通缩飞轮起步
- **veALPHA / 锁仓加权**：解押冷却升级为 1m~4y 锁仓，时间越长乘数越高

---

## License

代码：BUSL-1.1（hook 核心）/ MIT（周边）

提交：5 月 28 日 23:59 UTC 前通过 OKX 官方 Google Form。

**Tag：`@XLayerOfficial` `@Uniswap` `@flapdotsh`**
