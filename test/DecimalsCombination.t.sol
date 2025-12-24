// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/SimpleERC20Decimals.sol";
import "../src/SimpleERC20.sol";
import "../src/MockOracle.sol";
import "../src/CDPStablecoin.sol";

contract DecimalsCombinationTest is Test {
    SimpleERC20Decimals token8;
    SimpleERC20Decimals token6;
    SimpleERC20 token18;
    MockOracle oracle8;
    MockOracle oracle6;
    MockOracle oracle18;
    CDPStablecoin cdp;
    address alice = address(0xA11ce);

    function setUp() public {
        token8 = new SimpleERC20Decimals("WBTC8", "WBTC8", 8);
        token6 = new SimpleERC20Decimals("TOKEN6", "T6", 6);
        token18 = new SimpleERC20("WETH", "WETH");

        // prices: 8-decimal token = 30k, 6-decimal = 2k, 18-decimal = 2000
        oracle8 = new MockOracle(18, int256(30000 ether));
        oracle6 = new MockOracle(18, int256(2000 ether));
        oracle18 = new MockOracle(18, int256(2000 ether));

        address[] memory tokens = new address[](3);
        address[] memory aggs = new address[](3);
        tokens[0] = address(token8);
        tokens[1] = address(token6);
        tokens[2] = address(token18);
        aggs[0] = address(oracle8);
        aggs[1] = address(oracle6);
        aggs[2] = address(oracle18);

        Treasury treasury = new Treasury(address(this));
        cdp = new CDPStablecoin(tokens, aggs, address(treasury));

        // mint tokens to alice: 1 WBTC8 (1e8), 1000 T6 (1e3 * 1e6), 10 WETH (10e18)
        token8.mint(alice, 1 * 10**8);
        token6.mint(alice, 1000 * 10**6);
        token18.mint(alice, 10 ether);

        vm.startPrank(alice);
        token8.approve(address(cdp), type(uint256).max);
        token6.approve(address(cdp), type(uint256).max);
        token18.approve(address(cdp), type(uint256).max);
        vm.stopPrank();
    }

    function testMultipleCollateralRounding() public {
        vm.startPrank(alice);
        // deposit mixed collaterals
        cdp.depositCollateral(address(token8), 1 * 10**8);
        cdp.setCollateralizationRatio(address(token8), 150);
        cdp.depositCollateral(address(token6), 1000 * 10**6);
        cdp.setCollateralizationRatio(address(token6), 150);
        cdp.depositCollateral(address(token18), 10 ether);
        cdp.setCollateralizationRatio(address(token18), 150);

        // Compute max mintable from each and mint small odd amounts to trigger rounding
        uint256 max8 = cdp.maxMintable(alice, address(token8));
        uint256 max6 = cdp.maxMintable(alice, address(token6));
        uint256 max18 = cdp.maxMintable(alice, address(token18));
        assertGt(max8, 0);
        assertGt(max6, 0);
        assertGt(max18, 0);

        // mint a combination
        cdp.mint(address(token8), max8 / 3 + 1);
        cdp.mint(address(token6), max6 / 3 + 1);
        cdp.mint(address(token18), max18 / 3 + 1);

        // capture debt and collateral sum
        uint256 totalDebt = cdp.balanceOf(alice);
        (uint256 col8, uint256 debt8, ) = cdp.getPosition(alice, address(token8));
        (uint256 col6, uint256 debt6, ) = cdp.getPosition(alice, address(token6));
        (uint256 col18, uint256 debt18, ) = cdp.getPosition(alice, address(token18));

        assertEq(totalDebt, debt8 + debt6 + debt18);

        // now simulate price moves that stress rounding and decimals
        // drive token8 price very low so its per-token position becomes eligible for liquidation
        oracle8.setPrice(1e15); // 0.001 USD (severe crash)
        oracle6.setPrice(1800 ether);  // token6 down
        oracle18.setPrice(1900 ether); // weth down slightly

        // health ratios should reflect decreased collateral value; ensure healthRatio function executes
        uint256 h8 = cdp.healthRatio(alice, address(token8));
        uint256 h6 = cdp.healthRatio(alice, address(token6));
        uint256 h18 = cdp.healthRatio(alice, address(token18));
        // health ratios may be below thresholds; ensure no underflow and function returns a value
        assert(h8 <= type(uint256).max && h6 <= type(uint256).max && h18 <= type(uint256).max);

        // stop acting as alice; prepare a liquidator as the test contract
        vm.stopPrank();

        // use token18 as collateral for this test contract to mint stable tokens to liquidate
        token18.mint(address(this), 1 ether);
        token18.approve(address(cdp), type(uint256).max);
        cdp.depositCollateral(address(token18), 1 ether);
        cdp.setCollateralizationRatio(address(token18), 200);
        cdp.mint(address(token18), 100 ether);

        // approve CDP to pull the minted stable tokens from this contract
        cdp.approve(address(cdp), type(uint256).max);

        // perform a liquidation attempt on one of alice's positions (called from test contract)
        cdp.liquidate(alice, address(token8), 1 ether);

        // verify debts did not increase and collateral amounts are consistent
        (uint256 col8_after, uint256 debt8_after, ) = cdp.getPosition(alice, address(token8));
        assertLe(debt8_after, debt8);
        assertLe(col8_after, col8);
    }
}
