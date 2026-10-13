// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IGraduationLocker} from "./interfaces/IGraduationLocker.sol";
import {ArbBlock} from "./libraries/ArbBlock.sol";
import {BondingCurveMath} from "./libraries/BondingCurveMath.sol";
import {LaunchLimits} from "./libraries/LaunchLimits.sol";

/// @title BondingCurve
/// @notice Holds one coin's entire supply and trades it against ETH on a constant-product curve
/// with virtual reserves. Deployed as a minimal-proxy clone per coin, so every coin's ETH is
/// isolated. Has no owner: once initialised, nobody can change its parameters or move its funds.
/// When the curve sells out it stops trading; anyone may then call `graduate` to move its
/// liquidity into a Uniswap v4 pool that is locked forever.
/// @dev Reserves are tracked in storage and never derived from token or ETH balances, so tokens
/// or ETH sent directly to this contract cannot influence pricing.
contract BondingCurve is Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    enum State {
        Trading,
        Complete,
        Graduated
    }

    struct Config {
        address token;
        address creator;
        address feeVault;
        uint256 targetRaise;
        uint16 platformFeeBps;
        uint16 creatorFeeBps;
        uint16 antiSnipeFeeBps;
        uint32 antiSnipeDuration;
        address locker;
        uint256 graduationFee;
        uint256 graduationReward;
    }

    struct BuyQuote {
        uint256 tokensOut;
        uint256 ethSpent;
        uint256 ethToCurve;
        uint256 platformFee;
        uint256 creatorFee;
    }

    struct SellQuote {
        uint256 ethOut;
        uint256 grossEth;
        uint256 platformFee;
        uint256 creatorFee;
    }

    uint256 public constant BPS = LaunchLimits.BPS;
    uint256 public constant MAX_TRADE_FEE_BPS = LaunchLimits.MAX_TRADE_FEE_BPS;
    uint256 public constant MAX_ANTI_SNIPE_FEE_BPS = LaunchLimits.MAX_ANTI_SNIPE_FEE_BPS;
    uint256 public constant MAX_ANTI_SNIPE_DURATION = LaunchLimits.MAX_ANTI_SNIPE_DURATION;
    uint256 public constant MIN_TARGET_RAISE = LaunchLimits.MIN_TARGET_RAISE;
    uint256 public constant MAX_TARGET_RAISE = LaunchLimits.MAX_TARGET_RAISE;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable factory;

    IERC20 public token;
    address public creator;
    address public feeVault;
    uint16 public platformFeeBps;
    uint16 public creatorFeeBps;
    uint16 public antiSnipeFeeBps;
    uint32 public antiSnipeDuration;
    uint64 public launchedAt;
    State public state;

    uint256 public initialVirtualEth;
    uint256 public virtualTokenReserve;
    uint256 public realEthReserve;
    uint256 public creatorFeesAccrued;

    address public locker;
    uint256 public graduationFee;
    uint256 public graduationReward;

    mapping(address account => uint256 l2Block) public lastBuyBlock;

    event Buy(
        address indexed buyer,
        uint256 ethSpent,
        uint256 tokensOut,
        uint256 platformFee,
        uint256 creatorFee,
        uint256 virtualEthReserve,
        uint256 virtualTokenReserve
    );
    event Sell(
        address indexed seller,
        uint256 tokensIn,
        uint256 ethOut,
        uint256 platformFee,
        uint256 creatorFee,
        uint256 virtualEthReserve,
        uint256 virtualTokenReserve
    );
    event CurveCompleted(uint256 realEthReserve);
    event CurveGraduated(
        address indexed caller, uint256 ethToPool, uint256 tokensToPool, uint256 tokensBurned
    );
    event CreatorFeesClaimed(address indexed creator, uint256 amount);

    error OnlyFactory();
    error OnlyCreator();
    error ZeroAddress();
    error InvalidTargetRaise();
    error FeeTooHigh();
    error InvalidAntiSnipe();
    error InvalidToken();
    error NotTrading();
    error DeadlineExpired();
    error ZeroAmount();
    error SlippageExceeded();
    error OneBuyPerBlock();
    error CreatorBuyNotFirst();
    error CreatorBuyTooLarge();
    error NothingToClaim();
    error InvalidGraduationFee();
    error NotComplete();
    error EthTransferFailed();

    modifier onlyTrading() {
        if (state != State.Trading) revert NotTrading();
        _;
    }

    modifier beforeDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    constructor() {
        factory = msg.sender;
        _disableInitializers();
    }

    // ---------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------

    function initialize(Config calldata config) external initializer {
        if (msg.sender != factory) revert OnlyFactory();
        if (config.token == address(0) || config.creator == address(0)) revert ZeroAddress();
        if (config.feeVault == address(0) || config.locker == address(0)) revert ZeroAddress();
        if (config.targetRaise < MIN_TARGET_RAISE || config.targetRaise > MAX_TARGET_RAISE) {
            revert InvalidTargetRaise();
        }
        if (uint256(config.platformFeeBps) + config.creatorFeeBps > MAX_TRADE_FEE_BPS) {
            revert FeeTooHigh();
        }
        if (
            config.antiSnipeFeeBps > MAX_ANTI_SNIPE_FEE_BPS
                || config.antiSnipeDuration > MAX_ANTI_SNIPE_DURATION
        ) revert InvalidAntiSnipe();
        if (
            config.graduationFee
                    > config.targetRaise * LaunchLimits.MAX_GRADUATION_FEE_BPS_OF_RAISE / BPS
                || config.graduationReward > config.graduationFee
        ) revert InvalidGraduationFee();

        IERC20 token_ = IERC20(config.token);
        if (
            token_.totalSupply() != BondingCurveMath.TOTAL_SUPPLY
                || token_.balanceOf(address(this)) != BondingCurveMath.TOTAL_SUPPLY
        ) revert InvalidToken();

        token = token_;
        creator = config.creator;
        feeVault = config.feeVault;
        platformFeeBps = config.platformFeeBps;
        creatorFeeBps = config.creatorFeeBps;
        antiSnipeFeeBps = config.antiSnipeFeeBps;
        antiSnipeDuration = config.antiSnipeDuration;
        locker = config.locker;
        graduationFee = config.graduationFee;
        graduationReward = config.graduationReward;
        launchedAt = uint64(block.timestamp);
        initialVirtualEth = BondingCurveMath.initialVirtualEth(config.targetRaise);
        virtualTokenReserve = BondingCurveMath.INITIAL_VIRTUAL_TOKEN_RESERVE;
    }

    // ---------------------------------------------------------------------
    // Trading
    // ---------------------------------------------------------------------

    /// @notice Buys tokens with all of `msg.value`. If the buy would exceed the tokens left on the
    /// curve, only the remainder is bought, the curve completes and the unused ETH is refunded.
    function buy(uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        onlyTrading
        beforeDeadline(deadline)
        returns (uint256)
    {
        return _buy(msg.sender, msg.value, minTokensOut, currentBuyFeeBps());
    }

    /// @notice The creator's optional first buy, executed by the factory in the same transaction
    /// that creates the coin. Pays normal trade fees but no anti-snipe fee.
    function creatorBuy(uint256 minTokensOut, uint256 maxTokensOut)
        external
        payable
        nonReentrant
        onlyTrading
        returns (uint256 tokensOut)
    {
        if (msg.sender != factory) revert OnlyFactory();
        if (virtualTokenReserve != BondingCurveMath.INITIAL_VIRTUAL_TOKEN_RESERVE) {
            revert CreatorBuyNotFirst();
        }
        tokensOut = _buy(creator, msg.value, minTokensOut, uint256(platformFeeBps) + creatorFeeBps);
        if (tokensOut > maxTokensOut) revert CreatorBuyTooLarge();
    }

    function sell(uint256 tokensIn, uint256 minEthOut, uint256 deadline)
        external
        nonReentrant
        onlyTrading
        beforeDeadline(deadline)
        returns (uint256)
    {
        if (tokensIn == 0) revert ZeroAmount();
        SellQuote memory quote = _quoteSell(tokensIn);
        if (quote.ethOut == 0) revert ZeroAmount();
        if (quote.ethOut < minEthOut) revert SlippageExceeded();

        realEthReserve -= quote.grossEth;
        virtualTokenReserve += tokensIn;
        creatorFeesAccrued += quote.creatorFee;

        emit Sell(
            msg.sender,
            tokensIn,
            quote.ethOut,
            quote.platformFee,
            quote.creatorFee,
            virtualEthReserve(),
            virtualTokenReserve
        );

        token.safeTransferFrom(msg.sender, address(this), tokensIn);
        _sendEth(feeVault, quote.platformFee);
        _sendEth(msg.sender, quote.ethOut);
        return quote.ethOut;
    }

    /// @notice Moves a sold-out curve into its Uniswap v4 pool. Anyone may call it; the result is
    /// fully determined on chain, and the caller receives `graduationReward`.
    /// @dev The pool receives the raised ETH minus the graduation fee, paired with exactly enough
    /// tokens to open at the curve's final price. Every other token still held is burned.
    function graduate() external nonReentrant {
        if (state != State.Complete) revert NotComplete();
        state = State.Graduated;

        uint256 ethToPool = realEthReserve - graduationFee;
        uint256 tokensToPool = Math.min(
            BondingCurveMath.poolTokensForEth(ethToPool, virtualEthReserve(), virtualTokenReserve),
            BondingCurveMath.POOL_SUPPLY
        );
        realEthReserve = 0;
        uint256 tokensToBurn = token.balanceOf(address(this)) - tokensToPool;

        emit CurveGraduated(msg.sender, ethToPool, tokensToPool, tokensToBurn);

        token.safeTransfer(DEAD, tokensToBurn);
        token.forceApprove(locker, tokensToPool);
        IGraduationLocker(locker).graduate{value: ethToPool}(address(token), creator, tokensToPool);

        // Anything above the creator's unclaimed fees is the platform's graduation fee plus any
        // ETH force-sent to this contract; the caller's reward comes out of it.
        uint256 surplus = address(this).balance - creatorFeesAccrued;
        _sendEth(feeVault, surplus - graduationReward);
        _sendEth(msg.sender, graduationReward);
    }

    function claimCreatorFees() external nonReentrant returns (uint256 amount) {
        if (msg.sender != creator) revert OnlyCreator();
        amount = creatorFeesAccrued;
        if (amount == 0) revert NothingToClaim();

        creatorFeesAccrued = 0;
        emit CreatorFeesClaimed(msg.sender, amount);

        _sendEth(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function virtualEthReserve() public view returns (uint256) {
        return initialVirtualEth + realEthReserve;
    }

    function tokensRemaining() public view returns (uint256) {
        return virtualTokenReserve - BondingCurveMath.FINAL_VIRTUAL_TOKEN_RESERVE;
    }

    /// @notice Anti-snipe surcharge in basis points, decaying linearly to zero over
    /// `antiSnipeDuration` seconds after launch.
    function currentAntiSnipeFeeBps() public view returns (uint256) {
        uint256 elapsed = block.timestamp - launchedAt;
        if (elapsed >= antiSnipeDuration) return 0;
        return Math.mulDiv(antiSnipeFeeBps, antiSnipeDuration - elapsed, antiSnipeDuration);
    }

    function currentBuyFeeBps() public view returns (uint256) {
        return uint256(platformFeeBps) + creatorFeeBps + currentAntiSnipeFeeBps();
    }

    function quoteBuy(uint256 ethIn) external view onlyTrading returns (BuyQuote memory) {
        return _quoteBuy(ethIn, currentBuyFeeBps());
    }

    function quoteSell(uint256 tokensIn) external view onlyTrading returns (SellQuote memory) {
        return _quoteSell(tokensIn);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _buy(address buyer, uint256 ethIn, uint256 minTokensOut, uint256 feeBps)
        private
        returns (uint256)
    {
        if (ethIn == 0) revert ZeroAmount();
        uint256 l2Block = ArbBlock.number();
        if (lastBuyBlock[buyer] == l2Block) revert OneBuyPerBlock();
        lastBuyBlock[buyer] = l2Block;

        BuyQuote memory quote = _quoteBuy(ethIn, feeBps);
        if (quote.tokensOut == 0) revert ZeroAmount();
        if (quote.tokensOut < minTokensOut) revert SlippageExceeded();

        realEthReserve += quote.ethToCurve;
        virtualTokenReserve -= quote.tokensOut;
        creatorFeesAccrued += quote.creatorFee;
        bool completed = virtualTokenReserve == BondingCurveMath.FINAL_VIRTUAL_TOKEN_RESERVE;
        if (completed) state = State.Complete;

        emit Buy(
            buyer,
            quote.ethSpent,
            quote.tokensOut,
            quote.platformFee,
            quote.creatorFee,
            virtualEthReserve(),
            virtualTokenReserve
        );
        if (completed) emit CurveCompleted(realEthReserve);

        token.safeTransfer(buyer, quote.tokensOut);
        _sendEth(feeVault, quote.platformFee);
        _sendEth(buyer, ethIn - quote.ethSpent);
        return quote.tokensOut;
    }

    function _quoteBuy(uint256 ethIn, uint256 feeBps) private view returns (BuyQuote memory quote) {
        uint256 virtualEth = virtualEthReserve();
        uint256 virtualToken = virtualTokenReserve;
        uint256 remaining = tokensRemaining();

        uint256 netIn = Math.mulDiv(ethIn, BPS - feeBps, BPS);
        uint256 tokensOut = BondingCurveMath.tokensOutForEthIn(virtualEth, virtualToken, netIn);

        if (tokensOut < remaining) {
            quote.tokensOut = tokensOut;
            quote.ethToCurve = netIn;
            quote.ethSpent = ethIn;
        } else {
            quote.tokensOut = remaining;
            quote.ethToCurve =
                BondingCurveMath.ethInForTokensOut(virtualEth, virtualToken, remaining);
            quote.ethSpent = Math.mulDiv(quote.ethToCurve, BPS, BPS - feeBps, Math.Rounding.Ceil);
        }

        (quote.platformFee, quote.creatorFee) = _splitFee(quote.ethSpent - quote.ethToCurve, feeBps);
    }

    function _quoteSell(uint256 tokensIn) private view returns (SellQuote memory quote) {
        uint256 feeBps = uint256(platformFeeBps) + creatorFeeBps;
        quote.grossEth =
            BondingCurveMath.ethOutForTokensIn(virtualEthReserve(), virtualTokenReserve, tokensIn);
        uint256 fee = Math.mulDiv(quote.grossEth, feeBps, BPS);
        quote.ethOut = quote.grossEth - fee;
        (quote.platformFee, quote.creatorFee) = _splitFee(fee, feeBps);
    }

    /// @dev The creator receives its configured share of `fee`; the platform receives the rest,
    /// which includes any anti-snipe surcharge.
    function _splitFee(uint256 fee, uint256 feeBps)
        private
        view
        returns (uint256 platformFee, uint256 creatorFee)
    {
        if (feeBps == 0) return (fee, 0);
        creatorFee = Math.mulDiv(fee, creatorFeeBps, feeBps);
        platformFee = fee - creatorFee;
    }

    function _sendEth(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool success,) = to.call{value: amount}("");
        if (!success) revert EthTransferFailed();
    }
}
