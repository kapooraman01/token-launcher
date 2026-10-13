// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BondingCurve} from "./BondingCurve.sol";
import {GraduationLocker} from "./GraduationLocker.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {BondingCurveMath} from "./libraries/BondingCurveMath.sol";
import {LaunchLimits} from "./libraries/LaunchLimits.sol";

/// @title LaunchFactory
/// @notice Launches coins: deploys the token, clones a bonding curve for it and optionally runs the
/// creator's first buy, all in one transaction. The owner can only change fee settings for coins
/// launched afterwards and pause new launches; it has no power over existing curves. Graduation
/// settings and the GraduationLocker are fixed for the life of the factory.
contract LaunchFactory is Ownable2Step, Pausable, ReentrancyGuardTransient {
    struct Settings {
        address owner;
        address feeVault;
        uint256 targetRaise;
        uint16 platformFeeBps;
        uint16 creatorFeeBps;
        uint16 antiSnipeFeeBps;
        uint32 antiSnipeDuration;
        uint16 maxCreatorBuyBps;
        uint256 maxCreatorBuyEth;
        address poolManager;
        bytes32 lockerSalt;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 lockerCreatorShareBps;
        uint256 graduationFee;
        uint256 graduationReward;
    }

    uint256 public constant MAX_CREATOR_BUY_BPS = LaunchLimits.MAX_CREATOR_BUY_BPS;
    uint256 public constant MAX_NAME_LENGTH = 32;
    uint256 public constant MAX_SYMBOL_LENGTH = 10;

    address public immutable implementation;
    address public immutable feeVault;
    uint256 public immutable targetRaise;
    uint256 public immutable maxCreatorBuyTokens;
    uint256 public immutable maxCreatorBuyEth;
    address public immutable locker;
    uint256 public immutable graduationFee;
    uint256 public immutable graduationReward;

    uint16 public platformFeeBps;
    uint16 public creatorFeeBps;
    uint16 public antiSnipeFeeBps;
    uint32 public antiSnipeDuration;

    uint256 public coinCount;
    mapping(address token => address curve) public curveOf;
    mapping(address curve => bool) public isCurve;

    event CoinCreated(
        address indexed token,
        address indexed curve,
        address indexed creator,
        string name,
        string symbol,
        uint256 targetRaise,
        uint16 platformFeeBps,
        uint16 creatorFeeBps,
        uint16 antiSnipeFeeBps,
        uint32 antiSnipeDuration
    );
    event TradeFeesUpdated(uint16 platformFeeBps, uint16 creatorFeeBps);
    event AntiSnipeUpdated(uint16 antiSnipeFeeBps, uint32 antiSnipeDuration);

    error ZeroAddress();
    error InvalidTargetRaise();
    error FeeTooHigh();
    error InvalidAntiSnipe();
    error InvalidCreatorBuyCap();
    error InvalidGraduationFee();
    error InvalidName();
    error InvalidSymbol();
    error DeadlineExpired();
    error CreatorBuyTooLarge();

    constructor(Settings memory settings) Ownable(settings.owner) {
        if (settings.feeVault == address(0)) revert ZeroAddress();
        if (
            settings.targetRaise < LaunchLimits.MIN_TARGET_RAISE
                || settings.targetRaise > LaunchLimits.MAX_TARGET_RAISE
        ) revert InvalidTargetRaise();
        if (settings.maxCreatorBuyBps > MAX_CREATOR_BUY_BPS) revert InvalidCreatorBuyCap();
        if (
            settings.graduationFee
                    > settings.targetRaise * LaunchLimits.MAX_GRADUATION_FEE_BPS_OF_RAISE
                        / LaunchLimits.BPS || settings.graduationReward > settings.graduationFee
        ) revert InvalidGraduationFee();

        implementation = address(new BondingCurve());
        feeVault = settings.feeVault;
        targetRaise = settings.targetRaise;
        maxCreatorBuyTokens =
            BondingCurveMath.CURVE_SUPPLY * settings.maxCreatorBuyBps / LaunchLimits.BPS;
        maxCreatorBuyEth = settings.maxCreatorBuyEth;
        graduationFee = settings.graduationFee;
        graduationReward = settings.graduationReward;

        _setTradeFees(settings.platformFeeBps, settings.creatorFeeBps);
        _setAntiSnipe(settings.antiSnipeFeeBps, settings.antiSnipeDuration);

        locker = address(
            new GraduationLocker{salt: settings.lockerSalt}(
                IPoolManager(settings.poolManager),
                settings.feeVault,
                settings.poolFee,
                settings.tickSpacing,
                settings.lockerCreatorShareBps
            )
        );
    }

    // ---------------------------------------------------------------------
    // Launch
    // ---------------------------------------------------------------------

    /// @notice Launches a coin. Any ETH sent is spent on the creator's first buy, which happens
    /// before anyone else can trade and is capped by `maxCreatorBuyEth` and `maxCreatorBuyTokens`.
    function createCoin(
        string calldata name,
        string calldata symbol,
        uint256 minTokensOut,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused returns (address token, address curve) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (bytes(name).length == 0 || bytes(name).length > MAX_NAME_LENGTH) revert InvalidName();
        if (bytes(symbol).length == 0 || bytes(symbol).length > MAX_SYMBOL_LENGTH) {
            revert InvalidSymbol();
        }
        if (msg.value > maxCreatorBuyEth) revert CreatorBuyTooLarge();

        curve = Clones.clone(implementation);
        token = address(new LaunchToken(name, symbol, curve));

        coinCount++;
        curveOf[token] = curve;
        isCurve[curve] = true;

        BondingCurve(curve)
            .initialize(
                BondingCurve.Config({
                token: token,
                creator: msg.sender,
                feeVault: feeVault,
                targetRaise: targetRaise,
                platformFeeBps: platformFeeBps,
                creatorFeeBps: creatorFeeBps,
                antiSnipeFeeBps: antiSnipeFeeBps,
                antiSnipeDuration: antiSnipeDuration,
                locker: locker,
                graduationFee: graduationFee,
                graduationReward: graduationReward
            })
            );

        emit CoinCreated(
            token,
            curve,
            msg.sender,
            name,
            symbol,
            targetRaise,
            platformFeeBps,
            creatorFeeBps,
            antiSnipeFeeBps,
            antiSnipeDuration
        );

        if (msg.value > 0) {
            BondingCurve(curve).creatorBuy{value: msg.value}(minTokensOut, maxCreatorBuyTokens);
        }
    }

    // ---------------------------------------------------------------------
    // Admin: affects only coins launched after the change
    // ---------------------------------------------------------------------

    function setTradeFees(uint16 platformFeeBps_, uint16 creatorFeeBps_) external onlyOwner {
        _setTradeFees(platformFeeBps_, creatorFeeBps_);
    }

    function setAntiSnipe(uint16 antiSnipeFeeBps_, uint32 antiSnipeDuration_) external onlyOwner {
        _setAntiSnipe(antiSnipeFeeBps_, antiSnipeDuration_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _setTradeFees(uint16 platformFeeBps_, uint16 creatorFeeBps_) private {
        if (uint256(platformFeeBps_) + creatorFeeBps_ > LaunchLimits.MAX_TRADE_FEE_BPS) {
            revert FeeTooHigh();
        }
        platformFeeBps = platformFeeBps_;
        creatorFeeBps = creatorFeeBps_;
        emit TradeFeesUpdated(platformFeeBps_, creatorFeeBps_);
    }

    function _setAntiSnipe(uint16 antiSnipeFeeBps_, uint32 antiSnipeDuration_) private {
        if (
            antiSnipeFeeBps_ > LaunchLimits.MAX_ANTI_SNIPE_FEE_BPS
                || antiSnipeDuration_ > LaunchLimits.MAX_ANTI_SNIPE_DURATION
        ) revert InvalidAntiSnipe();
        antiSnipeFeeBps = antiSnipeFeeBps_;
        antiSnipeDuration = antiSnipeDuration_;
        emit AntiSnipeUpdated(antiSnipeFeeBps_, antiSnipeDuration_);
    }
}
