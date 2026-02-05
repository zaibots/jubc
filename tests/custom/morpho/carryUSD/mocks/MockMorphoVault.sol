// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockMorphoVault
 * @notice Configurable mock of Morpho Vault V2 for testing adapter integration
 * @dev Implements ERC-4626-like interface with adapter allocation
 */
contract MockMorphoVault is ERC20 {
    // ═══════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════

    IERC20 public immutable asset;

    // Adapter tracking
    mapping(address => bool) public isAdapter;
    mapping(address => uint256) public adapterAllocations;
    address[] public adapters;

    // Caps per risk ID
    mapping(bytes32 => uint256) public absoluteCaps;
    mapping(bytes32 => uint256) public relativeCaps;
    mapping(bytes32 => uint256) public riskExposures;

    // Configuration
    uint256 public performanceFee = 2000; // 20% in bps
    uint256 public managementFee = 200;   // 2% in bps
    address public feeRecipient;

    // Configurable behavior
    bool public shouldRevertOnDeposit;
    bool public shouldRevertOnWithdraw;
    bool public shouldRevertOnAllocate;

    // Events
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event Allocated(address indexed adapter, uint256 assets);
    event Deallocated(address indexed adapter, uint256 assets);

    // ═══════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        asset = _asset;
        feeRecipient = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════

    function addAdapter(address adapter) external {
        require(!isAdapter[adapter], "Already adapter");
        isAdapter[adapter] = true;
        adapters.push(adapter);
    }

    function removeAdapter(address adapter) external {
        require(isAdapter[adapter], "Not adapter");
        isAdapter[adapter] = false;

        // Remove from array
        for (uint256 i = 0; i < adapters.length; i++) {
            if (adapters[i] == adapter) {
                adapters[i] = adapters[adapters.length - 1];
                adapters.pop();
                break;
            }
        }
    }

    function setAbsoluteCap(bytes32 riskId, uint256 cap) external {
        absoluteCaps[riskId] = cap;
    }

    function setRelativeCap(bytes32 riskId, uint256 cap) external {
        relativeCaps[riskId] = cap;
    }

    function setFees(uint256 _performanceFee, uint256 _managementFee) external {
        performanceFee = _performanceFee;
        managementFee = _managementFee;
    }

    function setFeeRecipient(address _feeRecipient) external {
        feeRecipient = _feeRecipient;
    }

    function setShouldRevert(bool _deposit, bool _withdraw, bool _allocate) external {
        shouldRevertOnDeposit = _deposit;
        shouldRevertOnWithdraw = _withdraw;
        shouldRevertOnAllocate = _allocate;
    }

    // ═══════════════════════════════════════════════════════════════════
    // ERC-4626 IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(!shouldRevertOnDeposit, "MockMorphoVault: deposit reverted");

        shares = convertToShares(assets);
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        require(!shouldRevertOnDeposit, "MockMorphoVault: mint reverted");

        assets = convertToAssets(shares);
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares) {
        require(!shouldRevertOnWithdraw, "MockMorphoVault: withdraw reverted");

        shares = convertToShares(assets);

        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            require(allowed >= shares, "Insufficient allowance");
            _approve(owner, msg.sender, allowed - shares);
        }

        _burn(owner, shares);
        asset.transfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        require(!shouldRevertOnWithdraw, "MockMorphoVault: redeem reverted");

        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            require(allowed >= shares, "Insufficient allowance");
            _approve(owner, msg.sender, allowed - shares);
        }

        assets = convertToAssets(shares);
        _burn(owner, shares);
        asset.transfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function totalAssets() public view returns (uint256) {
        uint256 balance = asset.balanceOf(address(this));

        // Add allocations to adapters
        for (uint256 i = 0; i < adapters.length; i++) {
            balance += adapterAllocations[adapters[i]];
        }

        return balance;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : (shares * totalAssets()) / supply;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ADAPTER ALLOCATION (Morpho V2 specific)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Allocate assets to an adapter
    function allocate(
        address adapter,
        bytes calldata data,
        uint256 assets
    ) external returns (bytes32[] memory ids, int256 delta) {
        require(!shouldRevertOnAllocate, "MockMorphoVault: allocate reverted");
        require(isAdapter[adapter], "Not adapter");
        require(asset.balanceOf(address(this)) >= assets, "Insufficient balance");

        // Approve adapter to pull tokens (CarryAdapter uses transferFrom)
        asset.approve(adapter, assets);
        adapterAllocations[adapter] += assets;

        // Call adapter's allocate function (adapter will pull tokens)
        (ids, delta) = IVaultV2Adapter(adapter).allocate(data, assets, bytes4(0), msg.sender);

        // Update risk exposures
        for (uint256 i = 0; i < ids.length; i++) {
            riskExposures[ids[i]] += assets;
        }

        emit Allocated(adapter, assets);
    }

    /// @notice Deallocate assets from an adapter
    function deallocate(
        address adapter,
        bytes calldata data,
        uint256 assets
    ) external returns (bytes32[] memory ids, int256 delta) {
        require(isAdapter[adapter], "Not adapter");

        // Call adapter's deallocate function
        (ids, delta) = IVaultV2Adapter(adapter).deallocate(data, assets, bytes4(0), msg.sender);

        // Receive assets back
        uint256 balanceBefore = asset.balanceOf(address(this));
        // Adapter should transfer back

        uint256 received = asset.balanceOf(address(this)) - balanceBefore;
        if (received > 0) {
            adapterAllocations[adapter] -= received > adapterAllocations[adapter]
                ? adapterAllocations[adapter]
                : received;
        }

        // Update risk exposures
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 exposure = riskExposures[ids[i]];
            riskExposures[ids[i]] = assets > exposure ? 0 : exposure - assets;
        }

        emit Deallocated(adapter, assets);
    }

    /// @notice Force deallocate with penalty (for stuck positions)
    function forceDeallocate(
        address adapter,
        bytes calldata data,
        uint256 assets
    ) external returns (bytes32[] memory ids, int256 delta) {
        // Same as deallocate but called via this to reach external function
        return this.deallocate(adapter, data, assets);
    }

    // ═══════════════════════════════════════════════════════════════════
    // TEST HELPERS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Set adapter allocation directly (for testing)
    function setAdapterAllocation(address adapter, uint256 amount) external {
        adapterAllocations[adapter] = amount;
    }

    /// @notice Get all adapter addresses
    function getAdapters() external view returns (address[] memory) {
        return adapters;
    }

    /// @notice Get adapter count
    function getAdapterCount() external view returns (uint256) {
        return adapters.length;
    }

    /// @notice Get total allocated to adapters
    function getTotalAllocated() external view returns (uint256 total) {
        for (uint256 i = 0; i < adapters.length; i++) {
            total += adapterAllocations[adapters[i]];
        }
    }

    /// @notice Get share price (assets per share, scaled by 1e18)
    function sharePrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return (totalAssets() * 1e18) / supply;
    }
}

// Interface for adapter calls
interface IVaultV2Adapter {
    function allocate(
        bytes calldata data,
        uint256 assets,
        bytes4 selector,
        address caller
    ) external returns (bytes32[] memory ids, int256 delta);

    function deallocate(
        bytes calldata data,
        uint256 assets,
        bytes4 selector,
        address caller
    ) external returns (bytes32[] memory ids, int256 delta);

    function realAssets() external view returns (uint256);
    function ids() external view returns (bytes32[] memory);
}
