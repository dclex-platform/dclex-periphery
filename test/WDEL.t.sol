// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {WDEL} from "../src/WDEL.sol";

contract WDELTest is Test {
    WDEL private wdel;
    address private user = makeAddr("user");

    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    function setUp() public {
        wdel = new WDEL();
        vm.deal(user, 100 ether);
    }

    function test_NameAndSymbol() public view {
        assertEq(wdel.name(), "Wrapped DEL");
        assertEq(wdel.symbol(), "WDEL");
        assertEq(wdel.decimals(), 18);
    }

    function test_Deposit() public {
        vm.prank(user);
        wdel.deposit{value: 1 ether}();
        assertEq(wdel.balanceOf(user), 1 ether);
        assertEq(address(wdel).balance, 1 ether);
    }

    function test_DepositEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Deposit(user, 1 ether);
        vm.prank(user);
        wdel.deposit{value: 1 ether}();
    }

    function test_DepositViaReceive() public {
        vm.prank(user);
        (bool ok, ) = address(wdel).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(wdel.balanceOf(user), 2 ether);
    }

    function test_Withdraw() public {
        vm.startPrank(user);
        wdel.deposit{value: 5 ether}();
        uint256 balanceBefore = user.balance;
        wdel.withdraw(3 ether);
        vm.stopPrank();
        assertEq(wdel.balanceOf(user), 2 ether);
        assertEq(user.balance, balanceBefore + 3 ether);
    }

    function test_WithdrawEmitsEvent() public {
        vm.startPrank(user);
        wdel.deposit{value: 5 ether}();
        vm.expectEmit(true, false, false, true);
        emit Withdrawal(user, 2 ether);
        wdel.withdraw(2 ether);
        vm.stopPrank();
    }

    function test_WithdrawRevertsInsufficientBalance() public {
        vm.prank(user);
        vm.expectRevert("WDEL: insufficient balance");
        wdel.withdraw(1 ether);
    }

    function test_MintOnlyLocal() public {
        // chainid 31337 in forge test — should work
        wdel.mint(user, 10 ether);
        assertEq(wdel.balanceOf(user), 10 ether);
    }

    function test_MintRevertsOnNonLocal() public {
        vm.chainId(2028);
        vm.expectRevert("WDEL: mint only on local");
        wdel.mint(user, 1 ether);
    }

    function test_DepositZero() public {
        vm.prank(user);
        wdel.deposit{value: 0}();
        assertEq(wdel.balanceOf(user), 0);
    }

    function test_WithdrawAll() public {
        vm.startPrank(user);
        wdel.deposit{value: 10 ether}();
        wdel.withdraw(10 ether);
        vm.stopPrank();
        assertEq(wdel.balanceOf(user), 0);
        assertEq(address(wdel).balance, 0);
    }

    function testFuzz_DepositWithdraw(uint96 amount) public {
        vm.assume(amount > 0);
        vm.deal(user, uint256(amount));
        vm.startPrank(user);
        wdel.deposit{value: amount}();
        assertEq(wdel.balanceOf(user), amount);
        wdel.withdraw(amount);
        assertEq(wdel.balanceOf(user), 0);
        vm.stopPrank();
    }
}
