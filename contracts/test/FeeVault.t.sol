// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FeeVault} from "../src/FeeVault.sol";

contract FeeVaultTest is Test {
    FeeVault internal vault;
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vault = new FeeVault(owner);
    }

    function test_ReceivesEthWithMinimalGas() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(vault).call{value: 1 ether, gas: 2_300}("");
        assertTrue(success);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_OwnerWithdraws() public {
        vm.deal(address(vault), 3 ether);

        vm.expectEmit(address(vault));
        emit FeeVault.Withdrawn(treasury, 2 ether);
        vm.prank(owner);
        vault.withdraw(treasury, 2 ether);

        assertEq(treasury.balance, 2 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_RevertWhen_NonOwnerWithdraws() public {
        vm.deal(address(vault), 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.withdraw(alice, 1 ether);
    }

    function test_RevertWhen_WithdrawToZeroAddress() public {
        vm.deal(address(vault), 1 ether);
        vm.prank(owner);
        vm.expectRevert(FeeVault.ZeroAddress.selector);
        vault.withdraw(address(0), 1 ether);
    }

    function test_RevertWhen_WithdrawMoreThanBalance() public {
        vm.prank(owner);
        vm.expectRevert(FeeVault.EthTransferFailed.selector);
        vault.withdraw(treasury, 1 ether);
    }

    function test_OwnershipTransferIsTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(alice);
        assertEq(vault.owner(), owner);
        assertEq(vault.pendingOwner(), alice);

        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.owner(), alice);
    }
}
