// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {IPool} from '../../interfaces/IPool.sol';

interface IGhoFacilitator {
  function mint(address account, uint256 amount) external;
  function burn(uint256 amount) external;
  function getFacilitatorBucket(address facilitator) external view returns (uint256, uint256);
}

/**
 * @title DirectMinter
 * @notice GHO Facilitator that mints tokens and supplies them to an Aave V3 pool.
 * @dev Replaces the legacy GhoAToken pattern. Works with standard aToken/vToken
 *      implementations on Aave V3.4+/V3.6 where virtual accounting is always enabled.
 *
 *      Flow: DirectMinter.mint() → GhoToken.mint(this) → IERC20.approve(pool) → Pool.supply()
 *      Users borrow from the supplied liquidity like any normal reserve.
 *
 *      Must be registered as a facilitator on the GHO token before use:
 *        ghoToken.addFacilitator(address(directMinter), "Direct Minter", bucketCapacity)
 */
contract DirectMinter {
  IPool public immutable POOL;
  address public immutable GHO_TOKEN;
  address public owner;

  event Supplied(uint256 amount);
  event Withdrawn(uint256 amount);
  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

  modifier onlyOwner() {
    require(msg.sender == owner, 'ONLY_OWNER');
    _;
  }

  constructor(address pool, address ghoToken, address _owner) {
    POOL = IPool(pool);
    GHO_TOKEN = ghoToken;
    owner = _owner;
    IERC20(ghoToken).approve(pool, type(uint256).max);
  }

  /**
   * @notice Mint GHO via facilitator mechanism and supply to the Aave pool.
   * @param amount Amount of GHO to mint and supply
   */
  function mintAndSupply(uint256 amount) external onlyOwner {
    IGhoFacilitator(GHO_TOKEN).mint(address(this), amount);
    POOL.supply(GHO_TOKEN, amount, address(this), 0);
    emit Supplied(amount);
  }

  /**
   * @notice Withdraw GHO from the Aave pool and burn via facilitator mechanism.
   * @param amount Amount of GHO to withdraw and burn (type(uint256).max for all)
   */
  function withdrawAndBurn(uint256 amount) external onlyOwner {
    uint256 withdrawn = POOL.withdraw(GHO_TOKEN, amount, address(this));
    IGhoFacilitator(GHO_TOKEN).burn(withdrawn);
    emit Withdrawn(withdrawn);
  }

  /**
   * @notice Returns remaining mintable capacity for this facilitator.
   */
  function remainingCapacity() external view returns (uint256) {
    (uint256 capacity, uint256 level) = IGhoFacilitator(GHO_TOKEN).getFacilitatorBucket(address(this));
    return capacity - level;
  }

  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), 'ZERO_ADDRESS');
    emit OwnershipTransferred(owner, newOwner);
    owner = newOwner;
  }
}
