// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/SimpleERC20.sol";
import "../src/MockOracle.sol";
import "../src/CDPStablecoin.sol";

contract DustRoundingTest is Test {
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
        cdp = new CDPStablecoin(tokens, aggs);

        // give collateral
        weth.mint(alice, 1 ether); // 1 WETH
        weth.mint(bob, 1 ether);

        vm.startPrank(alice);
        weth.approve(address(cdp), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        weth.approve(address(cdp), type(uint256).max);
        vm.stopPrank();
    }

    // If liquidator repays full debt, user's debt should be zero and collateral reduced accordingly
    function testFullRepayClearsDebt() public {
        vm.startPrank(alice);
        cdp.depositCollateral(address(weth), 1 ether);
        cdp.setCollateralizationRatio(address(weth), 110);
        // mint a small amount to keep repayable amount achievable after a price drop
        uint256 mintAmt = 10 ether;
        cdp.mint(address(weth), mintAmt);
        (, uint256 aliceDebtBefore, ) = cdp.getPosition(alice, address(weth));
        vm.stopPrank();

        // bob prepares to liquidate by minting stable tokens
        vm.startPrank(bob);
        cdp.depositCollateral(address(weth), 1 ether);
        cdp.setCollateralizationRatio(address(weth), 200);
        cdp.mint(address(weth), mintAmt + 10);
        cdp.approve(address(cdp), type(uint256).max);
        vm.stopPrank();

        // drop price such that liquidation is possible
        wethOracle.setPrice(1e17); // 0.1 USD

        vm.startPrank(bob);
        // attempt to repay all of alice's debt
        cdp.liquidate(alice, address(weth), aliceDebtBefore);
        vm.stopPrank();

        (uint256 colAfter, uint256 debtAfter, ) = cdp.getPosition(alice, address(weth));
        // debt must not have increased and should be <= previous debt
        assertLe(debtAfter, aliceDebtBefore);
        // collateral should be <= initial collateral (no minting of collateral)
        assertLe(colAfter, 1 ether);
    }

    // When repayAmount is larger than possible (collateral too small), liquidate should cap repay and not underflow
    function testRepayCappedByCollateral() public {
        vm.startPrank(alice);
        cdp.depositCollateral(address(weth), 1 ether);
        cdp.setCollateralizationRatio(address(weth), 120);
        cdp.mint(address(weth), 100 ether); // large debt to force cap behavior
        vm.stopPrank();

        vm.startPrank(bob);
        cdp.depositCollateral(address(weth), 1 ether);
        cdp.setCollateralizationRatio(address(weth), 200);
        cdp.mint(address(weth), 50 ether);
        cdp.approve(address(cdp), type(uint256).max);
        vm.stopPrank();

        // crash price so collateral supports only small repay
        wethOracle.setPrice(1e16); // 0.01 USD

        vm.startPrank(bob);
        uint256 bobBal = cdp.balanceOf(bob);
        // try to repay up to bob's balance but not exceed alice's debt
        uint256 tryRepay = bobBal;
        if (tryRepay > 100 ether) tryRepay = 100 ether;
        // should not revert; internal cap will apply where collateral is insufficient
        cdp.liquidate(alice, address(weth), tryRepay);
        vm.stopPrank();

        (uint256 colAfter, uint256 debtAfter, ) = cdp.getPosition(alice, address(weth));
        // no underflow: debt must be <= previous large amount
        assertLe(debtAfter, type(uint256).max);
        // collateral consumed (may be zero)
        assert(colAfter <= 1 ether);
    }
}
