// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Script, console2} from 'forge-std/Script.sol';
import {DirectMinter} from '../src/contracts/custom/facilitators/DirectMinter.sol';
import {IPoolConfigurator} from '../src/contracts/interfaces/IPoolConfigurator.sol';
import {ConfiguratorInputTypes} from '../src/contracts/protocol/libraries/types/ConfiguratorInputTypes.sol';

interface IGhoToken {
  function addFacilitator(address facilitator, string calldata label, uint128 capacity) external;
  function grantRole(bytes32 role, address account) external;
  function hasRole(bytes32 role, address account) external view returns (bool);
  function FACILITATOR_MANAGER_ROLE() external view returns (bytes32);
}

contract DeployDirectMiners is Script {
  address constant POOL = 0xAf29b85C97B28490E00A090bD1b4B552c69C7559;
  address constant POOL_CONFIGURATOR = 0x888C7478060755Bb3E796D2F8534821202285aF1;
  address constant AIEN = 0x9F88A8Ad79532AE619e4b70c520f534E78A5ba18;
  address constant GHO = 0xC2c5EA7578a7953aC4f28f094258348cF1e674F1;
  address constant YENX = 0x65474c0ACBeA902E3d0411b8831cC1028571eE49;

  // Standard implementations (used by other reserves like USDC, WETH, LINK)
  address constant STD_ATOKEN_IMPL = 0x7a4c67d348f771261a59a00F0b9883873F97acfE;
  address constant STD_VAR_DEBT_IMPL = 0xC2Fe08be2d3a8296A1a1D8a540f707B07B2b1d99;

  uint128 constant BUCKET_CAPACITY = 100_000_000e18; // 100M per facilitator
  uint256 constant SUPPLY_AMOUNT = 10_000_000e18; // 10M initial supply

  function run() external {
    address deployer = msg.sender;
    IPoolConfigurator configurator = IPoolConfigurator(POOL_CONFIGURATOR);

    vm.startBroadcast();

    // ═══════════════════════════════════════════════════════════════
    // STEP 1: Upgrade AIEN and GHO from GhoAToken to standard AToken
    // ═══════════════════════════════════════════════════════════════
    console2.log('>>> Step 1: Upgrading aToken implementations...');

    configurator.updateAToken(ConfiguratorInputTypes.UpdateATokenInput({
      asset: AIEN,
      name: 'sepUBC AIEN',
      symbol: 'sepUBC-AIEN',
      implementation: STD_ATOKEN_IMPL,
      params: bytes('')
    }));
    console2.log('  AIEN aToken upgraded to standard');

    configurator.updateAToken(ConfiguratorInputTypes.UpdateATokenInput({
      asset: GHO,
      name: 'sepUBC GHO',
      symbol: 'sepUBC-GHO',
      implementation: STD_ATOKEN_IMPL,
      params: bytes('')
    }));
    console2.log('  GHO aToken upgraded to standard');

    // ═══════════════════════════════════════════════════════════════
    // STEP 2: Upgrade variable debt tokens to standard
    // ═══════════════════════════════════════════════════════════════
    console2.log('>>> Step 2: Upgrading varDebt implementations...');

    configurator.updateVariableDebtToken(ConfiguratorInputTypes.UpdateDebtTokenInput({
      asset: AIEN,
      name: 'sepUBC Variable Debt AIEN',
      symbol: 'sepUBC-varDebt-AIEN',
      implementation: STD_VAR_DEBT_IMPL,
      params: bytes('')
    }));
    console2.log('  AIEN varDebt upgraded to standard');

    configurator.updateVariableDebtToken(ConfiguratorInputTypes.UpdateDebtTokenInput({
      asset: GHO,
      name: 'sepUBC Variable Debt GHO',
      symbol: 'sepUBC-varDebt-GHO',
      implementation: STD_VAR_DEBT_IMPL,
      params: bytes('')
    }));
    console2.log('  GHO varDebt upgraded to standard');

    // ═══════════════════════════════════════════════════════════════
    // STEP 3: Grant FACILITATOR_MANAGER_ROLE on YENX
    // ═══════════════════════════════════════════════════════════════
    IGhoToken yenx = IGhoToken(YENX);
    bytes32 facilitatorRole = yenx.FACILITATOR_MANAGER_ROLE();
    if (!yenx.hasRole(facilitatorRole, deployer)) {
      yenx.grantRole(facilitatorRole, deployer);
      console2.log('  Granted FACILITATOR_MANAGER_ROLE on YENX');
    }

    // ═══════════════════════════════════════════════════════════════
    // STEP 4: Deploy DirectMinters
    // ═══════════════════════════════════════════════════════════════
    console2.log('>>> Step 3: Deploying DirectMinters...');

    DirectMinter aienMinter = new DirectMinter(POOL, AIEN, deployer);
    console2.log('  AIEN DirectMinter:', address(aienMinter));

    DirectMinter ghoMinter = new DirectMinter(POOL, GHO, deployer);
    console2.log('  GHO DirectMinter:', address(ghoMinter));

    DirectMinter yenxMinter = new DirectMinter(POOL, YENX, deployer);
    console2.log('  YENX DirectMinter:', address(yenxMinter));

    // ═══════════════════════════════════════════════════════════════
    // STEP 5: Register as facilitators
    // ═══════════════════════════════════════════════════════════════
    console2.log('>>> Step 4: Registering facilitators...');

    IGhoToken(AIEN).addFacilitator(address(aienMinter), 'AIEN Direct Minter', BUCKET_CAPACITY);
    IGhoToken(GHO).addFacilitator(address(ghoMinter), 'GHO Direct Minter', BUCKET_CAPACITY);
    yenx.addFacilitator(address(yenxMinter), 'YENX Direct Minter', BUCKET_CAPACITY);
    console2.log('  All facilitators registered');

    // ═══════════════════════════════════════════════════════════════
    // STEP 6: Mint and supply 10M each
    // ═══════════════════════════════════════════════════════════════
    console2.log('>>> Step 5: Minting and supplying 10M each...');

    aienMinter.mintAndSupply(SUPPLY_AMOUNT);
    console2.log('  Supplied 10M AIEN');

    ghoMinter.mintAndSupply(SUPPLY_AMOUNT);
    console2.log('  Supplied 10M GHO');

    yenxMinter.mintAndSupply(SUPPLY_AMOUNT);
    console2.log('  Supplied 10M YENX');

    vm.stopBroadcast();

    console2.log('');
    console2.log('=== DEPLOYMENT COMPLETE ===');
    console2.log('AIEN DirectMinter:', address(aienMinter));
    console2.log('GHO DirectMinter:', address(ghoMinter));
    console2.log('YENX DirectMinter:', address(yenxMinter));
  }
}
