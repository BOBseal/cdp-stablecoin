// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/SimpleERC20Decimals.sol";
import "../src/MockOracle.sol";
import "../src/CDPStablecoin.sol";

contract CollateralDecimalsTest is Test {
    SimpleERC20Decimals token8;
    MockOracle oracle;
    CDPStablecoin cdp;
    address alice = address(0xA11ce);

    function setUp() public {
        token8 = new SimpleERC20Decimals("WBTC8", "WBTC8", 8);
        oracle = new MockOracle(18, int256(30000 ether));
        address[] memory tokens = new address[](1);
        address[] memory aggs = new address[](1);
        tokens[0] = address(token8);
        aggs[0] = address(oracle);
        Treasury treasury = new Treasury(address(this));
        cdp = new CDPStablecoin(tokens, aggs, address(treasury));

        // mint 1 WBTC (8 decimals => 1 * 10^8)
        token8.mint(alice, 1 * 10**8);

        vm.startPrank(alice);
        token8.approve(address(cdp), type(uint256).max);
        vm.stopPrank();
    }

    function test8DecimalsCollateralValue() public {
        vm.startPrank(alice);
        // deposit 1 WBTC (1e8 units)
        cdp.depositCollateral(address(token8), 1 * 10**8);
        cdp.setCollateralizationRatio(address(token8), 150);
        uint256 maxMint = cdp.maxMintable(alice, address(token8));
        // with price 30000 USD, 1 WBTC => 30000e18 value; maxMint should be > 0
        assertGt(maxMint, 0);
        // Mint a small amount and ensure no revert
        cdp.mint(address(token8), 100 ether);
        assertEq(cdp.balanceOf(alice), 100 ether);
        vm.stopPrank();
    }
}
