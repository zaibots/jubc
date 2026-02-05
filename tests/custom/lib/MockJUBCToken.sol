// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {ERC20} from 'openzeppelin-contracts/contracts/token/ERC20/ERC20.sol';
import {AccessControl} from 'openzeppelin-contracts/contracts/access/AccessControl.sol';

/**
 * @title MockJUBCToken
 * @notice Mock GHO-like token for testing purposes
 * @dev Simplified version with facilitator bucket mechanics
 */
contract MockJUBCToken is ERC20, AccessControl {
  struct Facilitator {
    uint128 bucketCapacity;
    uint128 bucketLevel;
    string label;
  }

  mapping(address => Facilitator) internal _facilitators;
  address[] internal _facilitatorsList;

  bytes32 public constant FACILITATOR_MANAGER_ROLE = keccak256('FACILITATOR_MANAGER_ROLE');
  bytes32 public constant BUCKET_MANAGER_ROLE = keccak256('BUCKET_MANAGER_ROLE');

  event FacilitatorAdded(address indexed facilitatorAddress, bytes32 indexed label, uint256 bucketCapacity);
  event FacilitatorRemoved(address indexed facilitatorAddress);
  event FacilitatorBucketCapacityUpdated(address indexed facilitatorAddress, uint256 oldCapacity, uint256 newCapacity);
  event FacilitatorBucketLevelUpdated(address indexed facilitatorAddress, uint256 oldLevel, uint256 newLevel);

  constructor(address admin) ERC20('Mock JUBC Token', 'mJUBC') {
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(FACILITATOR_MANAGER_ROLE, admin);
    _grantRole(BUCKET_MANAGER_ROLE, admin);
  }

  function mint(address account, uint256 amount) external {
    require(amount > 0, 'INVALID_MINT_AMOUNT');
    Facilitator storage f = _facilitators[msg.sender];

    uint256 currentBucketLevel = f.bucketLevel;
    uint256 newBucketLevel = currentBucketLevel + amount;
    require(f.bucketCapacity >= newBucketLevel, 'FACILITATOR_BUCKET_CAPACITY_EXCEEDED');
    f.bucketLevel = uint128(newBucketLevel);

    _mint(account, amount);

    emit FacilitatorBucketLevelUpdated(msg.sender, currentBucketLevel, newBucketLevel);
  }

  function burn(uint256 amount) external {
    require(amount > 0, 'INVALID_BURN_AMOUNT');

    Facilitator storage f = _facilitators[msg.sender];
    uint256 currentBucketLevel = f.bucketLevel;
    uint256 newBucketLevel = currentBucketLevel - amount;
    f.bucketLevel = uint128(newBucketLevel);

    _burn(msg.sender, amount);

    emit FacilitatorBucketLevelUpdated(msg.sender, currentBucketLevel, newBucketLevel);
  }

  function addFacilitator(
    address facilitatorAddress,
    string calldata facilitatorLabel,
    uint128 bucketCapacity
  ) external onlyRole(FACILITATOR_MANAGER_ROLE) {
    Facilitator storage facilitator = _facilitators[facilitatorAddress];
    require(bytes(facilitator.label).length == 0, 'FACILITATOR_ALREADY_EXISTS');
    require(bytes(facilitatorLabel).length > 0, 'INVALID_LABEL');

    facilitator.label = facilitatorLabel;
    facilitator.bucketCapacity = bucketCapacity;

    _facilitatorsList.push(facilitatorAddress);

    emit FacilitatorAdded(facilitatorAddress, keccak256(abi.encodePacked(facilitatorLabel)), bucketCapacity);
  }

  function removeFacilitator(address facilitatorAddress) external onlyRole(FACILITATOR_MANAGER_ROLE) {
    require(bytes(_facilitators[facilitatorAddress].label).length > 0, 'FACILITATOR_DOES_NOT_EXIST');
    require(_facilitators[facilitatorAddress].bucketLevel == 0, 'FACILITATOR_BUCKET_LEVEL_NOT_ZERO');

    delete _facilitators[facilitatorAddress];

    // Remove from list
    for (uint256 i = 0; i < _facilitatorsList.length; i++) {
      if (_facilitatorsList[i] == facilitatorAddress) {
        _facilitatorsList[i] = _facilitatorsList[_facilitatorsList.length - 1];
        _facilitatorsList.pop();
        break;
      }
    }

    emit FacilitatorRemoved(facilitatorAddress);
  }

  function setFacilitatorBucketCapacity(
    address facilitator,
    uint128 newCapacity
  ) external onlyRole(BUCKET_MANAGER_ROLE) {
    require(bytes(_facilitators[facilitator].label).length > 0, 'FACILITATOR_DOES_NOT_EXIST');

    uint256 oldCapacity = _facilitators[facilitator].bucketCapacity;
    _facilitators[facilitator].bucketCapacity = newCapacity;

    emit FacilitatorBucketCapacityUpdated(facilitator, oldCapacity, newCapacity);
  }

  function getFacilitator(address facilitator) external view returns (Facilitator memory) {
    return _facilitators[facilitator];
  }

  function getFacilitatorBucket(address facilitator) external view returns (uint256, uint256) {
    return (_facilitators[facilitator].bucketCapacity, _facilitators[facilitator].bucketLevel);
  }

  function getFacilitatorsList() external view returns (address[] memory) {
    return _facilitatorsList;
  }

  // Test helper to mint without facilitator check
  function testMint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  // Test helper to burn without facilitator check
  function testBurn(address from, uint256 amount) external {
    _burn(from, amount);
  }
}
