// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockLocker} from "../mocks/MockLocker.sol";

/// @notice Deploys a curve the same way the factory will: the test contract deploys the
/// implementation (and so acts as its factory), clones it, mints the token to the clone and
/// initialises it.
abstract contract CurveTestBase is Test {
    uint256 internal constant TARGET_RAISE = 4 ether;
    uint16 internal constant PLATFORM_FEE_BPS = 95;
    uint16 internal constant CREATOR_FEE_BPS = 30;
    uint16 internal constant ANTI_SNIPE_FEE_BPS = 5_000;
    uint32 internal constant ANTI_SNIPE_DURATION = 30;
    uint256 internal constant GRADUATION_FEE = 0.02 ether;
    uint256 internal constant GRADUATION_REWARD = 0.001 ether;

    BondingCurve internal implementation;
    BondingCurve internal curve;
    LaunchToken internal token;
    MockLocker internal locker;

    address internal creator = makeAddr("creator");
    address internal feeVault = makeAddr("feeVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        vm.etch(address(100), address(new MockArbSys()).code);
        vm.warp(1_700_000_000);
        vm.roll(100);

        implementation = new BondingCurve();
        locker = new MockLocker();
        (curve, token) = _launch(_defaultConfig());
    }

    /// @dev `token` is left empty; `_launch` fills it in once the token is deployed.
    function _defaultConfig() internal view returns (BondingCurve.Config memory) {
        return BondingCurve.Config({
            token: address(0),
            creator: creator,
            feeVault: feeVault,
            targetRaise: TARGET_RAISE,
            platformFeeBps: PLATFORM_FEE_BPS,
            creatorFeeBps: CREATOR_FEE_BPS,
            antiSnipeFeeBps: ANTI_SNIPE_FEE_BPS,
            antiSnipeDuration: ANTI_SNIPE_DURATION,
            locker: address(locker),
            graduationFee: GRADUATION_FEE,
            graduationReward: GRADUATION_REWARD
        });
    }

    function _launch(BondingCurve.Config memory config)
        internal
        returns (BondingCurve curve_, LaunchToken token_)
    {
        curve_ = BondingCurve(Clones.clone(address(implementation)));
        token_ = new LaunchToken("Test Coin", "TEST", address(curve_));
        config.token = address(token_);
        curve_.initialize(config);
    }

    function _skipAntiSnipe() internal {
        vm.warp(block.timestamp + ANTI_SNIPE_DURATION);
    }

    function _nextBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
    }

    function _buy(address buyer, uint256 ethIn) internal returns (uint256 tokensOut) {
        vm.deal(buyer, buyer.balance + ethIn);
        vm.prank(buyer);
        tokensOut = curve.buy{value: ethIn}(0, block.timestamp);
    }

    function _sell(address seller, uint256 tokensIn) internal returns (uint256 ethOut) {
        vm.startPrank(seller);
        token.approve(address(curve), tokensIn);
        ethOut = curve.sell(tokensIn, 0, block.timestamp);
        vm.stopPrank();
    }

    function _assertEthAccounted() internal view {
        assertEq(address(curve).balance, curve.realEthReserve() + curve.creatorFeesAccrued(), "eth");
    }
}
