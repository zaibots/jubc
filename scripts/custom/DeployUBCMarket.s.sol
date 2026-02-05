// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Script, console2} from 'forge-std/Script.sol';
import {MarketConfig as UBCMarketConfigLib, UBCMarketConfig, NetworkAddresses} from './config/MarketConfig.sol';

// Aave V3 deployment framework
import {MarketInput} from '../../src/deployments/inputs/MarketInput.sol';
import '../../src/deployments/interfaces/IMarketReportTypes.sol';
import {AaveV3BatchOrchestration} from '../../src/deployments/projects/aave-v3-batched/AaveV3BatchOrchestration.sol';
import {IMetadataReporter} from '../../src/deployments/interfaces/IMetadataReporter.sol';
import {DeployUtils} from '../../src/deployments/contracts/utilities/DeployUtils.sol';
import {IDefaultInterestRateStrategyV2} from '../../src/contracts/interfaces/IDefaultInterestRateStrategyV2.sol';

// Aave V3 interfaces for post-deployment config
import {IPoolConfigurator} from '../../src/contracts/interfaces/IPoolConfigurator.sol';
import {IAaveOracle} from '../../src/contracts/interfaces/IAaveOracle.sol';
import {IACLManager} from '../../src/contracts/interfaces/IACLManager.sol';
import {IPoolAddressesProvider} from '../../src/contracts/interfaces/IPoolAddressesProvider.sol';
import {ConfiguratorInputTypes} from '../../src/contracts/protocol/libraries/types/ConfiguratorInputTypes.sol';

// Custom protocol imports
import {DataStreamAggregatorAdapter} from 'custom/oracles/DataStreamAggregatorAdapter.sol';
import {JpyUbiAMOMinter} from 'custom/amo/JpyUbiAMOMinter.sol';
import {JpyUbiConvexAMO} from 'custom/amo/JpyUbiConvexAMO.sol';
import {MorphoVaultV1Adapter} from 'custom/integrations/morpho/adapters/MorphoVaultV1Adapter.sol';

// Interface for jUBC token (GHO-compatible)
interface IJUBCToken {
  function grantRole(bytes32 role, address account) external;
  function addFacilitator(address facilitator, string calldata label, uint128 capacity) external;
}

/**
 * @title DeployUBCMarket
 * @notice Main deployment script for UBC Market - deploys full Aave V3 + custom components
 * @dev Run with: forge script scripts/custom/DeployUBCMarket.s.sol:DeployUBCMarket --rpc-url $RPC_URL --broadcast
 */
contract DeployUBCMarket is DeployUtils, MarketInput, Script {
  // ══════════════════════════════════════════════════════════════════════════════
  // CUSTOM DEPLOYED CONTRACTS
  // ══════════════════════════════════════════════════════════════════════════════

  address public jUBCToken;
  DataStreamAggregatorAdapter public jpyUsdOracle;
  JpyUbiAMOMinter public amoMinter;
  MorphoVaultV1Adapter public morphoAdapter;

  // ══════════════════════════════════════════════════════════════════════════════
  // CONFIGURATION
  // ══════════════════════════════════════════════════════════════════════════════

  address public admin;
  address public treasuryAddress;

  // Chainlink Data Streams
  address public verifierProxy;
  bytes32 public jpyUsdFeedId;

  // External addresses (set per network)
  address public wrappedNative;
  address public usdcAddress;
  address public usdcOracle;

  // ══════════════════════════════════════════════════════════════════════════════
  // MARKET INPUT IMPLEMENTATION
  // ══════════════════════════════════════════════════════════════════════════════

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
    // Set roles - deployer is used for all roles initially
    roles.marketOwner = deployer;
    roles.emergencyAdmin = deployer;
    roles.poolAdmin = deployer;

    // Configure market
    config.marketId = 'ZaiBots UBC Market';
    config.providerId = 42; // Unique provider ID for ZaiBots
    config.oracleDecimals = 8;
    config.flashLoanPremium = 0.0005e4; // 0.05%

    // L1 deployment (not L2)
    flags.l2 = false;

    return (roles, config, flags, deployedContracts);
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // MAIN DEPLOYMENT
  // ══════════════════════════════════════════════════════════════════════════════

  function run() external {
    _loadConfig();

    console2.log('========================================');
    console2.log('ZAIBOTS UBC MARKET DEPLOYMENT');
    console2.log('========================================');
    console2.log('Deployer:', msg.sender);
    console2.log('Admin:', admin);

    // Get market input
    Roles memory roles;
    MarketConfig memory config;
    DeployFlags memory flags;
    MarketReport memory report;

    (roles, config, flags, report) = _getMarketInput(msg.sender);

    // Override roles with loaded config if set
    if (admin != address(0) && admin != msg.sender) {
      roles.marketOwner = admin;
      roles.emergencyAdmin = admin;
      roles.poolAdmin = admin;
    }

    // Set network-specific config
    config.wrappedNativeToken = wrappedNative;
    config.treasury = treasuryAddress;

    vm.startBroadcast();

    // ════════════════════════════════════════════════════════════════════════════
    // STEP 1: Deploy full Aave V3 protocol
    // ════════════════════════════════════════════════════════════════════════════
    console2.log('');
    console2.log('>>> Step 1: Deploying Aave V3 Protocol...');

    report = AaveV3BatchOrchestration.deployAaveV3(msg.sender, roles, config, flags, report);

    console2.log('Aave V3 deployed successfully');
    console2.log('  Pool:', report.poolProxy);
    console2.log('  PoolConfigurator:', report.poolConfiguratorProxy);
    console2.log('  AaveOracle:', report.aaveOracle);
    console2.log('  ACLManager:', report.aclManager);

    // ════════════════════════════════════════════════════════════════════════════
    // STEP 2: Use existing jUBC Token (passed via JUBC_TOKEN env var)
    // ════════════════════════════════════════════════════════════════════════════
    console2.log('');
    console2.log('>>> Step 2: Using existing jUBC Token...');
    console2.log('  JUBCToken:', jUBCToken);

    // ════════════════════════════════════════════════════════════════════════════
    // STEP 3: Deploy Oracle
    // ════════════════════════════════════════════════════════════════════════════
    console2.log('');
    console2.log('>>> Step 3: Deploying JPY/USD Oracle...');

    jpyUsdOracle = new DataStreamAggregatorAdapter(verifierProxy, jpyUsdFeedId, 8, 'JPY / USD');
    console2.log('  JpyUsdOracle:', address(jpyUsdOracle));

    // ════════════════════════════════════════════════════════════════════════════
    // STEP 4: Discount Rate Strategy (skipped - deploy separately if needed)
    // ════════════════════════════════════════════════════════════════════════════
    console2.log('');
    console2.log('>>> Step 4: Discount Rate Strategy skipped (deploy separately if needed)');

    // ════════════════════════════════════════════════════════════════════════════
    // STEP 5: Deploy AMO Minter
    // ════════════════════════════════════════════════════════════════════════════
    console2.log('');
    console2.log('>>> Step 5: Deploying AMO Minter...');

    uint256 globalMintCap = 100_000_000e18; // 100M jUBC
    amoMinter = new JpyUbiAMOMinter(jUBCToken, globalMintCap);
    console2.log('  AMOMinter:', address(amoMinter));

    // ════════════════════════════════════════════════════════════════════════════
    // STEP 6: Configure jUBC token roles
    // ════════════════════════════════════════════════════════════════════════════
    console2.log('');
    console2.log('>>> Step 6: Configuring jUBC roles...');

    bytes32 FACILITATOR_MANAGER_ROLE = keccak256('FACILITATOR_MANAGER_ROLE');
    bytes32 BUCKET_MANAGER_ROLE = keccak256('BUCKET_MANAGER_ROLE');

    IJUBCToken(jUBCToken).grantRole(FACILITATOR_MANAGER_ROLE, admin);
    IJUBCToken(jUBCToken).grantRole(BUCKET_MANAGER_ROLE, admin);
    jpyUsdOracle.setKeeperAuthorization(admin, true);

    console2.log('  Roles configured');

    // ════════════════════════════════════════════════════════════════════════════
    // STEP 7: Configure jUBC as reserve in Aave pool
    // ════════════════════════════════════════════════════════════════════════════
    console2.log('');
    console2.log('>>> Step 7: Configuring jUBC as Aave reserve...');

    _configureJUBCReserve(report);

    // ════════════════════════════════════════════════════════════════════════════
    // STEP 8: Add Pool as jUBC Facilitator
    // ════════════════════════════════════════════════════════════════════════════
    console2.log('');
    console2.log('>>> Step 8: Adding Pool as jUBC Facilitator...');

    // The aToken will be the facilitator that can mint/burn jUBC
    // Need to get the aToken address after reserve init
    // For now, add the pool as facilitator with high capacity
    IJUBCToken(jUBCToken).addFacilitator(report.poolProxy, 'Aave V3 Pool', 500_000_000e18); // 500M capacity
    console2.log('  Pool added as facilitator');

    vm.stopBroadcast();

    // ════════════════════════════════════════════════════════════════════════════
    // FINAL: Log all deployed addresses
    // ════════════════════════════════════════════════════════════════════════════
    _logDeployedAddresses(report);

    // Write market deployment JSON report
    IMetadataReporter metadataReporter = IMetadataReporter(
      _deployFromArtifacts('MetadataReporter.sol:MetadataReporter')
    );
    metadataReporter.writeJsonReportMarket(report);
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // INTERNAL FUNCTIONS
  // ══════════════════════════════════════════════════════════════════════════════

  function _loadConfig() internal {
    admin = vm.envOr('ADMIN', msg.sender);
    treasuryAddress = vm.envOr('TREASURY', msg.sender);

    // jUBC token address (required - must be deployed separately)
    jUBCToken = vm.envAddress('JUBC_TOKEN');
    require(jUBCToken != address(0), 'JUBC_TOKEN env var required');

    // Chainlink Data Streams config
    verifierProxy = vm.envOr('VERIFIER_PROXY', address(0x2ff010DEbC1297f19579B4246cad07bd24F2488A));
    jpyUsdFeedId = vm.envOr('JPY_USD_FEED_ID', keccak256('JPY/USD'));

    // Network addresses - default to mainnet
    wrappedNative = vm.envOr('WRAPPED_NATIVE', address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)); // WETH
    usdcAddress = vm.envOr('USDC', address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));
    usdcOracle = vm.envOr('USDC_ORACLE', address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6));
  }

  function _configureJUBCReserve(MarketReport memory report) internal {
    IPoolConfigurator configurator = IPoolConfigurator(report.poolConfiguratorProxy);
    IAaveOracle oracle = IAaveOracle(report.aaveOracle);

    // Set jUBC price in oracle
    address[] memory assets = new address[](1);
    address[] memory sources = new address[](1);
    assets[0] = jUBCToken;
    sources[0] = address(jpyUsdOracle);
    oracle.setAssetSources(assets, sources);

    // Initialize jUBC reserve
    // Encode interest rate data for the default strategy
    IDefaultInterestRateStrategyV2.InterestRateData memory rateData = IDefaultInterestRateStrategyV2.InterestRateData({
      optimalUsageRatio: 90_00, // 90%
      baseVariableBorrowRate: 0,
      variableRateSlope1: 2_00, // 2%
      variableRateSlope2: 60_00 // 60%
    });

    ConfiguratorInputTypes.InitReserveInput[] memory initInputs = new ConfiguratorInputTypes.InitReserveInput[](1);
    initInputs[0] = ConfiguratorInputTypes.InitReserveInput({
      aTokenImpl: report.aToken,
      variableDebtTokenImpl: report.variableDebtToken,
      underlyingAsset: jUBCToken,
      aTokenName: 'ZaiBots jUBC',
      aTokenSymbol: 'aJUBC',
      variableDebtTokenName: 'ZaiBots Variable Debt jUBC',
      variableDebtTokenSymbol: 'variableDebtJUBC',
      params: bytes(''),
      interestRateData: abi.encode(rateData)
    });

    configurator.initReserves(initInputs);

    // Configure jUBC reserve parameters (borrow-only, no collateral)
    configurator.setReserveBorrowing(jUBCToken, true);
    configurator.setBorrowCap(jUBCToken, 500_000_000); // 500M jUBC borrow cap
    configurator.setReserveFlashLoaning(jUBCToken, false);

    // jUBC is not collateral (LTV = 0)
    configurator.configureReserveAsCollateral(
      jUBCToken,
      0, // ltv
      0, // liquidationThreshold
      0 // liquidationBonus
    );

    // Enable borrowing in isolation mode
    configurator.setBorrowableInIsolation(jUBCToken, true);

    console2.log('  jUBC reserve configured');
  }

  function _logDeployedAddresses(MarketReport memory report) internal view {
    console2.log('');
    console2.log('========================================');
    console2.log('DEPLOYMENT COMPLETE');
    console2.log('========================================');
    console2.log('');
    console2.log('--- Aave V3 Core ---');
    console2.log('PoolAddressesProvider:', report.poolAddressesProvider);
    console2.log('Pool:', report.poolProxy);
    console2.log('PoolConfigurator:', report.poolConfiguratorProxy);
    console2.log('AaveOracle:', report.aaveOracle);
    console2.log('ACLManager:', report.aclManager);
    console2.log('Treasury:', report.treasury);
    console2.log('');
    console2.log('--- Aave V3 Tokens ---');
    console2.log('AToken Implementation:', report.aToken);
    console2.log('VariableDebtToken Implementation:', report.variableDebtToken);
    console2.log('');
    console2.log('--- Aave V3 Periphery ---');
    console2.log('ProtocolDataProvider:', report.protocolDataProvider);
    console2.log('ConfigEngine:', report.configEngine);
    console2.log('RewardsController:', report.rewardsControllerProxy);
    console2.log('');
    console2.log('--- Custom Contracts ---');
    console2.log('JUBCToken:', jUBCToken);
    console2.log('JpyUsdOracle:', address(jpyUsdOracle));
    console2.log('AMOMinter:', address(amoMinter));
    console2.log('========================================');
  }
}

/**
 * @title DeployOracle
 * @notice Deploys oracle contracts
 */
contract DeployOracle is Script {
  function run() external {
    address deployer = vm.envOr('DEPLOYER', msg.sender);
    address verifierProxy = vm.envOr('VERIFIER_PROXY', address(0x2ff010DEbC1297f19579B4246cad07bd24F2488A));
    bytes32 feedId = vm.envOr('FEED_ID', keccak256('JPY/USD'));

    vm.startBroadcast(deployer);

    DataStreamAggregatorAdapter oracle = new DataStreamAggregatorAdapter(verifierProxy, feedId, 8, 'JPY / USD');

    console2.log('DataStreamAggregatorAdapter deployed at:', address(oracle));

    // Authorize deployer as keeper
    oracle.setKeeperAuthorization(deployer, true);

    vm.stopBroadcast();
  }
}

/**
 * @title ConfigureFacilitator
 * @notice Configures a facilitator for jUBC token
 */
contract ConfigureFacilitator is Script {
  function run() external {
    address deployer = vm.envOr('DEPLOYER', msg.sender);
    address jUBCAddress = vm.envAddress('JUBC_ADDRESS');
    address facilitator = vm.envAddress('FACILITATOR');
    string memory label = vm.envOr('LABEL', string('Aave V3 Pool'));
    uint128 capacity = uint128(vm.envOr('CAPACITY', uint256(100_000_000e18)));

    vm.startBroadcast(deployer);

    IJUBCToken(jUBCAddress).addFacilitator(facilitator, label, capacity);

    console2.log('Facilitator added:');
    console2.log('  Address:', facilitator);
    console2.log('  Label:', label);
    console2.log('  Capacity:', capacity);

    vm.stopBroadcast();
  }
}
