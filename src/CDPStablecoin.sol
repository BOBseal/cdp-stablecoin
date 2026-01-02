// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "../lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "./ChainlinkInterfaces.sol";

// Treasury is merged into the CDP contract: balances of seized fees are tracked
// in `treasuryBalance[token]` and can be withdrawn by the CDP owner.

contract CDPStablecoin is OZERC20, Ownable, ReentrancyGuard {
    // Chainlink aggregator interface

    uint256 public constant MIN_COLLATERAL_RATIO = 110; // percent
    uint256 public constant LIQUIDATION_THRESHOLD = 100; // percent
    uint256 public constant LIQUIDATION_BONUS = 1; // percent


    struct Position {
        uint256 collateralAmount; // amount of collateral token (assume 18 decimals for test tokens)
        uint256 debt; // stablecoin amount (18 decimals)
        uint256 collateralRatio; // percent (e.g., 150 = 150%) chosen by user
    }

    // supported collateral tokens and their Chainlink feeds
    mapping(address => address) public priceFeed; // token => aggregator
    mapping(address => bool) public supportedCollateral;
    address[] public supportedTokens;

    // positions[user][token]
    mapping(address => mapping(address => Position)) public positions;

    // treasury balances per token (held inside this contract)
    mapping(address => uint256) public treasuryBalance;
    bool public paused;
    mapping(address => bool) public blacklisted;

    // liquidation fee percent sent to treasury (e.g., 1 = 1%)
    uint256 public constant LIQUIDATION_FEE = 1;

    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event Mint(address indexed user, uint256 amount);
    event Burn(address indexed user, uint256 amount);
    event CollateralRatioSet(address indexed user, address indexed token, uint256 ratio);
    // Reduce indexed fields to two to lower event emission cost: index by `user` and `token`.
    // `treasuryAmount` is the portion of seized collateral sent to the treasury.
    event Liquidated(address indexed user, address indexed token, uint256 repaid, uint256 collateralTaken, uint256 treasuryAmount);

    constructor(address[] memory tokens, address[] memory aggregators) OZERC20("CDP Stable", "cUSD", 18) Ownable() {
        require(tokens.length == aggregators.length, "tokens/aggregators length");
        for (uint256 i = 0; i < tokens.length; i++) {
            supportedCollateral[tokens[i]] = true;
            priceFeed[tokens[i]] = aggregators[i];
            supportedTokens.push(tokens[i]);
        }
    }

    modifier onlySupported(address token) {
        require(supportedCollateral[token], "unsupported collateral");
        _;
    }

    // `onlyOwner` provided by Ownable

    modifier notPaused() {
        require(!paused, "paused");
        _;
    }

    modifier notBlacklisted() {
        require(!blacklisted[msg.sender], "blacklisted");
        _;
    }

    // deposit collateral (must be approved beforehand)
    /**
     * @notice Deposit `amount` of `token` as collateral for the caller.
     * @dev Caller must `approve` the CDP contract for `amount` prior to calling.
     * @param token The collateral token address (must be supported).
     * @param amount The token amount to deposit (in token's smallest units).
     */
    function depositCollateral(address token, uint256 amount) external nonReentrant onlySupported(token) notPaused notBlacklisted {
        require(amount > 0, "deposit: amount>0");
        OZERC20(token).transferFrom(msg.sender, address(this), amount);
        positions[msg.sender][token].collateralAmount += amount;
        emit Deposit(msg.sender, token, amount);
    }

    // withdraw collateral if position remains safe relative to user's chosen ratio
    /**
     * @notice Withdraw `amount` of `token` collateral for the caller.
     * @dev Reverts if the withdrawal would make the remaining position undercollateralized
     *      according to the caller's chosen collateralization ratio.
     * @param token The collateral token address.
     * @param amount The amount to withdraw.
     */
    function withdrawCollateral(address token, uint256 amount) external nonReentrant onlySupported(token) notPaused notBlacklisted {
        Position storage p = positions[msg.sender][token];
        require(amount > 0, "withdraw: amount>0");
        require(p.collateralAmount >= amount, "withdraw: insufficient collateral");
        uint256 newCollateral = p.collateralAmount - amount;
        if (p.debt > 0) {
            uint256 collateralValue = _collateralValue(token, newCollateral);
            require(collateralValue * 100 >= p.debt * p.collateralRatio, "withdraw: under-collateralized");
        }
        p.collateralAmount = newCollateral;
        OZERC20(token).transfer(msg.sender, amount);
        emit Withdraw(msg.sender, token, amount);
    }

    // user sets their desired collateralization ratio (must be >= MIN_COLLATERAL_RATIO)
    /**
     * @notice Set the caller's desired collateralization ratio (percent) for `token`.
     * @dev `ratioPercent` must be >= `MIN_COLLATERAL_RATIO`. If the user already has debt,
     *      the function will revert when the new ratio would make the position unsafe.
     * @param token The collateral token.
     * @param ratioPercent The percent (e.g., 150 = 150%).
     */
    function setCollateralizationRatio(address token, uint256 ratioPercent) external nonReentrant onlySupported(token) notPaused notBlacklisted {
        require(ratioPercent >= MIN_COLLATERAL_RATIO, "setRatio: ratio too low");
        Position storage p = positions[msg.sender][token];
        if (p.debt > 0) {
            uint256 collateralValue = _collateralValue(token, p.collateralAmount);
            require(collateralValue * 100 >= p.debt * ratioPercent, "setRatio: current position unsafe");
        }
        p.collateralRatio = ratioPercent;
        emit CollateralRatioSet(msg.sender, token, ratioPercent);
    }

    // view maximum stablecoin mintable for the user under their chosen ratio for a token
    /**
     * @notice Returns the maximum amount of stablecoin the `user` may mint against `token` collateral
     *         given their currently selected collateralization ratio for that token.
     * @dev Returns 0 when no collateral or ratio set.
     * @param user The user address.
     * @param token The collateral token address.
     */
    function maxMintable(address user, address token) public view onlySupported(token) returns (uint256) {
        Position storage p = positions[user][token];
        if (p.collateralAmount == 0 || p.collateralRatio == 0) return 0;
        uint256 collateralValue = _collateralValue(token, p.collateralAmount);
        return (collateralValue * 100) / p.collateralRatio;
    }

    // internal helper: get collateral token value in USD (18 decimals)
    function _collateralValue(address token, uint256 amount) internal view returns (uint256) {
        address agg = priceFeed[token];
        require(agg != address(0), "no price feed");
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(agg).latestRoundData();
        require(answer > 0, "invalid price");
        uint8 aggDecimals = AggregatorV3Interface(agg).decimals();
        // normalize price to 18 decimals
        uint256 price18 = uint256(answer) * (10 ** (18 - aggDecimals));
        // account for token decimals
        uint8 tokenDecimals = OZERC20(token).decimals();
        // collateral value in USD with 18 decimals = amount * price18 / (10 ** tokenDecimals)
        return (amount * price18) / (10 ** tokenDecimals);
    }

    // mint stablecoins up to user's limit for a particular collateral token
    /**
     * @notice Mint `amount` of stablecoin against `token` collateral for the caller.
     * @dev The caller must have set a collateralization ratio >= `MIN_COLLATERAL_RATIO`.
     *      The minted stablecoin is minted to the caller.
     * @param token The collateral token used to back the minted stablecoin.
     * @param amount The stablecoin amount to mint (18 decimals).
     */
    function mint(address token, uint256 amount) external nonReentrant onlySupported(token) notPaused notBlacklisted {
        require(amount > 0, "mint: amount>0");
        Position storage p = positions[msg.sender][token];
        require(p.collateralRatio >= MIN_COLLATERAL_RATIO, "mint: set ratio first");
        uint256 allowed = maxMintable(msg.sender, token);
        require(p.debt + amount <= allowed, "mint: exceeds allowed mint");
        p.debt += amount;
        _mint(msg.sender, amount);
        emit Mint(msg.sender, amount);
    }

    // repay stablecoin debt by burning stable tokens from caller. Debt is reduced proportionally across tokens.
    /**
     * @notice Repay `amount` of the caller's stablecoin debt. Caller must `approve` the CDP contract
     *         to transfer their stablecoins. The contract pulls and burns the stablecoin and reduces
     *         outstanding per-collateral debts proportionally.
     * @param amount The stablecoin amount to repay (18 decimals).
     */
    function repay(uint256 amount) public nonReentrant notPaused notBlacklisted {
        require(amount > 0, "repay: amount>0");
        uint256 totalDebt = _totalDebt(msg.sender);
        require(totalDebt >= amount, "repay: amount>debt");
        // pull stable tokens and burn
        this.transferFrom(msg.sender, address(this), amount);
        _burn(address(this), amount);

        // reduce per-token debts proportionally to their share of total debt
        address[] memory tokens = supportedTokens;
        uint256 remaining = amount;
        for (uint256 i = 0; i < tokens.length && remaining > 0; i++) {
            Position storage p = positions[msg.sender][tokens[i]];
            if (p.debt == 0) continue;
            uint256 reduce = (amount * p.debt) / totalDebt;
            if (reduce > p.debt) reduce = p.debt;
            // ensure we don't leave remainder due to rounding
            if (i == tokens.length - 1 && remaining > reduce) {
                reduce = remaining;
            }
            p.debt -= reduce;
            remaining -= reduce;
        }
        emit Burn(msg.sender, amount);
    }

    // legacy wrapper for compatibility
    function burn(uint256 amount) external {
        repay(amount);
    }

    // Partial liquidation: liquidator repays `repayAmount` (<= user's debt) and receives collateral + bonus.
    // A small fee portion of collateral is swept to the treasury.
    /**
     * @notice Partially liquidate `user`'s position for `token` by repaying up to `repayAmount` of their debt.
     * @dev Liquidation can only occur when the health ratio is below `LIQUIDATION_THRESHOLD`.
     *      The liquidator must have approved the CDP contract to transfer the stablecoin to be burned.
     * @param user The user being liquidated.
     * @param token The collateral token to seize.
     * @param repayAmount The stablecoin amount the liquidator wishes to repay on behalf of the user.
     */
    function liquidate(address user, address token, uint256 repayAmount) external nonReentrant onlySupported(token) {
        require(repayAmount > 0, "liquidate: repay>0");
        Position storage p = positions[user][token];
        require(p.debt > 0, "liquidate: no debt");
        require(repayAmount <= p.debt, "liquidate: repay>debt");
        uint256 collateralValue = _collateralValue(token, p.collateralAmount);
        uint256 currentRatio = (collateralValue * 100) / p.debt;
        require(currentRatio < LIQUIDATION_THRESHOLD, "liquidate: not eligible");

        // compute adjusted values via helper to reduce local variables and avoid stack-too-deep
        (uint256 adjustedRepay, uint256 collateralToLiquidator, uint256 fee) = _computeLiquidationInfo(token, repayAmount, p.collateralAmount);

        require(allowance(msg.sender, address(this)) >= adjustedRepay, "liquidate: allowance insufficient");
        // pull stable tokens and burn only the adjusted repay
        this.transferFrom(msg.sender, address(this), adjustedRepay);
        _burn(address(this), adjustedRepay);

        uint256 toLiquidatorNet = collateralToLiquidator > fee ? collateralToLiquidator - fee : 0;

        // update user
        if (collateralToLiquidator > p.collateralAmount) collateralToLiquidator = p.collateralAmount;
        p.collateralAmount -= collateralToLiquidator;
        p.debt = adjustedRepay >= p.debt ? 0 : p.debt - adjustedRepay;

        if (toLiquidatorNet > 0) OZERC20(token).transfer(msg.sender, toLiquidatorNet);
        if (fee > 0) {
            // keep fee inside this contract and mark it as treasury-held
            treasuryBalance[token] += fee;
        }

        // emit concise event (indexed: user, token) to reduce emission cost
        emit Liquidated(user, token, adjustedRepay, collateralToLiquidator, fee);
    }

    // compute adjusted repayable amount, collateral to liquidator and fee
    function _computeLiquidationInfo(address token, uint256 repayAmount, uint256 collateralAmount) internal view returns (uint256 adjustedRepay, uint256 collateralToLiquidator, uint256 fee) {
        address agg = priceFeed[token];
        (, int256 answer,, ,) = AggregatorV3Interface(agg).latestRoundData();
        uint256 price18 = uint256(answer) * (10 ** (18 - AggregatorV3Interface(agg).decimals()));
        uint256 tokenScale = (10 ** uint256(OZERC20(token).decimals()));
        uint256 collateralNeeded = (repayAmount * tokenScale) / price18;
        uint256 collToLiquidator = collateralNeeded + ((collateralNeeded * LIQUIDATION_BONUS) / 100);

        if (collToLiquidator > collateralAmount) {
            collToLiquidator = collateralAmount;
            uint256 repayPossible = (collateralAmount * price18) / tokenScale;
            if (repayPossible < repayAmount) {
                repayAmount = repayPossible;
            }
        }

        uint256 feeLocal = (collToLiquidator * LIQUIDATION_FEE) / 100;
        return (repayAmount, collToLiquidator, feeLocal);
    }

    // helper: total debt of user across supported tokens
    function _totalDebt(address user) internal view returns (uint256) {
        address[] memory tokens = supportedTokens;
        uint256 sum = 0;
        for (uint256 i = 0; i < tokens.length; i++) sum += positions[user][tokens[i]].debt;
        return sum;
    }

    // owner may withdraw treasury-held collateral tokens from the CDP contract
    function withdrawTreasury(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "treasury: invalid to");
        require(amount > 0, "treasury: amount>0");
        require(treasuryBalance[token] >= amount, "treasury: insufficient balance");
        treasuryBalance[token] -= amount;
        OZERC20(token).transfer(to, amount);
    }

    // emergency admin function: withdraw tokens that are free (not reserved as treasury)
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "emergency: invalid to");
        require(amount > 0, "emergency: amount>0");
        uint256 held = OZERC20(token).balanceOf(address(this));
        uint256 reserved = treasuryBalance[token];
        require(held >= reserved, "emergency: reserved>held");
        uint256 available = held - reserved;
        require(amount <= available, "emergency: amount>available");
        OZERC20(token).transfer(to, amount);
    }

    /**
     * @notice Estimate the liquidation oracle price (normalized to 18 decimals) at which
     *         the `user`'s position for `token` would hit the `LIQUIDATION_THRESHOLD`.
     * @dev Returns 0 when position has no collateral or no debt.
     * @param user The user address.
     * @param token The collateral token address.
     */
    function estimatedLiquidationPrice(address user, address token) external view returns (uint256 price18) {
        Position storage p = positions[user][token];
        if (p.debt == 0 || p.collateralAmount == 0) return 0;
        // collateralValue required at liquidation: debt * LIQUIDATION_THRESHOLD / 100
        // price18 = collateralValue * 10^tokenDecimals / collateralAmount
        uint8 tokenDecimals = OZERC20(token).decimals();
        uint256 collateralValueRequired = (p.debt * LIQUIDATION_THRESHOLD) / 100;
        // price18 = collateralValueRequired * (10 ** tokenDecimals) / collateralAmount
        price18 = (collateralValueRequired * (10 ** uint256(tokenDecimals))) / p.collateralAmount;
        return price18;
    }

    // helper: small list of supported tokens (not gas efficient, used for tests/example only)
    function _listSupported() internal view returns (address[] memory) {
        return supportedTokens;
    }

    // admin functions
    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    function setBlacklist(address who, bool v) external onlyOwner {
        blacklisted[who] = v;
    }

    function addSupportedToken(address token, address agg) external onlyOwner {
        require(!supportedCollateral[token], "already supported");
        supportedCollateral[token] = true;
        priceFeed[token] = agg;
        supportedTokens.push(token);
    }

    function removeSupportedToken(address token) external onlyOwner {
        require(supportedCollateral[token], "not supported");
        supportedCollateral[token] = false;
        priceFeed[token] = address(0);
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i] == token) {
                supportedTokens[i] = supportedTokens[supportedTokens.length - 1];
                supportedTokens.pop();
                break;
            }
        }
    }

    // view: health ratio for a user's token position (percent)
    /**
     * @notice Returns the health ratio (percent) for `user`'s position in `token`.
     * @dev A value < `LIQUIDATION_THRESHOLD` means the position is eligible for liquidation.
     * @param user The user address.
     * @param token The collateral token.
     */
    function healthRatio(address user, address token) external view returns (uint256) {
        Position storage p = positions[user][token];
        if (p.debt == 0) return type(uint256).max;
        uint256 collateralValue = _collateralValue(token, p.collateralAmount);
        return (collateralValue * 100) / p.debt;
    }

    // helper view to read a user's position for a token
    /**
     * @notice Returns `user`'s `token` position: collateral amount, debt, and collateral ratio percent.
     * @param user The user address.
     * @param token The collateral token.
     */
    function getPosition(address user, address token) external view returns (uint256 collateralAmount, uint256 debt, uint256 collateralRatioPercent) {
        Position storage p = positions[user][token];
        return (p.collateralAmount, p.debt, p.collateralRatio);
    }
}
