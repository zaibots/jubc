// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from 'openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';
import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {ReentrancyGuard} from 'openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol';

import {IAdapter} from 'vault-v2/interfaces/IAdapter.sol';

interface ICarryStrategy {
  function receiveAssets(uint256 amount) external;
  function withdrawAssets(uint256 amount) external returns (uint256);
  function getRealAssets() external view returns (uint256);
  function getCurrentLeverageRatio() external view returns (uint256);
  function isEngaged() external view returns (bool);
}

interface ILinearBlockTwapOracle {
  function getCurrentTwapPrice() external view returns (uint256);
}

/**
 * @title CarryAdapter
 * @notice Morpho Vault V2 adapter for carry strategies
 * @dev Implements IAdapter from vault-v2. VaultV2 pushes tokens before allocate()
 *      and pulls tokens after deallocate() via safeTransferFrom.
 */
contract CarryAdapter is IAdapter, Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  address public immutable vault;
  address public immutable asset;
  ICarryStrategy public strategy;
  ILinearBlockTwapOracle public twapOracle;
  bytes32 public immutable strategyRiskId;

  bytes32 public constant RISK_ID_AAVE = keccak256('aave-protocol');
  bytes32 public constant RISK_ID_JPY_FX = keccak256('jpy-fx-exposure');

  error OnlyVault();
  error ZeroAddress();
  error StrategyNotSet();
  error InsufficientAssets();

  modifier onlyVault() {
    if (msg.sender != vault) revert OnlyVault();
    _;
  }

  constructor(address _vault, address _asset, string memory _strategyId, address _twapOracle) Ownable(msg.sender) {
    if (_vault == address(0) || _asset == address(0) || _twapOracle == address(0)) revert ZeroAddress();
    vault = _vault;
    asset = _asset;
    strategyRiskId = keccak256(abi.encodePacked('strategy:', _strategyId));
    twapOracle = ILinearBlockTwapOracle(_twapOracle);
  }

  /// @dev VaultV2 pushes tokens to this adapter before calling allocate().
  function allocate(bytes memory, uint256 assets, bytes4, address) external override onlyVault nonReentrant returns (bytes32[] memory _ids, int256 change) {
    if (address(strategy) == address(0)) revert StrategyNotSet();
    // Tokens already at adapter — VaultV2 pushed before calling
    IERC20(asset).forceApprove(address(strategy), assets);
    strategy.receiveAssets(assets);
    _ids = ids();
    change = int256(assets);
  }

  /// @dev VaultV2 calls deallocate() then pulls tokens via safeTransferFrom.
  function deallocate(bytes memory, uint256 assets, bytes4, address) external override onlyVault nonReentrant returns (bytes32[] memory _ids, int256 change) {
    if (address(strategy) == address(0)) revert StrategyNotSet();
    if (assets > realAssets()) revert InsufficientAssets();
    uint256 withdrawn = strategy.withdrawAssets(assets);
    // Approve vault to pull tokens after this call returns
    IERC20(asset).forceApprove(vault, withdrawn);
    _ids = ids();
    change = -int256(withdrawn);
  }

  function realAssets() public view override returns (uint256) {
    if (address(strategy) == address(0)) return IERC20(asset).balanceOf(address(this));
    return strategy.getRealAssets();
  }

  function ids() public view returns (bytes32[] memory) {
    bytes32[] memory _ids = new bytes32[](3);
    _ids[0] = RISK_ID_AAVE;
    _ids[1] = RISK_ID_JPY_FX;
    _ids[2] = strategyRiskId;
    return _ids;
  }

  function setStrategy(address _strategy) external onlyOwner {
    if (_strategy == address(0)) revert ZeroAddress();
    strategy = ICarryStrategy(_strategy);
  }

  function setTwapOracle(address _oracle) external onlyOwner {
    if (_oracle == address(0)) revert ZeroAddress();
    twapOracle = ILinearBlockTwapOracle(_oracle);
  }

  function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
    IERC20(token).safeTransfer(owner(), amount);
  }
}
