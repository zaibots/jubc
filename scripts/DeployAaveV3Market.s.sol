// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';
import 'forge-std/console.sol';

import {IPoolAddressesProvider} from '../src/contracts/interfaces/IPoolAddressesProvider.sol';
import {IPoolConfigurator} from '../src/contracts/interfaces/IPoolConfigurator.sol';
import {IPool} from '../src/contracts/interfaces/IPool.sol';
import {IACLManager} from '../src/contracts/interfaces/IACLManager.sol';
import {IAaveOracle} from '../src/contracts/interfaces/IAaveOracle.sol';
import {IDefaultInterestRateStrategyV2} from '../src/contracts/interfaces/IDefaultInterestRateStrategyV2.sol';
import {ConfiguratorInputTypes} from '../src/contracts/protocol/pool/PoolConfigurator.sol';

import {MarketConfig, UBCMarketConfig, NetworkAddresses} from './custom/config/MarketConfig.sol';

/**
 * @title DeployAaveV3Market
 * @notice Lists reserves on an existing Aave V3 deployment using UBCMarketConfig.
 *
 * @dev Reads the MarketConfig for each token and lists them with proper
 *      collateral config, rate strategies, caps, and EMode categories.
 *
 * @dev Environment variables:
 *   POOL_ADDRESSES_PROVIDER  - (required) Address of the deployed PoolAddressesProvider
 *   NETWORK                  - "mainnet" | "base" | "sepolia" (default: "mainnet")
 *   ATOKEN_IMPL              - Override aToken implementation (uses protocol default if unset)
 *   VAR_DEBT_TOKEN_IMPL      - Override variable debt token implementation (uses protocol default if unset)
 *
 * @dev Usage:
 *   POOL_ADDRESSES_PROVIDER=0x... NETWORK=mainnet \
 *     forge script scripts/DeployAaveV3Market.s.sol:DeployAaveV3Market --broadcast --rpc-url $RPC_URL
 */
contract DeployAaveV3Market is Script {
  uint256 constant RAY = 1e27;

  // Resolved from PoolAddressesProvider
  IPoolAddressesProvider public provider;
  IPoolConfigurator public configurator;
  IAaveOracle public oracle;
  IACLManager public acl;
  IPool public pool;

  // Token implementations
  address public aTokenImpl;
  address public varDebtTokenImpl;

  function run() external {
    address providerAddr = vm.envAddress('POOL_ADDRESSES_PROVIDER');
    provider = IPoolAddressesProvider(providerAddr);

    // Resolve core protocol addresses from the provider
    pool = IPool(provider.getPool());
    configurator = IPoolConfigurator(provider.getPoolConfigurator());
    oracle = IAaveOracle(provider.getPriceOracle());
    acl = IACLManager(provider.getACLManager());

    // Resolve token implementations (use overrides or fetch from pool report)
    aTokenImpl = vm.envOr('ATOKEN_IMPL', address(0));
    varDebtTokenImpl = vm.envOr('VAR_DEBT_TOKEN_IMPL', address(0));

    // If not overridden, we need them from the deployment report
    require(aTokenImpl != address(0), 'ATOKEN_IMPL env var required');
    require(varDebtTokenImpl != address(0), 'VAR_DEBT_TOKEN_IMPL env var required');

    console.log('===========================================');
    console.log('   Aave V3 Market Listing');
    console.log('===========================================');
    console.log('Deployer:', msg.sender);
    console.log('PoolAddressesProvider:', providerAddr);
    console.log('Pool:', address(pool));
    console.log('PoolConfigurator:', address(configurator));
    console.log('AaveOracle:', address(oracle));
    console.log('isPoolAdmin:', acl.isPoolAdmin(msg.sender));
    console.log('');

    // Load reserves for the target network
    string memory network = vm.envOr('NETWORK', string('mainnet'));

    vm.startBroadcast();

    if (_strEq(network, 'mainnet')) {
      _listMainnetReserves();
    } else if (_strEq(network, 'base')) {
      _listBaseReserves();
    } else {
      revert(string.concat('Unknown network: ', network));
    }

    // Configure EMode categories
    _configureEModes();

    vm.stopBroadcast();

    console.log('');
    console.log('===========================================');
    console.log('   MARKET LISTING COMPLETE!');
    console.log('===========================================');
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // NETWORK-SPECIFIC RESERVE LISTING
  // ══════════════════════════════════════════════════════════════════════════════

  function _listMainnetReserves() internal {
    NetworkAddresses.MainnetAddresses memory addrs = NetworkAddresses.getMainnetAddresses();

    MarketConfig.ReserveParams[] memory reserves = new MarketConfig.ReserveParams[](7);
    reserves[0] = UBCMarketConfig.getUSDCConfig(addrs.usdc, addrs.usdcUsdFeed);
    reserves[1] = UBCMarketConfig.getUSDTConfig(addrs.usdt, addrs.usdtUsdFeed);
    reserves[2] = UBCMarketConfig.getCbBTCConfig(addrs.cbBtc, addrs.cbBtcUsdFeed);
    reserves[3] = UBCMarketConfig.getLINKConfig(addrs.link, addrs.linkUsdFeed);
    reserves[4] = UBCMarketConfig.getFETConfig(addrs.fet, address(0)); // TODO: FET oracle
    reserves[5] = UBCMarketConfig.getRENDERConfig(addrs.render, address(0)); // TODO: RENDER oracle
    reserves[6] = UBCMarketConfig.getJpyUBIConfig(address(0), addrs.jpyUsdFeed); // TODO: jpyUBI token

    _listReserves(reserves);
  }

  function _listBaseReserves() internal {
    NetworkAddresses.BaseAddresses memory addrs = NetworkAddresses.getBaseAddresses();

    MarketConfig.ReserveParams[] memory reserves = new MarketConfig.ReserveParams[](4);
    reserves[0] = UBCMarketConfig.getUSDCConfig(addrs.usdc, addrs.usdcUsdFeed);
    reserves[1] = UBCMarketConfig.getUSDTConfig(addrs.usdt, addrs.usdtUsdFeed);
    reserves[2] = UBCMarketConfig.getCbBTCConfig(addrs.cbBtc, addrs.cbBtcUsdFeed);
    reserves[3] = UBCMarketConfig.getLINKConfig(addrs.link, addrs.linkUsdFeed);

    _listReserves(reserves);
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // CORE LISTING LOGIC
  // ══════════════════════════════════════════════════════════════════════════════

  function _listReserves(MarketConfig.ReserveParams[] memory reserves) internal {
    // First pass: set oracle sources for all reserves
    console.log('Setting oracle sources...');
    uint256 validCount;
    for (uint256 i = 0; i < reserves.length; i++) {
      if (reserves[i].tokenAddress != address(0) && reserves[i].oracleAddress != address(0)) {
        validCount++;
      }
    }

    address[] memory assets = new address[](validCount);
    address[] memory sources = new address[](validCount);
    uint256 idx;
    for (uint256 i = 0; i < reserves.length; i++) {
      if (reserves[i].tokenAddress != address(0) && reserves[i].oracleAddress != address(0)) {
        assets[idx] = reserves[i].tokenAddress;
        sources[idx] = reserves[i].oracleAddress;
        idx++;
      }
    }
    if (validCount > 0) {
      oracle.setAssetSources(assets, sources);
    }

    // Second pass: list each reserve
    for (uint256 i = 0; i < reserves.length; i++) {
      MarketConfig.ReserveParams memory r = reserves[i];

      // Skip reserves with missing addresses
      if (r.tokenAddress == address(0)) {
        console.log('  Skipping', r.symbol, '(no token address)');
        continue;
      }
      if (r.oracleAddress == address(0)) {
        console.log('  Skipping', r.symbol, '(no oracle address)');
        continue;
      }

      _listSingleReserve(r);
    }
  }

  function _listSingleReserve(MarketConfig.ReserveParams memory r) internal {
    console.log('  Listing', r.symbol);

    // Determine rate strategy based on asset type
    MarketConfig.RateStrategyParams memory rateStrategy;
    if (_strEq(r.symbol, 'jpyUBI')) {
      rateStrategy = MarketConfig.getRateStrategyJpyUBI();
    } else if (_strEq(r.symbol, 'VIRTUALS') || _strEq(r.symbol, 'FET') || _strEq(r.symbol, 'RENDER')) {
      rateStrategy = MarketConfig.getRateStrategyVolatile();
    } else {
      rateStrategy = MarketConfig.getRateStrategyReserveOne();
    }

    // Convert RAY rates to bps for InterestRateData
    bytes memory rateData = abi.encode(
      IDefaultInterestRateStrategyV2.InterestRateData({
        optimalUsageRatio: _rayToBps16(rateStrategy.optimalUsageRatio),
        baseVariableBorrowRate: _rayToBps32(rateStrategy.baseVariableBorrowRate),
        variableRateSlope1: _rayToBps32(rateStrategy.variableRateSlope1),
        variableRateSlope2: _rayToBps32(rateStrategy.variableRateSlope2)
      })
    );

    // Init reserve
    ConfiguratorInputTypes.InitReserveInput[] memory input = new ConfiguratorInputTypes.InitReserveInput[](1);
    input[0] = ConfiguratorInputTypes.InitReserveInput({
      aTokenImpl: aTokenImpl,
      variableDebtTokenImpl: varDebtTokenImpl,
      underlyingAsset: r.tokenAddress,
      aTokenName: string.concat('ubc', r.symbol),
      aTokenSymbol: string.concat('ubc-', r.symbol),
      variableDebtTokenName: string.concat('ubc Variable Debt ', r.symbol),
      variableDebtTokenSymbol: string.concat('ubc-varDebt-', r.symbol),
      params: '',
      interestRateData: rateData
    });
    configurator.initReserves(input);

    // Configure collateral (skip if LTV = 0, e.g. jpyUBI)
    if (r.baseLTVAsCollateral > 0) {
      configurator.configureReserveAsCollateral(
        r.tokenAddress,
        r.baseLTVAsCollateral,
        r.liquidationThreshold,
        r.liquidationBonus
      );
    }

    // Set reserve factor
    configurator.setReserveFactor(r.tokenAddress, r.reserveFactor);

    // Set caps
    if (r.supplyCap > 0) {
      configurator.setSupplyCap(r.tokenAddress, r.supplyCap);
    }
    if (r.borrowCap > 0) {
      configurator.setBorrowCap(r.tokenAddress, r.borrowCap);
    }

    // Set debt ceiling for isolation mode
    if (r.debtCeiling > 0) {
      configurator.setDebtCeiling(r.tokenAddress, r.debtCeiling);
    }

    // Enable borrowing
    if (r.borrowingEnabled) {
      configurator.setReserveBorrowing(r.tokenAddress, true);
    }

    // Set liquidation protocol fee
    if (r.liquidationProtocolFee > 0) {
      configurator.setLiquidationProtocolFee(r.tokenAddress, r.liquidationProtocolFee);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // EMODE CONFIG
  // ══════════════════════════════════════════════════════════════════════════════

  function _configureEModes() internal {
    console.log('Configuring EMode categories...');

    // Category 1: Stablecoins
    configurator.setEModeCategory(
      1,
      95_00, // LTV 95%
      97_00, // Liquidation Threshold 97%
      101_00, // Liquidation Bonus 1%
      'Stablecoins'
    );
    console.log('  Created Stablecoin EMode (id=1)');
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // HELPERS
  // ══════════════════════════════════════════════════════════════════════════════

  /// @notice Convert a RAY value (1e27 = 100%) to bps uint16 (10000 = 100%)
  function _rayToBps16(uint256 rayValue) internal pure returns (uint16) {
    return uint16((rayValue * 10000) / RAY);
  }

  /// @notice Convert a RAY value (1e27 = 100%) to bps uint32 (10000 = 100%)
  function _rayToBps32(uint256 rayValue) internal pure returns (uint32) {
    return uint32((rayValue * 10000) / RAY);
  }

  function _strEq(string memory a, string memory b) internal pure returns (bool) {
    return keccak256(bytes(a)) == keccak256(bytes(b));
  }
}
