// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/SimpleERC20.sol";
import "../src/MockOracle.sol";
import "../src/CDPStablecoin.sol";

contract CDPStablecoinTest is Test {
    SimpleERC20 wbtc;
    SimpleERC20 weth;
    SimpleERC20 wsol;
    CDPStablecoin cdp;
    MockOracle wbtcOracle;
    MockOracle wethOracle;
    MockOracle wsolOracle;
    address alice = address(0xA11ce);
    address bob = address(0xB0b);

    function setUp() public {
        // create collateral tokens
        wbtc = new SimpleERC20("WBTC", "WBTC");
        weth = new SimpleERC20("WETH", "WETH");
        wsol = new SimpleERC20("WSOL", "WSOL");

        // Mock oracles: use 18-decimal scaled answers for simplicity
        wbtcOracle = new MockOracle(18, int256(30000 ether));
        wethOracle = new MockOracle(18, int256(2000 ether));
        wsolOracle = new MockOracle(18, int256(30 ether));

        address[] memory tokens = new address[](3);
        address[] memory aggs = new address[](3);
        tokens[0] = address(wbtc);
        tokens[1] = address(weth);
        tokens[2] = address(wsol);
        aggs[0] = address(wbtcOracle);
        aggs[1] = address(wethOracle);
        aggs[2] = address(wsolOracle);

        // deploy a simple treasury owned by test contract
        Treasury treasury = new Treasury(address(this));

        cdp = new CDPStablecoin(tokens, aggs, address(treasury));

        // mint collateral for users
        wbtc.mint(alice, 10 ether); // 10 WBTC
        weth.mint(alice, 100 ether); // 100 WETH
        wsol.mint(alice, 1000 ether); // 1000 WSOL

        wbtc.mint(bob, 10 ether);
        weth.mint(bob, 100 ether);
        wsol.mint(bob, 1000 ether);

        vm.startPrank(alice);
        wbtc.approve(address(cdp), type(uint256).max);
        weth.approve(address(cdp), type(uint256).max);
        wsol.approve(address(cdp), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        wbtc.approve(address(cdp), type(uint256).max);
        weth.approve(address(cdp), type(uint256).max);
        wsol.approve(address(cdp), type(uint256).max);
        vm.stopPrank();
    }

    function testSetRatioAndMint() public {
        vm.startPrank(alice);
        // deposit 100 WETH (price 2000) => value = 200k
        cdp.depositCollateral(address(weth), 100 ether);
        cdp.setCollateralizationRatio(address(weth), 150); // 150%
        uint256 maxMint = cdp.maxMintable(alice, address(weth));
        // (collateralValue * 100)/ratio = ((100 * 2000) * 100)/150 = large; check > 0
        assertGt(maxMint, 0);
        cdp.mint(address(weth), 50 ether);
        assertEq(cdp.balanceOf(alice), 50 ether);
        vm.stopPrank();
    }

    function testCannotSetTooLowRatio() public {
        vm.startPrank(bob);
        vm.expectRevert(bytes("setRatio: ratio too low"));
        cdp.setCollateralizationRatio(address(weth), 100);
        vm.stopPrank();
    }

    function testWithdrawFailsWhenUnsafe() public {
        vm.startPrank(alice);
        cdp.depositCollateral(address(weth), 100 ether);
        cdp.setCollateralizationRatio(address(weth), 120);
        cdp.mint(address(weth), 80 ether);
        // make price drop to make withdrawal unsafe
        wethOracle.setPrice(5e17);
        vm.expectRevert();
        cdp.withdrawCollateral(address(weth), 50 ether); // would make position unsafe after price drop
        vm.stopPrank();
    }

    function testLiquidationPath() public {
        vm.startPrank(alice);
        cdp.depositCollateral(address(weth), 100 ether);
        cdp.setCollateralizationRatio(address(weth), 120);
        cdp.mint(address(weth), 80 ether);
        vm.stopPrank();

            // bob prepares stable tokens to liquidate: deposit collateral and mint BEFORE price drop
            vm.startPrank(bob);
            cdp.depositCollateral(address(weth), 100 ether);
            cdp.setCollateralizationRatio(address(weth), 200);
            cdp.mint(address(weth), 100 ether);
            // sanity checks
            assertEq(cdp.balanceOf(bob), 100 ether);
            // bob approves CDP to pull his stable tokens for liquidation
            cdp.approve(address(cdp), type(uint256).max);
            assertEq(cdp.allowance(bob, address(cdp)), type(uint256).max);
            vm.stopPrank();

            // price drops: WETH from 2000 -> 0.5 (big drop)
            wethOracle.setPrice(5e17); // now 0.5 USD

            // liquidate alice's position (bob will call) - repay Alice's debt (80)
            vm.startPrank(bob);
            cdp.liquidate(alice, address(weth), 80 ether);
            vm.stopPrank();

        // alice's position should have had collateral swept; debt partially repaid
        (uint256 col, uint256 debt, uint256 ratio) = cdp.getPosition(alice, address(weth));
        assertEq(col, 0);
        // because collateral value collapsed, liquidator could only repay ~50 and 30 remains
        assertEq(debt, 30 ether);
    }
}
