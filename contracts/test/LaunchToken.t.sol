// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal curve = makeAddr("curve");

    function setUp() public {
        token = new LaunchToken("Test Coin", "TEST", curve);
    }

    function test_MetadataIsSet() public view {
        assertEq(token.name(), "Test Coin");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
    }

    function test_FullSupplyMintedToCurve() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 ether);
        assertEq(token.balanceOf(curve), token.totalSupply());
    }

    function test_RevertWhen_CurveIsZeroAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
        new LaunchToken("Test Coin", "TEST", address(0));
    }

    function test_HasNoPrivilegedFunctions() public {
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", address(this), 1);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1);
        calls[2] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[3] = abi.encodeWithSignature("burnFrom(address,uint256)", curve, 1);
        calls[4] = abi.encodeWithSignature("owner()");
        calls[5] = abi.encodeWithSignature("transferOwnership(address)", address(this));
        calls[6] = abi.encodeWithSignature("pause()");
        calls[7] = abi.encodeWithSignature("blacklist(address)", curve);
        calls[8] = abi.encodeWithSignature("setFee(uint256)", 1);
        calls[9] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(this), "");

        for (uint256 i = 0; i < calls.length; i++) {
            (bool success,) = address(token).call(calls[i]);
            assertFalse(success);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_RejectsPlainEtherTransfers() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(token).call{value: 1 ether}("");
        assertFalse(success);
    }

    function testFuzz_TransfersNeverChangeSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != curve);
        amount = bound(amount, 0, token.TOTAL_SUPPLY());

        vm.prank(curve);
        assertTrue(token.transfer(to, amount));

        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(curve), token.TOTAL_SUPPLY() - amount);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    function testFuzz_TransferFeeIsZero(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != curve);
        amount = bound(amount, 1, token.TOTAL_SUPPLY());

        uint256 before = token.balanceOf(to);
        vm.prank(curve);
        assertTrue(token.transfer(to, amount));

        assertEq(token.balanceOf(to) - before, amount);
    }
}
