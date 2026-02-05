# CarryUSD - Leveraged Yen Carry Trade Strategy

A configurable leveraged carry trade strategy that borrows jUBC (JPY-denominated token) against USDC collateral to capture interest rate differentials.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      Morpho Vault V2                             │
│                    (User Deposits USDC)                          │
└─────────────────────────┬───────────────────────────────────────┘
                          │ allocate/deallocate
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      CarryAdapter                                │
│              (Morpho V2 Integration Layer)                       │
└─────────────────────────┬───────────────────────────────────────┘
                          │ receiveAssets/withdrawAssets
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                     CarryStrategy                                │
│            (Core Leverage & Rebalancing Logic)                   │
├─────────────────────────┬───────────────────────────────────────┤
│                         │                                        │
│    ┌────────────────────┼────────────────────┐                  │
│    ▼                    ▼                    ▼                  │
│ Zaibots Pool      Milkman/CoW         Chainlink Oracle          │
│ (Aave V3)         (DEX Swaps)         (JPY/USD Price)           │
└─────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      CarryKeeper                                 │
│              (Chainlink Automation)                              │
└─────────────────────────────────────────────────────────────────┘
```

## Contracts

| Contract | Description |
|----------|-------------|
| `CarryStrategy.sol` | Core strategy contract handling leverage, rebalancing, and ripcord |
| `CarryAdapter.sol` | Morpho Vault V2 adapter bridging vault to strategy |
| `LinearBlockTwapOracle.sol` | TWAP oracle for JPY/USD price smoothing |
| `CarryTwapPriceChecker.sol` | Price validation for Milkman/CoW swaps |
| `CarryKeeper.sol` | Chainlink Automation keeper for automated rebalancing |
| `CarryLib.sol` | Shared constants and math utilities |

## Configuration Parameters

### Strategy Types

| Type | Target | Min | Max | Ripcord | Use Case |
|------|--------|-----|-----|---------|----------|
| CONSERVATIVE | 2.5x | 2x | 3x | 3.5x | Lower risk, stable returns |
| MODERATE | 5x | 4x | 6x | 7x | Balanced risk/reward |
| AGGRESSIVE | 10x | 8x | 12x | 15x | Higher risk, higher returns |

### Leverage Parameters (`LeverageParams`)

```solidity
struct LeverageParams {
  uint64 target;    // Target leverage ratio (9 decimals, e.g., 5e9 = 5x)
  uint64 min;       // Minimum leverage before rebalancing
  uint64 max;       // Maximum leverage before rebalancing
  uint64 ripcord;   // Emergency deleveraging threshold
}
```

**Recommendations:**
- `target`: Core strategy parameter - determines expected returns and risk
- `min/max`: Set ~20% below/above target for normal rebalancing band
- `ripcord`: Set 40-50% above target as emergency threshold

### Execution Parameters (`ExecutionParams`)

```solidity
struct ExecutionParams {
  uint128 maxTradeSize;      // Max single trade in collateral units (USDC)
  uint32 twapCooldown;       // Seconds between TWAP iterations
  uint16 slippageBps;        // Max slippage in basis points
  uint32 rebalanceInterval;  // Seconds between rebalances
  uint64 recenterSpeed;      // How fast to recenter (18 decimals, 0.3e18 = 30%)
}
```

**Recommendations:**
| Parameter | Conservative | Moderate | Aggressive |
|-----------|-------------|----------|------------|
| `maxTradeSize` | 100k USDC | 250k USDC | 500k USDC |
| `twapCooldown` | 5 min | 5 min | 5 min |
| `slippageBps` | 50 (0.5%) | 75 (0.75%) | 100 (1%) |
| `rebalanceInterval` | 1 day | 12 hours | 6 hours |
| `recenterSpeed` | 0.2e18 | 0.3e18 | 0.4e18 |

### Incentive Parameters (`IncentiveParams`)

```solidity
struct IncentiveParams {
  uint16 slippageBps;     // Ripcord slippage tolerance
  uint16 twapCooldown;    // Ripcord cooldown
  uint128 maxTrade;       // Max ripcord trade size
  uint96 etherReward;     // ETH reward for ripcord caller
}
```

**Recommendations:**
- `slippageBps`: 100-200 bps (higher than normal to ensure execution)
- `etherReward`: 0.01-0.05 ETH (must keep contract funded)

## Deployment

### Prerequisites

1. **External Contracts Required:**
   - Morpho Vault V2 address
   - Zaibots/Aave V3 pool address
   - jUBC token address
   - Chainlink JPY/USD price feed
   - Milkman swap router

2. **Deployer Requirements:**
   - ETH for gas
   - Admin keys for ownership

### Deployment Order

```bash
# 1. Deploy TWAP Oracle
LinearBlockTwapOracle(chainlinkJpyUsdFeed)

# 2. Deploy Price Checker
CarryTwapPriceChecker(twapOracle, chainlinkFeed, usdc, jpyToken)

# 3. Deploy Adapter
CarryAdapter(morphoVault, usdc, strategyId, twapOracle)

# 4. Deploy Strategy
CarryStrategy(name, type, addresses, leverage, execution, incentive)

# 5. Deploy Keeper
CarryKeeper()

# 6. Configure connections
adapter.setStrategy(strategy)
keeper.addStrategy(strategy)
strategy.setAllowedCaller(keeper, true)
strategy.setAllowedCaller(operatorEOA, true)
```

### Using the Deploy Script

```bash
# Local with all mocks
forge script scripts/custom/DeployCarryUSD.s.sol:DeployCarryUSD --broadcast

# Mainnet
NETWORK=mainnet \
MORPHO_VAULT=0x... \
AAVE_POOL=0x... \
JPY_TOKEN=0x... \
STRATEGY_TYPE=moderate \
ADMIN=0x... \
KEEPER=0x... \
forge script scripts/custom/DeployCarryUSD.s.sol:DeployCarryUSD \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `NETWORK` | Network name (local/mainnet/base/sepolia) | No (default: local) |
| `MORPHO_VAULT` | Morpho Vault V2 address | Yes (mainnet) |
| `AAVE_POOL` | Zaibots/Aave pool address | Yes (mainnet) |
| `JPY_TOKEN` | jUBC token address | Yes (mainnet) |
| `MILKMAN` | Milkman router address | No (known for mainnet) |
| `JPY_USD_FEED` | Chainlink JPY/USD feed | No (known for mainnet) |
| `STRATEGY_TYPE` | conservative/moderate/aggressive | No (default: moderate) |
| `ADMIN` | Admin address for ownership | No (default: deployer) |
| `KEEPER` | Keeper address for automation | No (default: deployer) |

## Security Considerations

### Access Control

| Role | Permissions | Recommendation |
|------|-------------|----------------|
| **Owner** | Transfer ownership, set adapter, set operator | Multisig (3/5) |
| **Operator** | Set active, set allowed callers, withdraw ETH | Operations multisig (2/3) |
| **Allowed Caller** | Engage, rebalance | Keeper contract + backup EOA |
| **Anyone** | Ripcord (when conditions met) | Incentivized public function |

### Critical Parameters

1. **Ripcord Threshold**: If set too high, may not trigger before liquidation
2. **Max Trade Size**: If too large, may cause excessive slippage
3. **Slippage Tolerance**: If too tight, swaps may fail; if too loose, MEV extraction
4. **ETH Balance**: Must maintain balance for ripcord rewards

### Oracle Risks

- **Chainlink Staleness**: TWAP oracle has `maxStaleness` check (default 2 hours)
- **Circuit Breaker**: Triggers if TWAP diverges >1% from spot
- **Price Manipulation**: TWAP smoothing mitigates flash loan attacks

### Smart Contract Risks

- **Reentrancy**: Protected via `ReentrancyGuard` on all state-changing functions
- **Integer Overflow**: Solidity 0.8+ with explicit bounds checking
- **Approval Hygiene**: Max approvals granted at construction to trusted contracts only

## Operations

### Monitoring

**Critical Metrics:**
```
- Current leverage ratio vs target
- Health factor on Zaibots/Aave
- Pending swap state and timeout
- ETH balance for ripcord rewards
- TWAP vs spot price divergence
```

**Alerts:**
| Condition | Severity | Action |
|-----------|----------|--------|
| Leverage > max | Warning | Check if rebalance pending |
| Leverage > ripcord | Critical | Verify ripcord executed |
| Health factor < 1.5 | Critical | Manual intervention |
| Swap pending > 30 min | Warning | Check CoW settlement |
| ETH balance < reward | High | Fund contract |

### Regular Operations

**Daily:**
- Verify keeper is executing rebalances
- Check TWAP oracle is updating
- Monitor gas costs

**Weekly:**
- Review leverage history
- Analyze swap execution quality
- Check interest rate spread

**Monthly:**
- Review and adjust parameters if needed
- Audit access control lists
- Test emergency procedures

### Keeper Configuration

For Chainlink Automation:
```
Contract: CarryKeeper
Check function: checkUpkeep(bytes)
Perform function: performUpkeep(bytes)
Gas limit: 500,000
```

## Emergency Procedures

### Pause Strategy

```solidity
// Operator can pause
strategy.setActive(false);

// This prevents:
// - engage()
// - rebalance()
// Does NOT prevent:
// - ripcord() (intentional - emergency exit must work)
// - withdrawAssets() via adapter
```

### Emergency Deleveraging

If automated systems fail:

1. **Manual Ripcord** (anyone can call if conditions met):
   ```solidity
   strategy.ripcord();
   ```

2. **Manual Rebalance** (allowed caller only):
   ```solidity
   strategy.rebalance();
   ```

3. **Emergency Withdrawal** (adapter owner only):
   ```solidity
   adapter.emergencyWithdraw(token, amount);
   ```

### Stuck Swap Recovery

If a swap is pending for > 30 minutes:
1. Check Milkman/CoW order status
2. Cancel order if possible via Milkman
3. Strategy will timeout and allow new operations

### Oracle Failure

If Chainlink feed is stale or circuit breaker triggers:
1. TWAP oracle will revert on `getSpotPrice()`
2. Strategy operations will halt
3. Owner can call `twapOracle.resetToSpot()` once feed recovers

## Risk Parameters by Strategy Type

### Conservative (2.5x)

```
Expected APY: ~5-8% (varies with rate spread)
Max Drawdown: ~15-20%
Liquidation Distance: ~60%
Rebalance Frequency: ~Weekly
```

### Moderate (5x)

```
Expected APY: ~12-18%
Max Drawdown: ~25-35%
Liquidation Distance: ~40%
Rebalance Frequency: ~Daily
```

### Aggressive (10x)

```
Expected APY: ~25-40%
Max Drawdown: ~40-60%
Liquidation Distance: ~25%
Rebalance Frequency: ~Multiple daily
```

## Decimal Reference

| Value | Decimals | Example |
|-------|----------|---------|
| Leverage ratio | 9 | 5e9 = 5x |
| Full precision | 18 | 1e18 = 1.0 |
| Chainlink price | 8 | 650000 = $0.0065 |
| USDC amounts | 6 | 1e6 = 1 USDC |
| jUBC amounts | 18 | 1e18 = 1 jUBC |
| Basis points | 0 | 50 = 0.5% |

## Deployed Addresses

### Sepolia Testnet

| Contract | Address |
|----------|---------|
| CarryStrategy | `0xeb4d7B8Bf919F562414695aC46D81aa3d5f8d042` |
| CarryAdapter | `0x3a7B9C686F38E60566BAE9F6C1AA0Da4daE49c0C` |
| LinearBlockTwapOracle | `0xC2B8C98c82c6be032a9c281C8B6183f7F9D17Fe7` |
| CarryTwapPriceChecker | `0xf436cB6E1A48D4A650645f6442e0527a73805607` |
| CarryKeeper | `0x2D422290836a97e0a008191abaAf288Ef7A794eD` |
| MockUSDC | `0xf79D144f8F3B294FDEC05c8E34D38EdEaf299047` |
| MockjUBC | `0x4808A01B79e8EC40DCA519A3c11691aeDEeCCfda` |
| MockMorphoVault | `0x3B9FA6b4c75024FfDda2Bfd2Cc38c77de79de6d8` |
| MockZaibots | `0x4d1BCa56D92D0641C91155596EA5a497A6876100` |

### Mainnet

*Not yet deployed*

## Audits

*Pending*

## License

MIT
