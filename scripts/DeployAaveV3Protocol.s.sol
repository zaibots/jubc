// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';
import 'forge-std/StdJson.sol';
import 'forge-std/console.sol';

import '../src/deployments/interfaces/IMarketReportTypes.sol';
import {IMetadataReporter} from '../src/deployments/interfaces/IMetadataReporter.sol';
import {DeployUtils} from '../src/deployments/contracts/utilities/DeployUtils.sol';
import {AaveV3BatchOrchestration} from '../src/deployments/projects/aave-v3-batched/AaveV3BatchOrchestration.sol';
import {MarketInput} from '../src/deployments/inputs/MarketInput.sol';

import {WETH9} from '../src/contracts/dependencies/weth/WETH9.sol';
import {MockAggregator} from '../src/contracts/mocks/oracle/CLAggregators/MockAggregator.sol';


/// @notice Mock Augustus Registry that accepts any non-zero augustus address
contract MockAugustusRegistry {
  function isValidAugustus(address input) external pure returns (bool) {
    return input != address(0);
  }
}

/**
 * @title DeployAaveV3Protocol
 * @notice Single script for deploying the core Aave V3 protocol to any chain.
 *
 * @dev Environment variables:
 *   MARKET_ID         - Market name (default: "Aave V3 Market")
 *   PROVIDER_ID       - Provider ID number (default: chain id)
 *   WETH              - Wrapped native token address. If unset, deploys mock WETH9 (local only).
 *   ETH_USD_FEED      - ETH/USD price feed. If unset, deploys mock oracle (local only).
 *   AUGUSTUS_REGISTRY  - ParaSwap registry. If unset, deploys mock.
 *   IS_L2             - Set to "true" for L2 deployments (default: false)
 *
 * @dev Usage:
 *   # Local (Anvil) - mocks deployed automatically
 *   forge script scripts/DeployAaveV3Protocol.s.sol:DeployAaveV3Protocol --broadcast --rpc-url http://localhost:8545
 *
 *   # Sepolia - provide real addresses
 *   MARKET_ID="Sepolia UBC Market" PROVIDER_ID=37 WETH=0x... ETH_USD_FEED=0x... \
 *     forge script scripts/DeployAaveV3Protocol.s.sol:DeployAaveV3Protocol --broadcast --rpc-url $SEPOLIA_RPC
 */
contract DeployAaveV3Protocol is DeployUtils, MarketInput, Script {
  using stdJson for string;

  function run() external {
    console.log('===========================================');
    console.log('   Aave V3 Protocol Deployment');
    console.log('===========================================');
    console.log('Deployer:', msg.sender);
    console.log('');

    vm.startBroadcast();

    // Resolve external dependencies (deploy mocks if not provided)
    (
      address wrappedNativeToken,
      address ethUsdFeed,
      address augustusRegistry
    ) = _resolveExternalDeps(msg.sender);

    // Build market config from env vars + resolved deps
    (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory report
    ) = _buildMarketConfig(msg.sender, wrappedNativeToken, ethUsdFeed, augustusRegistry);

    // Deploy full Aave V3 protocol
    console.log('Deploying Aave V3 Protocol...');
    console.log('-------------------------------------------');
    report = AaveV3BatchOrchestration.deployAaveV3(msg.sender, roles, config, flags, report);

    vm.stopBroadcast();

    // Log all deployed addresses
    console.log('');
    console.log('===========================================');
    console.log('   DEPLOYMENT COMPLETE!');
    console.log('===========================================');
    console.log('');
    _logReport(report);

    // Write JSON report
    IMetadataReporter metadataReporter = IMetadataReporter(
      _deployFromArtifacts('MetadataReporter.sol:MetadataReporter')
    );
    metadataReporter.writeJsonReportMarket(report);
    console.log('JSON report written to ./reports/');
  }

  /// @notice Resolve external dependencies. Deploys mocks for any address not provided via env.
  function _resolveExternalDeps(
    address deployer
  ) internal returns (address wrappedNativeToken, address ethUsdFeed, address augustusRegistry) {
    wrappedNativeToken = vm.envOr('WETH', address(0));
    ethUsdFeed = vm.envOr('ETH_USD_FEED', address(0));
    augustusRegistry = vm.envOr('AUGUSTUS_REGISTRY', address(0));

    if (wrappedNativeToken == address(0)) {
      WETH9 weth = new WETH9();
      wrappedNativeToken = address(weth);
      console.log('  Deployed mock WETH9:', wrappedNativeToken);
    } else {
      console.log('  Using WETH:', wrappedNativeToken);
    }

    if (ethUsdFeed == address(0)) {
      MockAggregator oracle = new MockAggregator(3000 * 10 ** 8);
      ethUsdFeed = address(oracle);
      console.log('  Deployed mock ETH/USD Oracle:', ethUsdFeed);
    } else {
      console.log('  Using ETH/USD Feed:', ethUsdFeed);
    }

    if (augustusRegistry == address(0)) {
      MockAugustusRegistry registry = new MockAugustusRegistry();
      augustusRegistry = address(registry);
      console.log('  Deployed mock Augustus Registry:', augustusRegistry);
    } else {
      console.log('  Using Augustus Registry:', augustusRegistry);
    }
  }

  /// @notice Build the full market config from env vars and resolved dependencies.
  function _buildMarketConfig(
    address deployer,
    address wrappedNativeToken,
    address ethUsdFeed,
    address augustusRegistry
  )
    internal
    returns (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory report
    )
  {
    roles.marketOwner = deployer;
    roles.emergencyAdmin = deployer;
    roles.poolAdmin = deployer;

    config.marketId = vm.envOr('MARKET_ID', string('Aave V3 Market'));
    config.providerId = vm.envOr('PROVIDER_ID', uint256(block.chainid));
    config.oracleDecimals = 8;
    config.flashLoanPremium = 0.0005e4; // 0.05%

    config.networkBaseTokenPriceInUsdProxyAggregator = ethUsdFeed;
    config.marketReferenceCurrencyPriceInUsdProxyAggregator = ethUsdFeed;
    config.paraswapAugustusRegistry = augustusRegistry;
    config.wrappedNativeToken = wrappedNativeToken;

    // L2 config
    bool isL2 = vm.envOr('IS_L2', false);
    flags.l2 = isL2;
    config.l2SequencerUptimeFeed = address(0);
    config.l2PriceOracleSentinelGracePeriod = 0;

    // Let deployment create new treasury & incentives
    config.treasury = address(0);
    config.treasuryPartner = address(0);
    config.treasurySplitPercent = 0;
    config.incentivesProxy = address(0);
    config.salt = bytes32(0);

    console.log('  Market ID:', config.marketId);
    console.log('  Provider ID:', config.providerId);
    console.log('  L2:', isL2);
    console.log('');
  }

  /// @dev Required by MarketInput abstract but unused - config built via _buildMarketConfig.
  function _getMarketInput(
    address deployer
  )
    internal
    pure
    override
    returns (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory deployedContracts
    )
  {
    roles.marketOwner = deployer;
    roles.emergencyAdmin = deployer;
    roles.poolAdmin = deployer;
    config.marketId = 'Aave V3 Market';
    config.oracleDecimals = 8;
    config.flashLoanPremium = 0.0005e4;
  }

  function _logReport(MarketReport memory r) internal pure {
    console.log('--- Core Infrastructure ---');
    console.log('  PoolAddressesProvider:', r.poolAddressesProvider);
    console.log('  PoolAddressesProviderRegistry:', r.poolAddressesProviderRegistry);
    console.log('  ACLManager:', r.aclManager);
    console.log('');
    console.log('--- Pool ---');
    console.log('  Pool Proxy:', r.poolProxy);
    console.log('  Pool Implementation:', r.poolImplementation);
    console.log('  PoolConfigurator Proxy:', r.poolConfiguratorProxy);
    console.log('  PoolConfigurator Implementation:', r.poolConfiguratorImplementation);
    console.log('');
    console.log('--- Oracle ---');
    console.log('  AaveOracle:', r.aaveOracle);
    console.log('  Default Interest Rate Strategy:', r.defaultInterestRateStrategy);
    console.log('');
    console.log('--- Treasury ---');
    console.log('  Treasury (Collector):', r.treasury);
    console.log('  Treasury Implementation:', r.treasuryImplementation);
    if (r.revenueSplitter != address(0)) {
      console.log('  Revenue Splitter:', r.revenueSplitter);
    }
    console.log('');
    console.log('--- Rewards ---');
    console.log('  Emission Manager:', r.emissionManager);
    console.log('  RewardsController Proxy:', r.rewardsControllerProxy);
    console.log('  RewardsController Implementation:', r.rewardsControllerImplementation);
    console.log('');
    console.log('--- Token Implementations ---');
    console.log('  AToken Implementation:', r.aToken);
    console.log('  VariableDebtToken Implementation:', r.variableDebtToken);
    console.log('');
    console.log('--- UI Data Providers ---');
    console.log('  UiPoolDataProvider:', r.uiPoolDataProvider);
    console.log('  UiIncentiveDataProvider:', r.uiIncentiveDataProvider);
    console.log('  Protocol Data Provider:', r.protocolDataProvider);
    console.log('  Wallet Balance Provider:', r.walletBalanceProvider);
    console.log('');
    console.log('--- Helpers ---');
    console.log('  Wrapped Token Gateway:', r.wrappedTokenGateway);
    if (r.l2Encoder != address(0)) {
      console.log('  L2Encoder:', r.l2Encoder);
    }
    console.log('');
    console.log('--- ParaSwap Adapters ---');
    console.log('  Liquidity Swap Adapter:', r.paraSwapLiquiditySwapAdapter);
    console.log('  Repay Adapter:', r.paraSwapRepayAdapter);
    console.log('  Withdraw Swap Adapter:', r.paraSwapWithdrawSwapAdapter);
    console.log('');
    console.log('--- Config Engine ---');
    console.log('  Config Engine:', r.configEngine);
    console.log('');
    console.log('--- Static aToken ---');
    console.log('  Transparent Proxy Factory:', r.transparentProxyFactory);
    console.log('  StaticAToken Implementation:', r.staticATokenImplementation);
    console.log('  StaticAToken Factory Proxy:', r.staticATokenFactoryProxy);
    console.log('  StaticAToken Factory Implementation:', r.staticATokenFactoryImplementation);
  }
}
