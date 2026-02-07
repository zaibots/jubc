// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {ERC20} from 'openzeppelin-contracts/contracts/token/ERC20/ERC20.sol';
import {SafeERC20} from 'openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';

// Morpho Vault V2
import {VaultV2} from 'vault-v2/VaultV2.sol';
import {VaultV2Factory} from 'vault-v2/VaultV2Factory.sol';
import {IVaultV2} from 'vault-v2/interfaces/IVaultV2.sol';

// CarryUSD Product Contracts
import {CarryStrategy} from 'custom/products/carryUSDC/CarryStrategy.sol';
import {CarryAdapter} from 'custom/integrations/morpho/adapters/CarryAdapter.sol';
import {LinearBlockTwapOracle} from 'custom/products/carryUSDC/LinearBlockTwapOracle.sol';
import {CarryTwapPriceChecker} from 'custom/products/carryUSDC/CarryTwapPriceChecker.sol';
import {CarryKeeper} from 'custom/products/carryUSDC/CarryKeeper.sol';

// Interfaces for mocks
import {IChainlinkAggregatorV3} from 'custom/integrations/morpho/interfaces/IChainlinkAutomation.sol';

// Network address library
import {NetworkAddresses} from './config/MarketConfig.sol';

/**
 * @title CarryUSDConfig
 * @notice Configuration library for CarryUSD deployments
 */
library CarryUSDConfig {
  enum Network {
    LOCAL,
    MAINNET,
    BASE,
    SEPOLIA
  }

  struct ExternalAddresses {
    address morphoVault;
    address aavePool;
    address milkman;
    address usdc;
    address jpyToken;
    address jpyUsdFeed;
    address usdcUsdFeed;
  }

  struct StrategyParams {
    string name;
    CarryStrategy.StrategyType strategyType;
    uint64 targetLeverage;
    uint64 minLeverage;
    uint64 maxLeverage;
    uint64 ripcordLeverage;
    uint128 maxTradeSize;
    uint32 twapCooldown;
    uint16 slippageBps;
    uint32 rebalanceInterval;
    uint64 recenterSpeed;
    uint16 incentiveSlippageBps;
    uint16 incentiveTwapCooldown;
    uint128 incentiveMaxTrade;
    uint96 incentiveEtherReward;
  }

  function getConservativeStrategy() internal pure returns (StrategyParams memory) {
    return
      StrategyParams({
        name: 'CarryUSD Conservative',
        strategyType: CarryStrategy.StrategyType.CONSERVATIVE,
        targetLeverage: 2_500_000_000,
        minLeverage: 2_000_000_000,
        maxLeverage: 3_000_000_000,
        ripcordLeverage: 3_500_000_000,
        maxTradeSize: 100_000e6,
        twapCooldown: 5 minutes,
        slippageBps: 50,
        rebalanceInterval: 1 days,
        recenterSpeed: 200_000_000_000_000_000,
        incentiveSlippageBps: 100,
        incentiveTwapCooldown: 30,
        incentiveMaxTrade: 50_000e6,
        incentiveEtherReward: 0.01 ether
      });
  }

  function getModerateStrategy() internal pure returns (StrategyParams memory) {
    return
      StrategyParams({
        name: 'CarryUSD Moderate',
        strategyType: CarryStrategy.StrategyType.MODERATE,
        targetLeverage: 5_000_000_000,
        minLeverage: 4_000_000_000,
        maxLeverage: 6_000_000_000,
        ripcordLeverage: 7_000_000_000,
        maxTradeSize: 250_000e6,
        twapCooldown: 5 minutes,
        slippageBps: 75,
        rebalanceInterval: 12 hours,
        recenterSpeed: 300_000_000_000_000_000,
        incentiveSlippageBps: 150,
        incentiveTwapCooldown: 30,
        incentiveMaxTrade: 100_000e6,
        incentiveEtherReward: 0.02 ether
      });
  }

  function getAggressiveStrategy() internal pure returns (StrategyParams memory) {
    return
      StrategyParams({
        name: 'CarryUSD Aggressive',
        strategyType: CarryStrategy.StrategyType.AGGRESSIVE,
        targetLeverage: 10_000_000_000,
        minLeverage: 8_000_000_000,
        maxLeverage: 12_000_000_000,
        ripcordLeverage: 15_000_000_000,
        maxTradeSize: 500_000e6,
        twapCooldown: 5 minutes,
        slippageBps: 100,
        rebalanceInterval: 6 hours,
        recenterSpeed: 400_000_000_000_000_000,
        incentiveSlippageBps: 200,
        incentiveTwapCooldown: 30,
        incentiveMaxTrade: 200_000e6,
        incentiveEtherReward: 0.05 ether
      });
  }

  function getMainnetAddresses() internal pure returns (ExternalAddresses memory) {
    NetworkAddresses.MainnetAddresses memory mainnet = NetworkAddresses.getMainnetAddresses();
    return
      ExternalAddresses({
        morphoVault: address(0),
        aavePool: address(0),
        milkman: 0x11C76AD590ABDFFCD980afEC9ad951B160F02797,
        usdc: mainnet.usdc,
        jpyToken: address(0),
        jpyUsdFeed: mainnet.jpyUsdFeed,
        usdcUsdFeed: mainnet.usdcUsdFeed
      });
  }

  function getBaseAddresses() internal pure returns (ExternalAddresses memory) {
    NetworkAddresses.BaseAddresses memory base = NetworkAddresses.getBaseAddresses();
    return
      ExternalAddresses({
        morphoVault: address(0),
        aavePool: address(0),
        milkman: address(0),
        usdc: base.usdc,
        jpyToken: address(0),
        jpyUsdFeed: address(0),
        usdcUsdFeed: base.usdcUsdFeed
      });
  }

  function getSepoliaAddresses() internal pure returns (ExternalAddresses memory) {
    return ExternalAddresses({morphoVault: address(0), aavePool: address(0), milkman: address(0), usdc: address(0), jpyToken: address(0), jpyUsdFeed: address(0), usdcUsdFeed: address(0)});
  }
}

/**
 * @title DeployCarryUSD
 * @notice Main deployment script for CarryUSD product contracts
 * @dev Run with: forge script scripts/custom/DeployCarryUSD.s.sol:DeployCarryUSD --rpc-url $RPC_URL --broadcast
 *
 * Environment variables:
 *   NETWORK - "mainnet", "base", "sepolia", or "local" (default: local)
 *   ADMIN - Admin address (default: deployer)
 *   KEEPER - Keeper address for automation (default: deployer)
 *   STRATEGY_TYPE - "conservative", "moderate", or "aggressive" (default: moderate)
 *
 *   External addresses (override network defaults or provide if not known):
 *   MORPHO_VAULT - Morpho Vault V2 address
 *   AAVE_POOL - Aave/Zaibots pool address
 *   MILKMAN - Milkman swap router address
 *   USDC - USDC token address
 *   JPY_TOKEN - jUBC/JPY token address
 *   JPY_USD_FEED - Chainlink JPY/USD price feed
 *   USDC_USD_FEED - Chainlink USDC/USD price feed
 *
 *   If addresses are not provided and not known for the network, mocks will be deployed.
 */
contract DeployCarryUSD is Script {
  using CarryUSDConfig for *;

  // Core CarryUSD contracts
  CarryStrategy public carryStrategy;
  CarryAdapter public carryAdapter;
  LinearBlockTwapOracle public twapOracle;
  CarryTwapPriceChecker public priceChecker;
  CarryKeeper public carryKeeper;

  // Mock contracts (only deployed if needed)
  DeployMockPool public mockPool;
  DeployMockMilkman public mockMilkman;
  DeployMockChainlinkFeed public mockJpyUsdFeed;
  DeployMockChainlinkFeed public mockUsdcUsdFeed;

  // Vault V2 (deployed via VaultV2Factory when no vault address provided)
  VaultV2 public morphoVaultV2;
  bool public deployedNewVault;

  // Configuration
  CarryUSDConfig.Network public network;
  CarryUSDConfig.ExternalAddresses public addresses;
  CarryUSDConfig.StrategyParams public strategyParams;

  address public admin;
  address public keeper;
  bool public deployedMocks;

  function run() external virtual {
    _loadConfig();

    console2.log('========================================');
    console2.log('CARRYUSD DEPLOYMENT');
    console2.log('========================================');
    console2.log('Network:', _networkToString(network));
    console2.log('Deployer:', msg.sender);
    console2.log('Admin:', admin);
    console2.log('Keeper:', keeper);
    console2.log('Strategy:', strategyParams.name);
    console2.log('');

    vm.startBroadcast();

    // Step 1: Deploy mocks if needed
    console2.log('>>> Step 1: Checking external dependencies...');
    _deployMocksIfNeeded();

    // Step 2: Deploy TWAP Oracle
    console2.log('');
    console2.log('>>> Step 2: Deploying TWAP Oracle...');
    twapOracle = new LinearBlockTwapOracle(addresses.jpyUsdFeed);
    console2.log('  LinearBlockTwapOracle:', address(twapOracle));

    // Step 3: Deploy Price Checker
    console2.log('');
    console2.log('>>> Step 3: Deploying Price Checker...');
    priceChecker = new CarryTwapPriceChecker(address(twapOracle), addresses.jpyUsdFeed, addresses.usdc, addresses.jpyToken);
    console2.log('  CarryTwapPriceChecker:', address(priceChecker));

    // Step 4: Deploy Carry Adapter
    console2.log('');
    console2.log('>>> Step 4: Deploying Carry Adapter...');
    string memory strategyId = _getStrategyId();
    carryAdapter = new CarryAdapter(addresses.morphoVault, addresses.usdc, strategyId, address(twapOracle));
    console2.log('  CarryAdapter:', address(carryAdapter));

    // Step 5: Deploy Carry Strategy
    console2.log('');
    console2.log('>>> Step 5: Deploying Carry Strategy...');

    CarryStrategy.Addresses memory strategyAddresses = CarryStrategy.Addresses({
      adapter: address(carryAdapter),
      zaibots: addresses.aavePool,
      collateralToken: addresses.usdc,
      debtToken: addresses.jpyToken,
      jpyUsdOracle: addresses.jpyUsdFeed,
      jpyUsdAggregator: addresses.jpyUsdFeed,
      twapOracle: address(twapOracle),
      milkman: addresses.milkman,
      priceChecker: address(priceChecker)
    });

    uint64[4] memory leverageParams = [strategyParams.targetLeverage, strategyParams.minLeverage, strategyParams.maxLeverage, strategyParams.ripcordLeverage];

    CarryStrategy.ExecutionParams memory executionParams = CarryStrategy.ExecutionParams({
      maxTradeSize: strategyParams.maxTradeSize,
      twapCooldown: strategyParams.twapCooldown,
      slippageBps: strategyParams.slippageBps,
      rebalanceInterval: strategyParams.rebalanceInterval,
      recenterSpeed: strategyParams.recenterSpeed
    });

    CarryStrategy.IncentiveParams memory incentiveParams = CarryStrategy.IncentiveParams({
      slippageBps: strategyParams.incentiveSlippageBps,
      twapCooldown: strategyParams.incentiveTwapCooldown,
      maxTrade: strategyParams.incentiveMaxTrade,
      etherReward: strategyParams.incentiveEtherReward
    });

    carryStrategy = new CarryStrategy(strategyParams.name, strategyParams.strategyType, strategyAddresses, leverageParams, executionParams, incentiveParams);
    console2.log('  CarryStrategy:', address(carryStrategy));

    // Step 6: Deploy Keeper
    console2.log('');
    console2.log('>>> Step 6: Deploying Keeper...');
    carryKeeper = new CarryKeeper();
    console2.log('  CarryKeeper:', address(carryKeeper));

    // Step 7: Configure permissions
    console2.log('');
    console2.log('>>> Step 7: Configuring permissions...');

    carryAdapter.setStrategy(address(carryStrategy));
    console2.log('  Adapter connected to Strategy');

    carryKeeper.addStrategy(address(carryStrategy));
    console2.log('  Strategy added to Keeper');

    carryStrategy.setAllowedCaller(keeper, true);
    carryStrategy.setAllowedCaller(address(carryKeeper), true);
    console2.log('  Keeper authorized on Strategy');

    if (admin != msg.sender) {
      carryStrategy.transferOwnership(admin);
      carryAdapter.transferOwnership(admin);
      twapOracle.transferOwnership(admin);
      priceChecker.transferOwnership(admin);
      carryKeeper.transferOwnership(admin);
      console2.log('  Ownership transferred to admin');
    }

    if (deployedNewVault && address(morphoVaultV2) != address(0)) {
      _configureVaultV2();
      console2.log('  VaultV2 configured: adapter, allocator, caps set');
    }

    vm.stopBroadcast();

    _logDeployedAddresses();
  }

  function _loadConfig() internal {
    string memory networkStr = vm.envOr('NETWORK', string('local'));
    network = _parseNetwork(networkStr);

    if (network == CarryUSDConfig.Network.MAINNET) {
      addresses = CarryUSDConfig.getMainnetAddresses();
    } else if (network == CarryUSDConfig.Network.BASE) {
      addresses = CarryUSDConfig.getBaseAddresses();
    } else if (network == CarryUSDConfig.Network.SEPOLIA) {
      addresses = CarryUSDConfig.getSepoliaAddresses();
    }

    addresses.morphoVault = vm.envOr('MORPHO_VAULT', addresses.morphoVault);
    addresses.aavePool = vm.envOr('AAVE_POOL', addresses.aavePool);
    addresses.milkman = vm.envOr('MILKMAN', addresses.milkman);
    addresses.usdc = vm.envOr('USDC', addresses.usdc);
    addresses.jpyToken = vm.envOr('JPY_TOKEN', addresses.jpyToken);
    addresses.jpyUsdFeed = vm.envOr('JPY_USD_FEED', addresses.jpyUsdFeed);
    addresses.usdcUsdFeed = vm.envOr('USDC_USD_FEED', addresses.usdcUsdFeed);

    string memory strategyType = vm.envOr('STRATEGY_TYPE', string('moderate'));
    if (_strEq(strategyType, 'conservative')) {
      strategyParams = CarryUSDConfig.getConservativeStrategy();
    } else if (_strEq(strategyType, 'aggressive')) {
      strategyParams = CarryUSDConfig.getAggressiveStrategy();
    } else {
      strategyParams = CarryUSDConfig.getModerateStrategy();
    }

    // Custom leverage overrides (9 decimal precision, e.g. 7000000000 = 7x)
    strategyParams.targetLeverage = uint64(vm.envOr('TARGET_LEVERAGE', uint256(strategyParams.targetLeverage)));
    strategyParams.minLeverage = uint64(vm.envOr('MIN_LEVERAGE', uint256(strategyParams.minLeverage)));
    strategyParams.maxLeverage = uint64(vm.envOr('MAX_LEVERAGE', uint256(strategyParams.maxLeverage)));
    strategyParams.ripcordLeverage = uint64(vm.envOr('RIPCORD_LEVERAGE', uint256(strategyParams.ripcordLeverage)));

    admin = vm.envOr('ADMIN', msg.sender);
    keeper = vm.envOr('KEEPER', msg.sender);
  }

  function _deployMocksIfNeeded() internal {
    if (addresses.usdc == address(0)) {
      console2.log('  Deploying MockERC20 for USDC...');
      DeployMockERC20 mockUsdc = new DeployMockERC20('Mock USDC', 'USDC', 6);
      addresses.usdc = address(mockUsdc);
      console2.log('    MockUSDC:', addresses.usdc);
      deployedMocks = true;
    }

    if (addresses.jpyToken == address(0)) {
      console2.log('  Deploying MockERC20 for jUBC...');
      DeployMockERC20 mockJpy = new DeployMockERC20('Mock jUBC', 'jUBC', 18);
      addresses.jpyToken = address(mockJpy);
      console2.log('    MockjUBC:', addresses.jpyToken);
      deployedMocks = true;
    }

    if (addresses.jpyUsdFeed == address(0)) {
      console2.log('  Deploying MockChainlinkFeed for JPY/USD...');
      mockJpyUsdFeed = new DeployMockChainlinkFeed(8, 'JPY / USD', 650000);
      addresses.jpyUsdFeed = address(mockJpyUsdFeed);
      console2.log('    MockJpyUsdFeed:', addresses.jpyUsdFeed);
      deployedMocks = true;
    }

    if (addresses.usdcUsdFeed == address(0)) {
      console2.log('  Deploying MockChainlinkFeed for USDC/USD...');
      mockUsdcUsdFeed = new DeployMockChainlinkFeed(8, 'USDC / USD', 100000000);
      addresses.usdcUsdFeed = address(mockUsdcUsdFeed);
      console2.log('    MockUsdcUsdFeed:', addresses.usdcUsdFeed);
      deployedMocks = true;
    }

    if (addresses.morphoVault == address(0)) {
      console2.log('  Deploying VaultV2 via VaultV2Factory...');
      VaultV2Factory factory = new VaultV2Factory();
      addresses.morphoVault = factory.createVaultV2(msg.sender, addresses.usdc, bytes32('CarryUSD'));
      morphoVaultV2 = VaultV2(addresses.morphoVault);
      deployedNewVault = true;
      console2.log('    VaultV2:', addresses.morphoVault);
      deployedMocks = true;
    }

    if (addresses.aavePool == address(0)) {
      console2.log('  Deploying MockPool...');
      mockPool = new DeployMockPool();
      mockPool.registerAsset(addresses.usdc, 6500);
      mockPool.registerAsset(addresses.jpyToken, 0);
      addresses.aavePool = address(mockPool);
      console2.log('    MockPool:', addresses.aavePool);
      deployedMocks = true;
    }

    if (addresses.milkman == address(0)) {
      console2.log('  Deploying MockMilkman...');
      mockMilkman = new DeployMockMilkman();
      mockMilkman.setAutoSettle(true, 0);
      addresses.milkman = address(mockMilkman);
      console2.log('    MockMilkman:', addresses.milkman);
      deployedMocks = true;
    }

    if (!deployedMocks) {
      console2.log('  All external addresses provided, no mocks needed');
    }
  }

  function _getStrategyId() internal view returns (string memory) {
    if (strategyParams.strategyType == CarryStrategy.StrategyType.CONSERVATIVE) return 'carry-usd-conservative';
    if (strategyParams.strategyType == CarryStrategy.StrategyType.AGGRESSIVE) return 'carry-usd-aggressive';
    return 'carry-usd-moderate';
  }

  function _parseNetwork(string memory networkStr) internal pure returns (CarryUSDConfig.Network) {
    if (_strEq(networkStr, 'mainnet')) return CarryUSDConfig.Network.MAINNET;
    if (_strEq(networkStr, 'base')) return CarryUSDConfig.Network.BASE;
    if (_strEq(networkStr, 'sepolia')) return CarryUSDConfig.Network.SEPOLIA;
    return CarryUSDConfig.Network.LOCAL;
  }

  function _networkToString(CarryUSDConfig.Network _network) internal pure returns (string memory) {
    if (_network == CarryUSDConfig.Network.MAINNET) return 'mainnet';
    if (_network == CarryUSDConfig.Network.BASE) return 'base';
    if (_network == CarryUSDConfig.Network.SEPOLIA) return 'sepolia';
    return 'local';
  }

  function _strEq(string memory a, string memory b) internal pure returns (bool) {
    return keccak256(bytes(a)) == keccak256(bytes(b));
  }

  function _configureVaultV2() internal {
    VaultV2 vault = morphoVaultV2;

    // Set vault name and symbol (owner-only, no timelock)
    vault.setName('CarryUSD Vault');
    vault.setSymbol('cvUSD');

    // Set deployer as curator (owner-only, no timelock)
    vault.setCurator(msg.sender);

    // All curator functions require submit+execute pattern.
    // Fresh vaults have zero timelocks so execute is immediate after submit.

    // Add adapter
    vault.submit(abi.encodeCall(IVaultV2.addAdapter, (address(carryAdapter))));
    vault.addAdapter(address(carryAdapter));

    // Set deployer as allocator
    vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (msg.sender, true)));
    vault.setIsAllocator(msg.sender, true);

    // Set caps for adapter risk IDs
    _setAbsoluteCap(vault, bytes('aave-protocol'));
    _setAbsoluteCap(vault, bytes('jpy-fx-exposure'));
    _setAbsoluteCap(vault, abi.encodePacked('strategy:', _getStrategyId()));
  }

  function _setAbsoluteCap(VaultV2 vault, bytes memory idData) internal {
    uint256 maxCap = uint256(type(uint128).max);
    vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, maxCap)));
    vault.increaseAbsoluteCap(idData, maxCap);
  }

  function _logDeployedAddresses() internal view {
    console2.log('');
    console2.log('========================================');
    console2.log('DEPLOYMENT COMPLETE');
    console2.log('========================================');
    console2.log('');
    console2.log('--- CarryUSD Core Contracts ---');
    console2.log('CarryStrategy:', address(carryStrategy));
    console2.log('CarryAdapter:', address(carryAdapter));
    console2.log('LinearBlockTwapOracle:', address(twapOracle));
    console2.log('CarryTwapPriceChecker:', address(priceChecker));
    console2.log('CarryKeeper:', address(carryKeeper));
    console2.log('');
    console2.log('--- External Dependencies ---');
    console2.log('MorphoVault:', addresses.morphoVault);
    console2.log('AavePool (Zaibots):', addresses.aavePool);
    console2.log('Milkman:', addresses.milkman);
    console2.log('USDC:', addresses.usdc);
    console2.log('JPY Token (jUBC):', addresses.jpyToken);
    console2.log('JPY/USD Feed:', addresses.jpyUsdFeed);

    if (deployedMocks) {
      console2.log('');
      console2.log('--- Mock/Deployed Contracts ---');
      if (deployedNewVault) console2.log('VaultV2:', address(morphoVaultV2));
      if (address(mockPool) != address(0)) console2.log('MockPool:', address(mockPool));
      if (address(mockMilkman) != address(0)) console2.log('MockMilkman:', address(mockMilkman));
      if (address(mockJpyUsdFeed) != address(0)) console2.log('MockJpyUsdFeed:', address(mockJpyUsdFeed));
    }

    console2.log('');
    console2.log('--- Strategy Configuration ---');
    console2.log('Name:', strategyParams.name);
    console2.log('Target Leverage:', strategyParams.targetLeverage / 1e9, 'x');
    console2.log('Min Leverage:', strategyParams.minLeverage / 1e9, 'x');
    console2.log('Max Leverage:', strategyParams.maxLeverage / 1e9, 'x');
    console2.log('Ripcord Leverage:', strategyParams.ripcordLeverage / 1e9, 'x');
    console2.log('========================================');
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// MOCK CONTRACTS FOR DEPLOYMENT
// ══════════════════════════════════════════════════════════════════════════════

contract DeployMockERC20 is IERC20 {
  string public name;
  string public symbol;
  uint8 public decimals;
  mapping(address => uint256) private _balances;
  mapping(address => mapping(address => uint256)) private _allowances;
  uint256 private _totalSupply;

  constructor(string memory _name, string memory _symbol, uint8 _decimals) {
    name = _name;
    symbol = _symbol;
    decimals = _decimals;
  }

  function totalSupply() external view override returns (uint256) {
    return _totalSupply;
  }

  function balanceOf(address account) external view override returns (uint256) {
    return _balances[account];
  }

  function transfer(address to, uint256 amount) external override returns (bool) {
    _balances[msg.sender] -= amount;
    _balances[to] += amount;
    emit Transfer(msg.sender, to, amount);
    return true;
  }

  function allowance(address owner, address spender) external view override returns (uint256) {
    return _allowances[owner][spender];
  }

  function approve(address spender, uint256 amount) external override returns (bool) {
    _allowances[msg.sender][spender] = amount;
    emit Approval(msg.sender, spender, amount);
    return true;
  }

  function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
    _allowances[from][msg.sender] -= amount;
    _balances[from] -= amount;
    _balances[to] += amount;
    emit Transfer(from, to, amount);
    return true;
  }

  function mint(address to, uint256 amount) external {
    _balances[to] += amount;
    _totalSupply += amount;
    emit Transfer(address(0), to, amount);
  }
}

contract DeployMockChainlinkFeed is IChainlinkAggregatorV3 {
  int256 public price;
  uint256 public updatedAt;
  uint80 public roundId;
  uint8 public immutable override decimals;
  string public override description;
  uint256 public constant override version = 1;

  constructor(uint8 _decimals, string memory _description, int256 _initialPrice) {
    decimals = _decimals;
    description = _description;
    price = _initialPrice;
    updatedAt = block.timestamp;
    roundId = 1;
  }

  function setPrice(int256 _price) external {
    price = _price;
    updatedAt = block.timestamp;
    roundId++;
  }

  function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
    return (roundId, price, updatedAt, updatedAt, roundId);
  }

  function getRoundData(uint80 _roundId) external view override returns (uint80, int256, uint256, uint256, uint80) {
    return (_roundId, price, updatedAt, updatedAt, _roundId);
  }
}

contract DeployMockBalanceTracker {
  mapping(address => uint256) private _balances;

  function balanceOf(address account) external view returns (uint256) {
    return _balances[account];
  }

  function mint(address to, uint256 amount) external {
    _balances[to] += amount;
  }

  function burn(address from, uint256 amount) external {
    _balances[from] -= amount;
  }
}

contract DeployMockPool {
  using SafeERC20 for IERC20;

  struct ReserveConfig {
    uint256 data;
  }

  mapping(address => address) public aTokens;
  mapping(address => address) public debtTokens;
  mapping(address => uint256) public configData;

  function registerAsset(address asset, uint256 ltvBps) external {
    if (aTokens[asset] == address(0)) {
      aTokens[asset] = address(new DeployMockBalanceTracker());
      debtTokens[asset] = address(new DeployMockBalanceTracker());
    }
    configData[asset] = ltvBps;
  }

  function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
    IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    DeployMockBalanceTracker(aTokens[asset]).mint(onBehalfOf, amount);
  }

  function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
    uint256 bal = DeployMockBalanceTracker(aTokens[asset]).balanceOf(msg.sender);
    uint256 toWithdraw = amount > bal ? bal : amount;
    DeployMockBalanceTracker(aTokens[asset]).burn(msg.sender, toWithdraw);
    IERC20(asset).safeTransfer(to, toWithdraw);
    return toWithdraw;
  }

  function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
    DeployMockBalanceTracker(debtTokens[asset]).mint(onBehalfOf, amount);
    IERC20(asset).safeTransfer(msg.sender, amount);
  }

  function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
    uint256 debt = DeployMockBalanceTracker(debtTokens[asset]).balanceOf(onBehalfOf);
    uint256 toRepay = amount > debt ? debt : amount;
    IERC20(asset).safeTransferFrom(msg.sender, address(this), toRepay);
    DeployMockBalanceTracker(debtTokens[asset]).burn(onBehalfOf, toRepay);
    return toRepay;
  }

  function getConfiguration(address asset) external view returns (ReserveConfig memory) {
    return ReserveConfig({data: configData[asset]});
  }

  function getReserveAToken(address asset) external view returns (address) {
    return aTokens[asset];
  }

  function getReserveVariableDebtToken(address asset) external view returns (address) {
    return debtTokens[asset];
  }

  function getUserAccountData(address) external pure returns (uint256, uint256, uint256, uint256, uint256, uint256) {
    return (type(uint128).max, 0, type(uint128).max, 0, 0, type(uint128).max);
  }

  function fundBorrowLiquidity(address asset, uint256 amount) external {
    (bool success, ) = asset.call(abi.encodeWithSignature('mint(address,uint256)', address(this), amount));
    require(success, 'mint failed');
  }
}

contract DeployMockMilkman {
  using SafeERC20 for IERC20;

  struct PendingSwap {
    address requester;
    uint256 amountIn;
    address fromToken;
    address toToken;
    address recipient;
    bool settled;
  }

  mapping(bytes32 => PendingSwap) public pendingSwaps;
  uint256 public swapCounter;
  bool public shouldAutoSettle;
  uint256 public autoSettlementDelay;

  function setAutoSettle(bool enabled, uint256 delay) external {
    shouldAutoSettle = enabled;
    autoSettlementDelay = delay;
  }

  function requestSwapExactTokensForTokens(uint256 amountIn, IERC20 fromToken, IERC20 toToken, address recipient, address, bytes calldata) external {
    swapCounter++;
    bytes32 swapId = keccak256(abi.encodePacked(msg.sender, swapCounter, block.timestamp));
    fromToken.safeTransferFrom(msg.sender, address(this), amountIn);
    pendingSwaps[swapId] = PendingSwap({requester: msg.sender, amountIn: amountIn, fromToken: address(fromToken), toToken: address(toToken), recipient: recipient, settled: false});

    if (shouldAutoSettle && autoSettlementDelay == 0) {
      pendingSwaps[swapId].settled = true;
      IERC20(address(toToken)).safeTransfer(recipient, amountIn);
    }
  }

  function settleSwap(bytes32 swapId, uint256 amountOut) external {
    PendingSwap storage swap = pendingSwaps[swapId];
    require(!swap.settled, 'Already settled');
    swap.settled = true;
    IERC20(swap.toToken).safeTransfer(swap.recipient, amountOut);
  }

  function fundSettlementLiquidity(address token, uint256 amount) external {
    (bool success, ) = token.call(abi.encodeWithSignature('mint(address,uint256)', address(this), amount));
    require(success, 'mint failed');
  }
}
