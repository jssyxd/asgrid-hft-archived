# asgrid-hft-archived: 早期高频盲目挂单版本完整归档 (Dayuan Account Archive)

本仓库完整归档了 **Strategy 012 / 003: Avellaneda-Stoikov ML Grid (早期同步 REST 轮询与高频全撤全挂版本)** 的全部生产组件、机器学习模型、训练流水线、实战对账数据与历史经验教训。

---

## 一、 历史背景与实盘运行战报（真实账单全量对账）

该版本曾部署在海外云服务器（VPS `155.254.60.38`），由实盘微账户 **`子账户dayuan`** 挂机运行。

### 1. 真实交易指标对账表（OKX 官方 Bills 权威流水）

| 核心指标项 | 真实统计数值 | 关键归因说明 |
| :--- | :---: | :--- |
| **实盘运行时长** | **40.96 小时** (约 1.7 天，2026-10-28 10:25 ~ 10-30 03:22 UTC) | 经历了暴跌震荡与多次高频调单周期 |
| **真实扣费撮合成交笔数** | **2,123 笔** | 平均每分钟被动撮合约 0.86 笔 |
| **名义成交流水总额 (Turnover)** | **16,839.07 USDT** | 单笔 0.01 张（0.0001 BTC），高频产生大量流水 |
| **累计手续费净支出 (Total Fees)** | **`4.9177 USDT`** | **占总资产变动亏损的 72.6%**（做市商被手续费反噬） |
| **已实现净盈亏 (Realized PnL)** | **`-1.8578 USDT`** | 包含手续费磨损后的净损益 |
| **Maker 成交笔数与比例** | **1,461 笔 (68.8%)** | 期望纯做市，但遭遇严重 Taker 穿透 |
| **Taker 误吃单笔数与比例** | **`657 笔 (30.9%)`** | **致命缺陷：未设置 post_only，导致 30.9% 变吃单** |
| **账户初始资金** | **34.95 USDT** | 3x 杠杆微型账户基底 |
| **运行期末账户总权益** | **28.25 USDT** | 回撤幅度约 -19.1%，无爆仓，但持续被手续费蚕食 |
| **循环计算与报单速度** | **700ms ~ 750ms / 轮** | 同步 REST 串行调用造成的延迟瓶颈 |

---

## 二、 架构解构：多层结构在交易中如何工作？

该版本采用经典的 5 层分层设计：

```
[OKX REST 轮询 (每轮 1.5~2 秒)]
       │
       ▼
【第 1 层：7 维微观特征提取器】
  - Parkinson 波动率 + Garman-Klass 波动率
  - ATR(14) 真实波幅均值 + MA20 偏离度 (f_dev) + 1-bar 收益率 (s_r1) + 成交量加速度
  - L2 深度 20 档静态失衡度 (OBI) + 离散一阶差分订单流不平衡量 (OFI)
       │
       ▼
【第 2 层：LightGBM 多任务推理内核】
  - lgb_drift_model.txt (50 树): 预测未来 5 根 Bar 归一化价格漂移 mu_drift
  - lgb_tox_down_model.txt (40 树): 预测下行 -1.8 ATR 暴跌毒性冲击概率 P_toxic_down
  - lgb_tox_up_model.txt (40 树): 预测上行 +1.8 ATR 爆仓挤压冲击概率 P_toxic_up
       │
       ▼
【第 3 层：Avellaneda-Stoikov 随机控制定价】
  - 保留价格倾斜: r = P_mid - q * lot * gamma * sigma^2 * 0.001 + alpha_d * mu_drift
  - 非对称毒性加宽: delta_bid = delta_base * (1 + beta_toxic * P_toxic_down)
                    delta_ask = delta_base * (1 + beta_toxic * P_toxic_up)
       │
       ▼
【第 4 层：微账户动态风险自适应 (as_dynamic_risk.py)】
  - 检测到资金 <= 100 USDT，强制将 gamma 上调为 3.0，max_inventory 收紧为 0.05 张
       │
       ▼
【第 5 层：实盘执行与订单管理 (致命缺陷所在)】
  - 步骤 A: get_pending_orders -> cancel_batch_orders (暴力全撤)
  - 步骤 B: place_order (ord_type="limit") (无脑重挂)
```

---

## 三、 为什么会导致手续费大幅亏损？核心漏洞剖析

1. **未强制 `post_only`（最致命问题）**：
   下单时使用普通 `limit` 限价单。当微观盘口跳动时，限价单直接与对手单重叠撮合，直接沦为 Taker，被 OKX 按照 **0.05%** 高费率惩罚性扣除，导致产生多达 657 笔 Taker 扣费。
2. **REST 轮询与信息陈旧度（Staleness）**：
   使用同步 REST 请求行情，网络往返需要 180ms，获取到的订单簿已经是历史切片。挂单到达交易所撮合队列时早已失去排队优势。
3. **高频全撤全挂摧毁队列优先权（Queue Priority）**：
   每 1~2 秒循环一次，无论价格是否变化都将上一轮挂单撤销重新挂出。这导致订单永远排在撮合队列的最末端，无法享受到 Maker 的优先成交权。
4. **曾出现“挂单成功当成成交”的统计假象**：
   早期代码将 `place_order` 返回 `code == "0"` 直接计入了撮合成交（`matched_trades += 1`），造成日志里产生了上万笔虚拟流水，掩盖了真实成交偏少、手续费畸高的本质。

---

## 四、 离线模型训练与可复现指南

模型训练源码位于 `kaggle_trainer/trainer.py`，已配置 Kaggle / 本地可复现环境。

### 1. 训练数据格式
输入为经过治理的高频订单簿微观切片（Parquet 格式），提取以下 7 维矩阵：
`X = [p_vol, gk_vol, atr14, bar_ofi, f_dev, s_r1, vol_accel]`

### 2. 标签定义与 LightGBM 训练
```python
# 5 周期前瞻漂移与极端冲击分类
fwd_ret = (pd.Series(close).shift(-5).values - close) / np.maximum(atr14, 0.05)
y_drift = np.clip(fwd_ret, -5.0, 5.0)
y_toxic_down = (fwd_min <= -1.8).astype(np.int32)
y_toxic_up = (fwd_max >= 1.8).astype(np.int32)

# 训练参数
params_drift = {'objective': 'regression', 'metric': 'rmse', 'learning_rate': 0.08, 'num_leaves': 15, 'verbosity': -1}
bst_drift = lgb.train(params_drift, dtrain_drift, num_boost_round=50)
```

训练完成的模型存放在 `checkpoints/` 目录下（`lgb_drift_model.txt`, `lgb_tox_down_model.txt`, `lgb_tox_up_model.txt`）。

---

## 五、 任何 VPS 一键复现部署指南

```bash
# 1. 克隆本仓库到 VPS
git clone https://github.com/jssyxd/asgrid-hft-archived.git /opt/asgrid-hft
cd /opt/asgrid-hft

# 2. 配置 OKX API 凭据
cat << 'EOF' > config.env
OKX_API_KEY=your_okx_key
OKX_API_SECRET=your_okx_secret
OKX_API_PASSPHRASE=your_passphrase
OKX_SIMULATED_TRADING=0
EOF

# 3. 启动实盘做市容器
docker compose up -d --build

# 4. 查看高频报单流水
docker logs -f nautilus_vps_003_as_grid --tail 20
```
