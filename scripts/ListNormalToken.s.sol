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

/**
 * @title ListNormalToken
 * @notice Script to list a normal token on the Sepolia Aave V3 deployment
 * @dev Update the TOKEN and TOKEN_ORACLE addresses before running
 */
contract ListNormalToken is Script {
  // ============ Sepolia Aave V3 Deployment Addresses ============
  address constant POOL_ADDRESSES_PROVIDER = 0xc183d9509425B9f1e08320AE1612C2Ee7de7EC4D;
  address constant POOL_CONFIGURATOR = 0x888C7478060755Bb3E796D2F8534821202285aF1;
  address constant ATOKEN_IMPL = 0x7a4c67d348f771261a59a00F0b9883873F97acfE;
  address constant VAR_DEBT_TOKEN_IMPL = 0xC2Fe08be2d3a8296A1a1D8a540f707B07B2b1d99;
  address constant AAVE_ORACLE = 0xdA55C5b54655819118EeF2c32b8ff3b022a7Cb8c;
  address constant ACL_MANAGER = 0xf5ef7CaF1444a1396e909e07325f3a5Ff99dA69A;

  // ============ Token Configuration - UPDATE THESE ============
  // TODO: Replace with your actual token address
  address constant TOKEN = address(0); // <-- SET YOUR TOKEN ADDRESS
  // TODO: Replace with your token price oracle address (or use a mock oracle)
  address constant TOKEN_ORACLE = address(0); // <-- SET YOUR TOKEN ORACLE ADDRESS

  function run() external {
    require(TOKEN != address(0), 'TOKEN address not set');
    require(TOKEN_ORACLE != address(0), 'TOKEN_ORACLE address not set');

    console.log('=== Listing Token ===');
    console.log('');

    IPoolConfigurator configurator = IPoolConfigurator(POOL_CONFIGURATOR);
    IACLManager acl = IACLManager(ACL_MANAGER);
    IAaveOracle oracle = IAaveOracle(AAVE_ORACLE);

    address deployer = msg.sender;
    console.log('Deployer:', deployer);
    console.log('isPoolAdmin:', acl.isPoolAdmin(deployer));
    console.log('');

    console.log('Token:', TOKEN);
    console.log('Token Oracle:', TOKEN_ORACLE);
    console.log('');

    vm.startBroadcast();

    // Step 1: Set oracle source for token
    console.log('Step 1: Setting oracle source...');
    address[] memory assets = new address[](1);
    address[] memory sources = new address[](1);
    assets[0] = TOKEN;
    sources[0] = TOKEN_ORACLE;
    oracle.setAssetSources(assets, sources);
    console.log('  Oracle source set');

    // Step 2: Prepare interest rate data for token (stablecoin-style rates)
    bytes memory rateData = abi.encode(
      IDefaultInterestRateStrategyV2.InterestRateData({
        optimalUsageRatio: 90_00, // 90% - high utilization target for stablecoins
        baseVariableBorrowRate: 0, // 0% base rate
        variableRateSlope1: 4_00, // 4% slope below optimal
        variableRateSlope2: 75_00 // 75% slope above optimal
      })
    );

    // Step 3: Initialize reserve
    console.log('Step 2: Initializing reserve...');
    ConfiguratorInputTypes.InitReserveInput[] memory input = new ConfiguratorInputTypes.InitReserveInput[](1);
    input[0] = ConfiguratorInputTypes.InitReserveInput({
      aTokenImpl: ATOKEN_IMPL,
      variableDebtTokenImpl: VAR_DEBT_TOKEN_IMPL,
      underlyingAsset: TOKEN,
      aTokenName: 'sepUBC Token',
      aTokenSymbol: 'sepUBC-TOKEN',
      variableDebtTokenName: 'sepUBC Variable Debt Token',
      variableDebtTokenSymbol: 'sepUBC-varDebt-TOKEN',
      params: '',
      interestRateData: rateData
    });

    configurator.initReserves(input);
    console.log('  Reserve initialized');

    // Step 4: Configure token as collateral
    console.log('Step 3: Configuring as collateral...');
    configurator.configureReserveAsCollateral(
      TOKEN,
      80_00, // LTV 80%
      85_00, // Liquidation Threshold 85%
      105_00 // Liquidation Bonus 5%
    );
    console.log('  Collateral config set');

    // Step 5: Set reserve parameters
    console.log('Step 4: Setting reserve parameters...');
    configurator.setReserveFactor(TOKEN, 10_00); // 10% reserve factor
    configurator.setSupplyCap(TOKEN, 10_000_000); // 10M supply cap
    configurator.setBorrowCap(TOKEN, 5_000_000); // 5M borrow cap
    console.log('  Reserve parameters set');

    // Step 6: Enable borrowing
    console.log('Step 5: Enabling borrowing...');
    configurator.setReserveBorrowing(TOKEN, true);
    console.log('  Borrowing enabled');

    // Step 7: Add to stablecoin EMode (category 1 if exists)
    console.log('Step 6: Adding to Stablecoin EMode...');
    configurator.setAssetCollateralInEMode(TOKEN, 1, true);
    console.log('  Added to EMode category 1');

    vm.stopBroadcast();

    // Verify
    console.log('');
    console.log('=== Verification ===');
    IPool pool = IPool(IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER).getPool());
    address aToken = pool.getReserveAToken(TOKEN);
    console.log('aToken address:', aToken);
    console.log('Reserve listed:', aToken != address(0));
    console.log('');
    console.log('=== Token Listed Successfully! ===');
  }
}
