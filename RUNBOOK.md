# RUNBOOK · 手动跑通全部流程

从「我刚 clone 下来」到「testnet 上完整跑了一轮 prophet 飞轮」的全部命令。
所有命令都可手动复制执行，无需任何外部 UI。

---

## 0. 前置依赖

```bash
# Foundry（如未安装）
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc        # 或 ~/.zshrc
foundryup

# clone 后第一步：拉子模块
git submodule update --init --recursive

# 验证 toolchain
forge --version         # ≥ 0.2.0
cast  --version
anvil --version
```

---

## Level 1 · 本地单测（30 秒）

```bash
# 编译全量
forge build

# 跑全部 56 项测试
forge test

# 看每条 setup/log（含 console.log）
forge test -vv

# 跑单个测试（trace 模式）
forge test --match-test test_payoutPot_splits_70_20_10 -vvvv

# 按 suite 跑
forge test --match-contract AlphaStakingTest -vv

# gas 报告
forge test --gas-report

# 覆盖率（先装 lcov）
forge coverage
```

期望输出：

```
Ran 4 test suites: 56 tests passed, 0 failed, 0 skipped
```

4 个 suite 分别是 `AlphaToken / ProphetCard / AlphaStaking / ProphetHook`。

---

## Level 2 · 本地端到端模拟（最推荐 · 5 秒看完整个飞轮）

这是最方便看「全流程」的方法 —— 一条命令在内存里跑完 10 个 stage：
**部署 → 配池 → 加流动性 → carol 质押 ALPHA → 多 trader swap → 结算 → claim → 70/20/10 派发 → staker 提取**。

```bash
forge script script/Demo.s.sol:Demo -vv
```

期望输出（节选）：

```
===== STAGE 5: carol mints + stakes 50,000 ALPHA (50% boost, 25% skim discount) =====
  Carol staked ALPHA : 50000
  Carol scoreMultBps : 15000
  Carol skimDiscount : 2500

===== STAGE 6: alice/bob/carol swap (recording predictions) =====
  alice swapped zeroForOne -5M (bets tick will DROP)
  bob   swapped zeroForOne -3M (same bet)
  carol swapped oneForZero -2M (opposite bet, but boosted)
  epoch 0 pot0 (skim accumulated): 40000      ← 5M+3M = 8M × 0.50% = 40000
  epoch 0 pot1 (skim accumulated): 7500       ← carol: 2M × 0.50% × 0.75 = 7500 (含 25% 折扣)

===== STAGE 8: each trader claims & is scored =====
  alice score : 5000000
  bob   score : 0                              ← 同向但仓位小，进入头部前被结算
  Top prophet : 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7   (alice)

===== STAGE 9: roll past claim window + payoutPot (70 / 20 / 10) =====
  Pot c0   : 40000
    -> top prophet (70%) : 28000     ← alice 拿到
    -> LPs (donate, 20%) : 8000      ← donate 进了 LP 池子
    -> stakers (10%)     : 4000      ← 进了 staking 合约

===== STAGE 10: carol claims her staker share =====
  Carol claimed currency0 : 4000   ← 唯一 staker → 拿走全部 10% 份额
  Carol claimed currency1 : 750
```

如果你要在 `Demo.s.sol` 里改参数（更多 trader、不同 skim、不同 stake），直接编辑然后再跑一次即可。

---

## Level 3 · 本地 Anvil + cast 手动交互

如果你想用 `cast send` 一条一条手动发交易（更贴近 testnet 体验）：

### 3.1 启动 Anvil + 部署

```bash
# 终端 A：起 Anvil（出块、预置 10 个富账户）
anvil --block-time 1

# 终端 B：用 Anvil 的 0 号私钥部署
export ANVIL_RPC=http://localhost:8545
export DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export DEPLOYER_ADDR=0xf39Fd6e51aad88F6F4ce6aB8827279cfFFb92266

# 部署 Prophet 全栈（先得部署一个 PoolManager 占位）
# 简化做法：直接跑 Demo 但带 --broadcast，把所有地址刻在链上
# 注：vm.roll 在 --broadcast 模式不会实际推进 Anvil 区块，所以 settle/payout 会失败；
#     若你只要部署的地址，可以用下面这条「只部署」的简化命令：
forge script script/Demo.s.sol:Demo \
  --rpc-url $ANVIL_RPC --broadcast \
  --private-key $DEPLOYER_KEY -vv 2>&1 | grep -E "(PoolManager|token|AlphaToken|Staking|ProphetHook|Registry|ProphetCard) :"
```

⚠️ 因为 `Demo.s.sol` 中使用了 `vm.roll`（仅作用于本地模拟，不会真正给 Anvil 出块），
所以 broadcast 模式下 stage 7/9 会因为 epoch 没到期而 revert。
**Level 3 真要手跑全流程，推荐用下面这个分阶段套路：**

### 3.2 分阶段手动跑

下面假设你已经手动用 `cast` 或自己的脚本部署好了 PoolManager 与 Prophet 全栈，
并把地址放进环境变量（举例值仅占位）：

```bash
export PM=0xPoolManager...
export HOOK=0xProphetHook...
export ALPHA=0xAlphaToken...
export STAKING=0xAlphaStaking...
export TOKEN0=0x...
export TOKEN1=0x...
export TICK_SPACING=60
export DYNAMIC_FEE=0x800000   # LPFeeLibrary.DYNAMIC_FEE_FLAG = 1<<23
export EPOCH=64
export SKIM=50                  # 0.50%
export BASE_LP=2500             # 0.25%
```

完整一轮的命令链：

```bash
# 1) 配池
cast send $HOOK \
  "configurePool((address,address,uint24,int24,address),uint32,uint16,uint24)" \
  "($TOKEN0,$TOKEN1,$DYNAMIC_FEE,$TICK_SPACING,$HOOK)" $EPOCH $SKIM $BASE_LP \
  --rpc-url $ANVIL_RPC --private-key $DEPLOYER_KEY

# 2) 初始化池子（sqrtPriceX96 = 1:1）
cast send $PM \
  "initialize((address,address,uint24,int24,address),uint160)" \
  "($TOKEN0,$TOKEN1,$DYNAMIC_FEE,$TICK_SPACING,$HOOK)" \
  79228162514264337593543950336 \
  --rpc-url $ANVIL_RPC --private-key $DEPLOYER_KEY

# 3) 加流动性（通过 PoolModifyLiquidityTest 路由器，自己部署一个或复用 v4-core/test 里的）
#    略 — 推荐直接 fork Demo.s.sol 的 stage4

# 4) Alice 做一笔 zeroForOne swap（通过 PoolSwapTest 路由器）
#    略 — 同上

# 5) 把链推到 epoch 终点
cast rpc anvil_mine $((EPOCH + 1)) 0 --rpc-url $ANVIL_RPC

# 6) 结算 epoch 0
cast send $HOOK "settleEpoch((address,address,uint24,int24,address),uint64)" \
  "($TOKEN0,$TOKEN1,$DYNAMIC_FEE,$TICK_SPACING,$HOOK)" 0 \
  --rpc-url $ANVIL_RPC --private-key $DEPLOYER_KEY

# 7) Alice 领分数
cast send $HOOK "claim((address,address,uint24,int24,address),uint64,address)" \
  "($TOKEN0,$TOKEN1,$DYNAMIC_FEE,$TICK_SPACING,$HOOK)" 0 $ALICE_ADDR \
  --rpc-url $ANVIL_RPC --private-key $DEPLOYER_KEY

# 8) 推到 claim 窗口外
cast rpc anvil_mine $((EPOCH + 1)) 0 --rpc-url $ANVIL_RPC

# 9) 派发 pot（70/20/10）
cast send $HOOK "payoutPot((address,address,uint24,int24,address),uint64)" \
  "($TOKEN0,$TOKEN1,$DYNAMIC_FEE,$TICK_SPACING,$HOOK)" 0 \
  --rpc-url $ANVIL_RPC --private-key $DEPLOYER_KEY

# 10) Staker 提取自己份额
cast send $STAKING "claim(address)" $TOKEN0 \
  --rpc-url $ANVIL_RPC --private-key $CAROL_KEY
```

每步都可以用 `cast call $HOOK "getEpochInfo(...)"` 查状态。

---

## Level 4 · 部署到 X Layer Testnet

### 4.1 准备账户

```bash
# 生成一个新钱包（如果还没有）
cast wallet new
# 输出：private key、address

export PRIVATE_KEY=0x<你的私钥>
export ADDR=$(cast wallet address --private-key $PRIVATE_KEY)
echo $ADDR
```

### 4.2 领 OKB（gas token）

打开 https://web3.okx.com/zh-hans/xlayer/faucet ，粘贴 `$ADDR` 领测试网 OKB。
通常 1 OKB 就够把整个 stack 部署 + 跑十几次 swap。

```bash
# 等几秒后查余额
cast balance $ADDR --rpc-url xlayer_testnet
```

### 4.3 找到 v4 PoolManager 地址

X Layer testnet 的 PoolManager 地址，请以 [Uniswap v4 官方 deployments](https://docs.uniswap.org/contracts/v4/deployments)
或 X Layer 官方 hackathon 页 [文档](https://web3.okx.com/zh-hans/xlayer/build-x-hackathon/hook) 公布的为准。
默认值已写在 `script/Deploy.s.sol` 里：

```solidity
address constant DEFAULT_POOL_MANAGER = 0xA0B4c6737C0D4942A353368AD86eBbf24503Fbba;
```

若有变动，覆盖：

```bash
export POOL_MANAGER=0x<最新的 PoolManager 地址>
```

### 4.4 一键部署 Prophet 全栈

```bash
forge script script/Deploy.s.sol:DeployXLayer \
  --rpc-url xlayer_testnet \
  --broadcast \
  --slow \
  -vvvv
```

执行成功后，控制台尾部会打印（举例）：

```
PoolManager:      0xA0B4c6737C0D4942A353368AD86eBbf24503Fbba
AlphaToken:       0x1111...
ProphetCard:      0x3333...
AlphaStaking:     0x4444...
ProphetHook:      0xfFff...00C8        ← 末位匹配 hook flags
Hook flags (hex): 0xc8
```

把这些写入新的 env：

```bash
export ALPHA=0x1111...
export CARD=0x3333...
export STAKING=0x4444...
export HOOK=0xfFff...00C8
export PM=0xA0B4c6737C0D4942A353368AD86eBbf24503Fbba
```

部署后**所有角色已自动接好**：
- `AlphaToken.minter = HOOK`
- `ProphetCard.recorder = HOOK`
- `AlphaStaking.notifier = HOOK`
- `ProphetHook.alphaStaking = STAKING`

不需要额外的 admin 配置。

### 4.5 浏览器验证

```bash
echo "https://www.okx.com/web3/explorer/xlayer-test/address/$HOOK"
echo "https://www.okx.com/web3/explorer/xlayer-test/address/$STAKING"
```

---

## Level 5 · Testnet 完整交互

下面演示在 X Layer testnet 上跑一轮真实的 prophet 飞轮。
为了避免每步都手敲长长的 `cast` 参数，强烈推荐把下面这段封装成一个 shell 脚本 `interact.sh`。

### 5.1 准备两个测试 token

X Layer testnet 上你可能要先部署两个 mock ERC20 作为交易对：

```bash
# 部署 mock token A
cast send --rpc-url xlayer_testnet --private-key $PRIVATE_KEY \
  --create $(forge inspect MockERC20 bytecode) \
  $(cast abi-encode "constructor(string,string,uint8)" "Token A" "A" 18)

# tx hash → 找 contract address
# 同样部署 token B，然后把小地址作为 token0，大地址作为 token1
```

### 5.2 全部 cast 命令

把下面这套环境变量填好就能逐条跑。`POOL_KEY_TUPLE` 是 v4 的核心数据结构。

```bash
export TOKEN0=0x<小地址>
export TOKEN1=0x<大地址>
export TICK_SPACING=60
export DYNAMIC_FEE=8388608     # 0x800000 = 1<<23
export EPOCH_BLOCKS=2048
export SKIM_BPS=50
export BASE_LP_BPS=2500

# PoolKey tuple，给所有调用复用
POOL_KEY="($TOKEN0,$TOKEN1,$DYNAMIC_FEE,$TICK_SPACING,$HOOK)"

# 1) 配池
cast send $HOOK \
  "configurePool((address,address,uint24,int24,address),uint32,uint16,uint24)" \
  "$POOL_KEY" $EPOCH_BLOCKS $SKIM_BPS $BASE_LP_BPS \
  --rpc-url xlayer_testnet --private-key $PRIVATE_KEY

# 2) 初始化池子（1:1 价格）
cast send $PM \
  "initialize((address,address,uint24,int24,address),uint160)" \
  "$POOL_KEY" 79228162514264337593543950336 \
  --rpc-url xlayer_testnet --private-key $PRIVATE_KEY

# 3) （首次）质押 ALPHA 拿乘数 + 折扣 —— 需要先 mint ALPHA
#    注意：mainnet/testnet 上 alpha.mint 只有 HOOK 能调，普通用户只能通过 claim 拿
#    所以第一轮你跑不到 stake；先专心跑 swap → claim → payout → 然后下一轮再 stake

# 4) Approve + Swap （通过 v4-periphery 的 router；或自己部署 PoolSwapTest）
#    最方便的办法是用 Uniswap 官方 UI 操作 X Layer testnet 上你的池子

# 5) 等 epoch 自然过去（链上区块自然出块；2048 block × ~2s = ~70 min）
#    或临时用更短 EPOCH_BLOCKS 配池（如 32）便于演示

# 6) Settle epoch
cast send $HOOK "settleEpoch((address,address,uint24,int24,address),uint64)" \
  "$POOL_KEY" 0 \
  --rpc-url xlayer_testnet --private-key $PRIVATE_KEY

# 7) Claim 各 trader 的分数
cast send $HOOK "claim((address,address,uint24,int24,address),uint64,address)" \
  "$POOL_KEY" 0 $TRADER_ADDR \
  --rpc-url xlayer_testnet --private-key $PRIVATE_KEY

# 8) 等 claim 窗口结束（再一个 epoch）

# 9) 派发 pot
cast send $HOOK "payoutPot((address,address,uint24,int24,address),uint64)" \
  "$POOL_KEY" 0 \
  --rpc-url xlayer_testnet --private-key $PRIVATE_KEY

# 10) Staker 提取
cast send $STAKING "claim(address)" $TOKEN0 \
  --rpc-url xlayer_testnet --private-key $STAKER_KEY
```

### 5.3 查询状态

```bash
# 查 epoch 0 的全部信息
cast call $HOOK "getEpochInfo((address,address,uint24,int24,address),uint64)" \
  "$POOL_KEY" 0 \
  --rpc-url xlayer_testnet
# 返回 (openTick, settledTick, settled, pot0, pot1, topProphet, topScore)

# 查 trader 在 epoch 0 的累计仓位
cast call $HOOK \
  "getTraderEpoch((address,address,uint24,int24,address),uint64,address)" \
  "$POOL_KEY" 0 $TRADER \
  --rpc-url xlayer_testnet

# 查 staking 状态
cast call $STAKING "stakedOf(address)" $USER --rpc-url xlayer_testnet
cast call $STAKING "earned(address,address)" $USER $TOKEN0 --rpc-url xlayer_testnet

# 查 SBT
TID=$(cast call $CARD "tokenIdOf(address)" $USER --rpc-url xlayer_testnet)
cast call $CARD "tokenURI(uint256)" $TID --rpc-url xlayer_testnet | \
  cut -d',' -f2 | base64 -d
```

---

## 演示话术（评委 / 投资人 demo）

跑给别人看的最短脚本：

```bash
forge test --match-test test_payoutPot_splits_70_20_10 -vvvv
forge script script/Demo.s.sol:Demo -vv
```

第一条用 trace 模式展示「pot 真的拆成了 70/20/10」；
第二条把整个飞轮 deploy → swap → settle → claim → payout → staker claim
在 3 秒内打印成可读 log，配合 README 里的设计图讲故事。

---

## Troubleshooting

| 现象 | 原因 / 解决 |
|---|---|
| `forge test` 提示 `submodule not initialized` | `git submodule update --init --recursive` |
| `Hook address mismatch` | `HookMiner` 找盐失败，检查 `HOOK_FLAGS` 与 `getHookPermissions` 是否一致 |
| `configurePool` revert `InvalidConfig` | 池子的 `fee` 必须是 `LPFeeLibrary.DYNAMIC_FEE_FLAG`（=0x800000），不能是普通 bps |
| `settleEpoch` revert `EpochNotYetEnded` | 区块还没推到 `firstEpochStartBlock + epochBlocks*(epoch+1)` |
| `claim` revert `NothingToClaim` | 该 trader 在该 epoch 没有 swap 仓位 |
| `payoutPot` revert `ClaimWindowOpen` | 还在 `CLAIM_WINDOW_EPOCHS=1` 宽限期内 |
| `payoutPot` 但 prophet 拿到 90% 而非 70% | 池子当前 tick 不在任何 LP 区间，`donate` 不可行 → LP 份额回滚给 prophet（设计行为） |
| `stake` revert `InsufficientStake` | 0 金额；或 unstake 时余额不足 |
| 跑 Demo.s.sol 报 `address(this) detected` | 旧版本，pull 最新代码即可 |
