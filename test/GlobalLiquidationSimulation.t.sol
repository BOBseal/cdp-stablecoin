// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/SimpleERC20.sol";
import "../src/MockOracle.sol";
import "../src/CDPStablecoin.sol";

contract GlobalLiquidationSimulation is Test {
    SimpleERC20 weth;
    MockOracle wethOracle;
    CDPStablecoin cdp;

    address user1 = address(0x1111);
    address user2 = address(0x2222);
    address user3 = address(0x3333);
    address liquidator = address(0xB1d);

    function setUp() public {
        weth = new SimpleERC20("WETH", "WETH");
        wethOracle = new MockOracle(18, int256(2000 ether));

        address[] memory tokens = new address[](1);
        address[] memory aggs = new address[](1);
        tokens[0] = address(weth);
        aggs[0] = address(wethOracle);

        cdp = new CDPStablecoin(tokens, aggs);

        // mint collateral for users and liquidator
        weth.mint(user1, 100 ether);
        weth.mint(user2, 100 ether);
        weth.mint(user3, 100 ether);
        weth.mint(liquidator, 200 ether);

        // approve CDP
        vm.startPrank(user1);
        weth.approve(address(cdp), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        weth.approve(address(cdp), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user3);
        weth.approve(address(cdp), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(liquidator);
        weth.approve(address(cdp), type(uint256).max);
        vm.stopPrank();

        // each user deposits and mints conservative amounts
        vm.startPrank(user1);
        cdp.depositCollateral(address(weth), 100 ether);
        cdp.setCollateralizationRatio(address(weth), 150);
        cdp.mint(address(weth), 80 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        cdp.depositCollateral(address(weth), 100 ether);
        cdp.setCollateralizationRatio(address(weth), 150);
        cdp.mint(address(weth), 80 ether);
        vm.stopPrank();

        vm.startPrank(user3);
        cdp.depositCollateral(address(weth), 100 ether);
        cdp.setCollateralizationRatio(address(weth), 150);
        cdp.mint(address(weth), 80 ether);
        vm.stopPrank();

        // liquidator prepares by depositing and minting some stablecoins
        vm.startPrank(liquidator);
        cdp.depositCollateral(address(weth), 200 ether);
        cdp.setCollateralizationRatio(address(weth), 200);
        // mint enough stablecoins so liquidator can repay multiple users
        cdp.mint(address(weth), 300 ether);
        // approve CDP to pull liquidator's stablecoins when liquidating
        cdp.approve(address(cdp), type(uint256).max);
        vm.stopPrank();
    }

    // helper to compute USD collateral value for a given token amount using oracle (18 decimals)
    function _collateralValueUsd(address token, uint256 amount) internal view returns (uint256) {
        address agg = cdp.priceFeed(token);
        (, int256 answer,, ,) = AggregatorV3Interface(agg).latestRoundData();
        uint8 aggDecimals = AggregatorV3Interface(agg).decimals();
        uint256 price18 = uint256(answer) * (10 ** (18 - aggDecimals));
        uint8 tokenDecimals = ERC20(token).decimals();
        return (amount * price18) / (10 ** tokenDecimals);
    }

    function _totalCollateralValueUsd() internal view returns (uint256) {
        uint256 sum = 0;
        // sum users' positions only (user1..user3)
        (uint256 col1,,) = cdp.getPosition(user1, address(weth));
        (uint256 col2,,) = cdp.getPosition(user2, address(weth));
        (uint256 col3,,) = cdp.getPosition(user3, address(weth));
        sum += _collateralValueUsd(address(weth), col1);
        sum += _collateralValueUsd(address(weth), col2);
        sum += _collateralValueUsd(address(weth), col3);
        // include collateral held by treasury (seized collateral tracked in the CDP)
        uint256 treasuryBal = cdp.treasuryBalance(address(weth));
        sum += _collateralValueUsd(address(weth), treasuryBal);
        // include collateral held by the liquidator (seized collateral may be transferred to them)
        uint256 liquidatorBal = weth.balanceOf(liquidator);
        sum += _collateralValueUsd(address(weth), liquidatorBal);
        return sum;
    }

    function testLiquidationsIncreaseGlobalRatio() public {
        // crash price to trigger liquidations
        vm.prank(address(this));
        wethOracle.setPrice(5e17); // 0.5 USD

        // compute totals AFTER the crash but BEFORE liquidations (same price basis)
        uint256 C_before = _totalCollateralValueUsd();
        uint256 S_before = cdp.totalSupply();

        // perform liquidations for each user by the liquidator
        vm.startPrank(liquidator);
        // liquidate user1
        (, uint256 debt1,) = cdp.getPosition(user1, address(weth));
        if (debt1 > 0) cdp.liquidate(user1, address(weth), debt1);
        // liquidate user2
        (, uint256 debt2,) = cdp.getPosition(user2, address(weth));
        if (debt2 > 0) cdp.liquidate(user2, address(weth), debt2);
        // liquidate user3
        (, uint256 debt3,) = cdp.getPosition(user3, address(weth));
        if (debt3 > 0) cdp.liquidate(user3, address(weth), debt3);
        vm.stopPrank();

        uint256 C_after = _totalCollateralValueUsd();
        uint256 S_after = cdp.totalSupply();

        // basic sanity: supply must drop after burning repaid stablecoins
        assertTrue(S_after < S_before, "supply did not drop after liquidation");

        // treasury should have received some collateral from liquidations
        uint256 treasuryBal = cdp.treasuryBalance(address(weth));
        assertTrue(treasuryBal > 0, "treasury did not gain collateral");

        // debug prints for failing cases
        console.log("C_before:", C_before);
        console.log("S_before:", S_before);
        console.log("C_after:", C_after);
        console.log("S_after:", S_after);

        // precise comparison without division: check C_after / S_after >= C_before / S_before
        // cross-multiply to avoid rounding: C_after * S_before >= C_before * S_after
        assertTrue(C_after * S_before >= C_before * S_after, "Global collateral-to-supply ratio decreased");
    }
}
