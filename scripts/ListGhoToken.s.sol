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
 * @title ListGhoToken
 * @notice Script to list a GHO token fork on the Sepolia Aave V3 deployment
 * @dev Update the GHO_TOKEN and GHO_ORACLE addresses before running
 */
contract ListGhoToken is Script {
  // ============ Sepolia Aave V3 Deployment Addresses ============
  address constant POOL_ADDRESSES_PROVIDER = 0xc183d9509425B9f1e08320AE1612C2Ee7de7EC4D;
  address constant POOL_CONFIGURATOR = 0x888C7478060755Bb3E796D2F8534821202285aF1;
  address constant AAVE_ORACLE = 0xdA55C5b54655819118EeF2c32b8ff3b022a7Cb8c;
  address constant ACL_MANAGER = 0xf5ef7CaF1444a1396e909e07325f3a5Ff99dA69A;
  // TODO: Replace with your GHO price oracle address (or use a mock oracle)
  address constant GHO_ORACLE = address(0xB0C712f98daE15264c8E26132BCC91C40aD4d5F9); // <-- SET YOUR GHO ORACLE ADDRESS

  // ============ GHO Token Configuration - UPDATE THESE ============
  // TODO: Replace with your actual GHO token fork address
  address constant ATOKEN_IMPL = 0x6c08bd68e2ffdd93d13b2e54227cd6468551d0f8;
  address constant VAR_DEBT_TOKEN_IMPL = 0xa24683acfdb7b64ef89b0465c90702f06f0fc428;
  address constant GHO_TOKEN = address(0x9F88A8Ad79532AE619e4b70c520f534E78A5ba18); // <-- SET YOUR GHO TOKEN ADDRESS

  function run() external {
    require(GHO_TOKEN != address(0), 'GHO_TOKEN address not set');
    require(GHO_ORACLE != address(0), 'GHO_ORACLE address not set');

    console.log('=== Listing GHO Token Fork ===');
    console.log('');

    IPoolConfigurator configurator = IPoolConfigurator(POOL_CONFIGURATOR);
    IACLManager acl = IACLManager(ACL_MANAGER);
    IAaveOracle oracle = IAaveOracle(AAVE_ORACLE);

    address deployer = msg.sender;
    console.log('Deployer:', deployer);
    console.log('isPoolAdmin:', acl.isPoolAdmin(deployer));
    console.log('');

    console.log('GHO Token:', GHO_TOKEN);
    console.log('GHO Oracle:', GHO_ORACLE);
    console.log('');

    vm.startBroadcast();

    // Step 1: Set oracle source for GHO token
    console.log('Step 1: Setting oracle source...');
    address[] memory assets = new address[](1);
    address[] memory sources = new address[](1);
    assets[0] = GHO_TOKEN;
    sources[0] = GHO_ORACLE;
    oracle.setAssetSources(assets, sources);
    console.log('  Oracle source set');

    // Step 2: Prepare interest rate data for GHO (stablecoin-style rates)
    // GHO typically uses conservative rates since it's a stablecoin
    bytes memory rateData = abi.encode(
      IDefaultInterestRateStrategyV2.InterestRateData({
        optimalUsageRatio: 90_00, // 90% - high utilization target for stablecoins
        baseVariableBorrowRate: 0, // 0% base rate
        variableRateSlope1: 4_00, // 4% slope below optimal
        variableRateSlope2: 75_00 // 75% slope above optimal
      })
    );

    // Step 3: Initialize GHO reserve
    console.log('Step 2: Initializing reserve...');
    ConfiguratorInputTypes.InitReserveInput[] memory input = new ConfiguratorInputTypes.InitReserveInput[](1);
    input[0] = ConfiguratorInputTypes.InitReserveInput({
      aTokenImpl: ATOKEN_IMPL,
      variableDebtTokenImpl: VAR_DEBT_TOKEN_IMPL,
      underlyingAsset: GHO_TOKEN,
      aTokenName: 'sepUBC GHO',
      aTokenSymbol: 'sepUBC-GHO',
      variableDebtTokenName: 'sepUBC Variable Debt GHO',
      variableDebtTokenSymbol: 'sepUBC-varDebt-GHO',
      params: '',
      interestRateData: rateData
    });

    configurator.initReserves(input);
    console.log('  Reserve initialized');

    // Step 4: Configure GHO as collateral
    // GHO as stablecoin: high LTV, high LT, low LB
    console.log('Step 3: Configuring as collateral...');
    configurator.configureReserveAsCollateral(
      GHO_TOKEN,
      80_00, // LTV 80%
      85_00, // Liquidation Threshold 85%
      105_00 // Liquidation Bonus 5%
    );
    console.log('  Collateral config set');

    // Step 5: Set reserve parameters
    console.log('Step 4: Setting reserve parameters...');
    configurator.setReserveFactor(GHO_TOKEN, 10_00); // 10% reserve factor
    configurator.setSupplyCap(GHO_TOKEN, 10_000_000); // 10M supply cap
    configurator.setBorrowCap(GHO_TOKEN, 5_000_000); // 5M borrow cap
    console.log('  Reserve parameters set');

    // Step 6: Enable borrowing
    console.log('Step 5: Enabling borrowing...');
    configurator.setReserveBorrowing(GHO_TOKEN, true);
    console.log('  Borrowing enabled');

    // Step 7: Add to stablecoin EMode (category 1 if exists)
    console.log('Step 6: Adding to Stablecoin EMode...');
    configurator.setAssetCollateralInEMode(GHO_TOKEN, 1, true);
    console.log('  Added to EMode category 1');

    vm.stopBroadcast();

    // Verify
    console.log('');
    console.log('=== Verification ===');
    IPool pool = IPool(IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER).getPool());
    address aToken = pool.getReserveAToken(GHO_TOKEN);
    console.log('aToken address:', aToken);
    console.log('Reserve listed:', aToken != address(0));
    console.log('');
    console.log('=== GHO Token Listed Successfully! ===');
  }
}
