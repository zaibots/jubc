// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {ERC20} from 'openzeppelin-contracts/contracts/token/ERC20/ERC20.sol';

/**
 * @title TestConstants
 * @notice Shared constants for Morpho/Carry tests
 */
library TestConstants {
  // Price constants (8 decimals - Chainlink standard)
  int256 constant JPY_USD_PRICE = 650_000; // ~$0.0065 (1 JPY = 0.0065 USD)

  // Common precision
  uint256 constant WAD = 1e18;
  uint256 constant RAY = 1e27;
  uint256 constant BPS = 10_000;
  uint256 constant USD_DECIMALS = 8;

  // Time constants
  uint256 constant HOUR = 3600;
  uint256 constant DAY = 86400;
  uint256 constant WEEK = 604800;
}

/**
 * @title NetworkConfig
 * @notice Network-specific addresses for fork testing
 */
library NetworkConfig {
  struct SepoliaAddresses {
    address poolAddressesProvider;
    address pool;
    address oracle;
    address usdc;
    address weth;
  }

  struct MainnetAddresses {
    address poolAddressesProvider;
    address pool;
    address oracle;
    address usdc;
    address usdt;
    address weth;
    address jpyUsdFeed;
  }

  struct BaseAddresses {
    address poolAddressesProvider;
    address pool;
    address oracle;
    address usdc;
    address weth;
  }

  function getSepolia() internal pure returns (SepoliaAddresses memory) {
    return
      SepoliaAddresses({
        poolAddressesProvider: address(0), // To be filled when deployed
        pool: address(0),
        oracle: address(0),
        usdc: 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8, // Sepolia USDC
        weth: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 // Sepolia WETH
      });
  }

  function getMainnet() internal pure returns (MainnetAddresses memory) {
    return
      MainnetAddresses({
        poolAddressesProvider: address(0), // To be filled when deployed
        pool: address(0),
        oracle: address(0),
        usdc: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
        usdt: 0xdAC17F958D2ee523a2206206994597C13D831ec7,
        weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
        jpyUsdFeed: 0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3
      });
  }

  function getBase() internal pure returns (BaseAddresses memory) {
    return
      BaseAddresses({
        poolAddressesProvider: address(0), // To be filled when deployed
        pool: address(0),
        oracle: address(0),
        usdc: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
        weth: 0x4200000000000000000000000000000000000006
      });
  }
}

/**
 * @title MockERC20
 * @notice Simple mintable/burnable ERC20 for testing
 */
contract MockERC20 is ERC20 {
  uint8 private _decimals;

  constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
    _decimals = decimals_;
  }

  function decimals() public view override returns (uint8) {
    return _decimals;
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  function burn(address from, uint256 amount) external {
    _burn(from, amount);
  }
}
