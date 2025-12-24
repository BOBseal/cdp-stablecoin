// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/SimpleERC20.sol";
import "../src/MockOracle.sol";
import "../src/CDPStablecoin.sol";

contract FuzzLiquidation is Test {
    SimpleERC20 weth;
    MockOracle wethOracle;
    CDPStablecoin cdp;
    address alice = address(0xA11ce);
    address bob = address(0xB0b);

    function setUp() public {
        weth = new SimpleERC20("WETH", "WETH");
        wethOracle = new MockOracle(18, int256(2000 ether));
        address[] memory tokens = new address[](1);
        address[] memory aggs = new address[](1);
        tokens[0] = address(weth);
        aggs[0] = address(wethOracle);
        Treasury treasury = new Treasury(address(this));
        cdp = new CDPStablecoin(tokens, aggs, address(treasury));

        // mint collateral for users
        weth.mint(alice, 100 ether);
        weth.mint(bob, 100 ether);

        vm.startPrank(alice);
        weth.approve(address(cdp), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        weth.approve(address(cdp), type(uint256).max);
        vm.stopPrank();
    }

    // fuzz repay amount and post-drop price, ensure liquidation never reverts and invariants hold
    function testFuzzLiquidation(uint96 repayInput, uint96 priceAfterMantissa) public {
        vm.assume(repayInput > 0 && repayInput <= uint96(100 ether));
        vm.assume(priceAfterMantissa > 0 && priceAfterMantissa <= uint96(2 ether)); // up to 2 USD

        // alice deposits and mints
        vm.startPrank(alice);
        cdp.depositCollateral(address(weth), 50 ether);
        cdp.setCollateralizationRatio(address(weth), 120);
        cdp.mint(address(weth), 50 ether);
        vm.stopPrank();

        // bob prepares to liquidate
        vm.startPrank(bob);
        cdp.depositCollateral(address(weth), 50 ether);
        cdp.setCollateralizationRatio(address(weth), 200);
        cdp.mint(address(weth), 30 ether);
        // approve CDP to pull bob's stable tokens
        cdp.approve(address(cdp), type(uint256).max);
        vm.stopPrank();

        // drop price to fuzzed small value (simulate severe crash)
        wethOracle.setPrice(int256(uint256(priceAfterMantissa) * 1e18));

        vm.startPrank(bob);
        uint256 toRepay = uint256(repayInput);
        // cap repay to bob's balance
        uint256 bobBal = cdp.balanceOf(bob);
        if (toRepay > bobBal) toRepay = bobBal;
        // call liquidate; should not revert
        try cdp.liquidate(alice, address(weth), toRepay) {
            // ok
        } catch {
            // if liquidation not eligible, ensure health ratio is >= threshold
            uint256 hr = cdp.healthRatio(alice, address(weth));
            assertGe(hr, 100);
        }
        vm.stopPrank();

        // ensure no negative balances or overflowed state
        (uint256 col, uint256 debt, ) = cdp.getPosition(alice, address(weth));
        assert(col <= 50 ether);
        // debt should not underflow
        assert(debt <= 50 ether);
    }
}
