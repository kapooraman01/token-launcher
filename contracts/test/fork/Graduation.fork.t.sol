// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {FeeVault} from "../../src/FeeVault.sol";
import {GraduationLocker} from "../../src/GraduationLocker.sol";
import {LaunchFactory} from "../../src/LaunchFactory.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {BondingCurveMath} from "../../src/libraries/BondingCurveMath.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {FactoryDeployer} from "../utils/FactoryDeployer.sol";
import {PoolSwapper} from "../utils/PoolSwapper.sol";

/// @notice Tries to remove liquidity from a pool position it does not own.
contract LiquidityThief is IUnlockCallback {
    IPoolManager internal immutable poolManager;
    PoolKey internal key;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function steal(PoolKey memory key_, int24 tickLower, int24 tickUpper) external {
        key = key_;
        poolManager.unlock(abi.encode(tickLower, tickUpper));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (int24 tickLower, int24 tickUpper) = abi.decode(data, (int24, int24));
        poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -1e18, salt: bytes32(0)
            }),
            ""
        );
        return "";
    }
}

/// @notice Graduation and post-graduation trading against Uniswap v4 on a fork of Robinhood Chain
/// testnet. Set ROBINHOOD_TESTNET_RPC to use another endpoint and FORK_BLOCK to pin a block.
contract GraduationForkTest is FactoryDeployer {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    IPoolManager internal constant PM = IPoolManager(POOL_MANAGER);

    FeeVault internal vault;
    LaunchFactory internal factory;
    GraduationLocker internal locker;
    PoolSwapper internal swapper;
    LaunchToken internal token;
    BondingCurve internal curve;

    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    address internal whale = makeAddr("whale");
    address internal keeper = makeAddr("keeper");
    address internal trader = makeAddr("trader");

    function setUp() public {
        string memory rpc =
            vm.envOr("ROBINHOOD_TESTNET_RPC", string("https://rpc.testnet.chain.robinhood.com"));
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        vm.etch(address(100), address(new MockArbSys()).code);

        vault = new FeeVault(owner);
        factory = _deployFactory(_defaultSettings(owner, address(vault)));
        locker = GraduationLocker(payable(factory.locker()));
        swapper = new PoolSwapper(PM);

        vm.deal(creator, 1 ether);
        vm.prank(creator);
        (address token_, address curve_) =
            factory.createCoin{value: 0.01 ether}("Fork Coin", "FORK", 0, block.timestamp);
        token = LaunchToken(token_);
        curve = BondingCurve(curve_);
        vm.warp(block.timestamp + 60);
    }

    function _fillCurve() internal {
        vm.roll(block.number + 1);
        vm.deal(whale, 20 ether);
        vm.prank(whale);
        curve.buy{value: 20 ether}(0, block.timestamp);
        assertEq(uint256(curve.state()), uint256(BondingCurve.State.Complete));
    }

    function _graduate() internal {
        vm.prank(keeper);
        curve.graduate();
    }

    function _key() internal view returns (PoolKey memory) {
        return locker.poolKey(address(token));
    }

    function _fullRangeTicks() internal pure returns (int24, int24) {
        return (TickMath.minUsableTick(200), TickMath.maxUsableTick(200));
    }

    // ---------------------------------------------------------------------
    // Graduation
    // ---------------------------------------------------------------------

    function test_GraduationOpensPoolAtCurvePriceAndLocksLiquidity() public {
        _fillCurve();
        uint256 raised = curve.realEthReserve();
        uint256 finalVirtualEth = curve.virtualEthReserve();
        uint256 finalVirtualToken = curve.virtualTokenReserve();
        uint256 creatorFees = curve.creatorFeesAccrued();
        uint256 vaultBefore = address(vault).balance;
        uint256 poolManagerEthBefore = address(PM).balance;

        _graduate();

        assertEq(uint256(curve.state()), uint256(BondingCurve.State.Graduated));
        assertEq(curve.realEthReserve(), 0);
        assertEq(address(curve).balance, creatorFees, "curve keeps only creator fees");
        assertEq(token.balanceOf(address(curve)), 0, "curve keeps no tokens");
        assertEq(keeper.balance, 0.001 ether, "caller reward");
        assertEq(locker.creatorOf(address(token)), creator);

        _assertPoolAtPrice(finalVirtualEth, finalVirtualToken);
        assertGt(PM.getLiquidity(_key().toId()), 0);

        // The pool holds the raised ETH less the graduation fee, minus liquidity rounding dust
        // (which goes to the platform); the reserved tokens are either in the pool or burned.
        uint256 ethToPool = raised - 0.02 ether;
        uint256 dust = ethToPool - (address(PM).balance - poolManagerEthBefore);
        assertLe(dust, ethToPool / 1e12, "rounding dust is negligible");
        assertEq(
            token.balanceOf(DEAD) + token.balanceOf(address(PM)),
            BondingCurveMath.POOL_SUPPLY,
            "pool tokens + burned = reserved supply"
        );
        assertEq(token.balanceOf(address(locker)), 0, "locker keeps no tokens");
        assertEq(address(locker).balance, 0, "locker keeps no eth");
        assertEq(address(vault).balance - vaultBefore, 0.02 ether - 0.001 ether + dust);
    }

    function test_RevertWhen_GraduatingBeforeCompletion() public {
        vm.expectRevert(BondingCurve.NotComplete.selector);
        curve.graduate();
    }

    function test_RevertWhen_GraduatingTwice() public {
        _fillCurve();
        _graduate();
        vm.expectRevert(BondingCurve.NotComplete.selector);
        curve.graduate();
    }

    function test_TradingOnTheCurveStaysClosedAfterGraduation() public {
        _fillCurve();
        _graduate();
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        vm.expectRevert(BondingCurve.NotTrading.selector);
        curve.buy{value: 1 ether}(0, block.timestamp);
    }

    function test_CreatorCanStillClaimCurveFeesAfterGraduation() public {
        _fillCurve();
        uint256 accrued = curve.creatorFeesAccrued();
        _graduate();
        vm.prank(creator);
        assertEq(curve.claimCreatorFees(), accrued);
        assertEq(address(curve).balance, 0);
    }

    function test_ForceSentEthAndDonatedTokensAreSweptAtGraduation() public {
        _fillCurve();
        vm.prank(whale);
        token.transfer(address(curve), 1_000 ether);
        vm.deal(address(curve), address(curve).balance + 1 ether);
        uint256 vaultBefore = address(vault).balance;
        uint256 creatorFees = curve.creatorFeesAccrued();

        _graduate();

        assertEq(address(curve).balance, creatorFees);
        assertEq(token.balanceOf(address(curve)), 0);
        assertApproxEqAbs(
            address(vault).balance - vaultBefore, 1 ether + 0.02 ether - 0.001 ether, 1e7
        );
    }

    function test_AnotherCallerCanGraduateIfTheFirstRejectsTheReward() public {
        _fillCurve();
        RewardRejecter rejecter = new RewardRejecter();
        vm.expectRevert(BondingCurve.EthTransferFailed.selector);
        rejecter.graduate(curve);

        _graduate();
        assertEq(uint256(curve.state()), uint256(BondingCurve.State.Graduated));
    }

    // ---------------------------------------------------------------------
    // Attacks
    // ---------------------------------------------------------------------

    function test_NobodyCanCreateOurPoolEarly() public {
        PoolKey memory key = _key();
        vm.prank(trader);
        vm.expectRevert();
        PM.initialize(key, TickMath.getSqrtPriceAtTick(-200_000));

        _fillCurve();
        _graduate();
        assertGt(PM.getLiquidity(key.toId()), 0);
    }

    function test_AHooklessPoolForTheSameTokenDoesNotAffectGraduation() public {
        PoolKey memory rogue = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        vm.prank(trader);
        PM.initialize(rogue, TickMath.getSqrtPriceAtTick(-200_000));

        _fillCurve();
        uint256 finalVirtualEth = curve.virtualEthReserve();
        uint256 finalVirtualToken = curve.virtualTokenReserve();
        _graduate();

        _assertPoolAtPrice(finalVirtualEth, finalVirtualToken);
    }

    function test_RevertWhen_SomeoneOtherThanTheCurveCallsLockerGraduate() public {
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        vm.expectRevert(GraduationLocker.OnlyCurve.selector);
        locker.graduate{value: 1 ether}(address(token), trader, 1);
    }

    function test_RevertWhen_HookOrCallbackCalledDirectly() public {
        PoolKey memory key = _key();
        vm.startPrank(trader);
        vm.expectRevert(GraduationLocker.OnlyPoolManager.selector);
        locker.beforeInitialize(address(locker), key, 1);

        vm.expectRevert(GraduationLocker.OnlyPoolManager.selector);
        locker.unlockCallback(abi.encode(uint8(0), address(token), uint256(1), uint256(1)));
        vm.stopPrank();
    }

    function test_RevertWhen_EthSentToLockerDirectly() public {
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        (bool success,) = address(locker).call{value: 1 ether}("");
        assertFalse(success);
    }

    function test_LockedLiquidityCannotBeRemoved() public {
        _fillCurve();
        _graduate();
        PoolKey memory key = _key();
        (int24 tickLower, int24 tickUpper) = _fullRangeTicks();
        PoolId id = key.toId();
        (uint128 lockedBefore,,) =
            PM.getPositionInfo(id, address(locker), tickLower, tickUpper, bytes32(0));

        LiquidityThief thief = new LiquidityThief(PM);
        vm.expectRevert();
        thief.steal(key, tickLower, tickUpper);

        (uint128 lockedAfter,,) =
            PM.getPositionInfo(id, address(locker), tickLower, tickUpper, bytes32(0));
        assertEq(lockedAfter, lockedBefore);
        assertGt(lockedAfter, 0);
    }

    // ---------------------------------------------------------------------
    // Post-graduation trading and fees
    // ---------------------------------------------------------------------

    function test_SwapsEarnFeesSplitBetweenCreatorAndPlatform() public {
        _fillCurve();
        _graduate();
        PoolKey memory key = _key();

        vm.deal(trader, 1 ether);
        vm.prank(trader);
        uint256 bought = swapper.buy{value: 1 ether}(key);
        assertGt(bought, 0);

        vm.startPrank(trader);
        token.approve(address(swapper), bought / 2);
        uint256 ethBack = swapper.sell(key, bought / 2);
        vm.stopPrank();
        assertGt(ethBack, 0);

        uint256 vaultEthBefore = address(vault).balance;
        (uint256 ethFees, uint256 tokenFees) = locker.collectFees(address(token));

        // 1% of the 1 ETH buy and of the token sell, less Uniswap rounding.
        assertApproxEqRel(ethFees, 0.01 ether, 0.001e18);
        assertApproxEqRel(tokenFees, (bought / 2) / 100, 0.001e18);

        uint256 creatorEth = locker.claimable(creator, address(0));
        uint256 creatorTokens = locker.claimable(creator, address(token));
        assertEq(creatorEth, ethFees / 2);
        assertEq(creatorTokens, tokenFees / 2);
        assertEq(address(vault).balance - vaultEthBefore, ethFees - creatorEth);
        assertEq(token.balanceOf(address(vault)), tokenFees - creatorTokens);

        vm.startPrank(creator);
        uint256 creatorBalance = creator.balance;
        assertEq(locker.claim(address(0)), creatorEth);
        assertEq(locker.claim(address(token)), creatorTokens);
        vm.stopPrank();
        assertEq(creator.balance - creatorBalance, creatorEth);
        assertEq(token.balanceOf(creator) >= creatorTokens, true);

        // The locker holds nothing once everything is claimed.
        assertEq(address(locker).balance, 0);
        assertEq(token.balanceOf(address(locker)), 0);
    }

    function test_CollectingWithNoTradesIsHarmless() public {
        _fillCurve();
        _graduate();
        (uint256 ethFees, uint256 tokenFees) = locker.collectFees(address(token));
        assertEq(ethFees, 0);
        assertEq(tokenFees, 0);
    }

    function test_RevertWhen_CollectingForACoinThatHasNotGraduated() public {
        vm.expectRevert(GraduationLocker.NotGraduated.selector);
        locker.collectFees(address(token));
    }

    function test_RevertWhen_ClaimingNothing() public {
        vm.prank(trader);
        vm.expectRevert(GraduationLocker.NothingToClaim.selector);
        locker.claim(address(0));
    }

    function test_FeeVaultOwnerCanWithdrawTokenFees() public {
        _fillCurve();
        _graduate();
        PoolKey memory key = _key();
        vm.deal(trader, 1 ether);
        vm.startPrank(trader);
        uint256 bought = swapper.buy{value: 1 ether}(key);
        token.approve(address(swapper), bought);
        swapper.sell(key, bought);
        vm.stopPrank();
        locker.collectFees(address(token));

        uint256 vaultTokens = token.balanceOf(address(vault));
        assertGt(vaultTokens, 0);
        vm.prank(owner);
        vault.withdrawToken(token, owner, vaultTokens);
        assertEq(token.balanceOf(owner), vaultTokens);
    }

    /// @dev Pool price (tokens per ETH, as Q96) must equal the curve's final virtual price.
    function _assertPoolAtPrice(uint256 virtualEth, uint256 virtualToken) internal view {
        (uint160 sqrtPrice,,,) = PM.getSlot0(_key().toId());
        uint256 poolPriceX96 = (uint256(sqrtPrice) * uint256(sqrtPrice)) >> 96;
        uint256 curvePriceX96 = virtualToken * 2 ** 96 / virtualEth;
        assertApproxEqRel(poolPriceX96, curvePriceX96, 1e9, "pool opens at curve price");
    }
}

contract RewardRejecter {
    function graduate(BondingCurve curve) external {
        curve.graduate();
    }
}
