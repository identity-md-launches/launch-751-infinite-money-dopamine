// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMD} from "src/IMD.sol";

/// forge-config: default.fuzz.runs = 1000
contract IMDAdversarialTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5EED);
    address internal constant OTHER = address(0xCAFE);
    IMD internal token;

    function setUp() public {
        token = new IMD();
    }

    function test_OneSmallestUnitCanBeTransferredAndReturned() public {
        assertTrue(token.transfer(ALICE, 1));
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        vm.prank(ALICE);
        assertTrue(token.transfer(address(this), 1));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ExhaustedAllowanceCannotBeSpentTwice() public {
        token.approve(SPENDER, 1);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 1));
        assertEq(token.allowance(address(this), SPENDER), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_MaximumFiniteAllowanceIsDecremented() public {
        token.approve(SPENDER, type(uint256).max - 1);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 1));
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max - 2);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
    }

    function test_InfiniteApprovalCanBeRevokedAndReplacedWithFiniteApproval() public {
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 1));
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);
        assertTrue(token.approve(SPENDER, 0));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 1);

        assertTrue(token.approve(SPENDER, 1));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 1));
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 2);
        assertEq(token.balanceOf(address(this)), SUPPLY - 2);
    }

    function test_SelfTransferStillRequiresSufficientBalance() public {
        token.transfer(ALICE, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1, 2));
        vm.prank(ALICE);
        token.transfer(ALICE, 2);

        vm.prank(ALICE);
        token.approve(SPENDER, 2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1, 2));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, ALICE, 2);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        assertEq(token.allowance(ALICE, SPENDER), 2);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_MaximumTransferValueRevertsWithoutOverflowOrAllowanceLoss() public {
        uint256 maximum = type(uint256).max;
        bytes memory error =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, maximum);
        vm.expectRevert(error);
        token.transfer(ALICE, maximum);
        token.approve(SPENDER, maximum);
        vm.expectRevert(error);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, maximum);
        assertEq(token.allowance(address(this), SPENDER), maximum);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_AllowanceIsScopedToBothOwnerAndSpender() public {
        token.transfer(ALICE, 100);
        token.transfer(BOB, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, 7);
        vm.prank(BOB);
        token.approve(SPENDER, 11);
        vm.prank(ALICE);
        token.approve(BOB, 13);
        vm.prank(SPENDER);
        token.approve(ALICE, 17);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, OTHER, 0, 1));
        vm.prank(OTHER);
        token.transferFrom(ALICE, OTHER, 1);
        assertEq(token.balanceOf(OTHER), 0);

        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, OTHER, 7));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.allowance(BOB, SPENDER), 11);
        assertEq(token.allowance(ALICE, BOB), 13);
        assertEq(token.allowance(SPENDER, ALICE), 17);
        assertEq(token.allowance(ALICE, OTHER), 0);
        assertEq(token.balanceOf(ALICE), 93);
        assertEq(token.balanceOf(BOB), 100);
        assertEq(token.balanceOf(SPENDER), 0);
        assertEq(token.balanceOf(OTHER), 7);
        assertEq(token.balanceOf(address(this)), SUPPLY - 200);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferringTokensDoesNotTransferTheSendersApproval() public {
        token.transfer(ALICE, 1);
        vm.startPrank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        assertTrue(token.transfer(BOB, 1));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(BOB, SPENDER, 1);
        assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
        assertEq(token.allowance(BOB, SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 1);
        assertEq(token.balanceOf(SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroTransferFromEmitsEventWithoutConsumingExistingApproval() public {
        token.transfer(ALICE, 1);
        vm.prank(ALICE);
        token.approve(SPENDER, 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(ALICE, BOB, 0);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        assertEq(token.allowance(ALICE, SPENDER), 1);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroValueDoesNotPermitAZeroRecipientOrSpender() public {
        token.approve(SPENDER, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);
        assertEq(token.allowance(address(this), address(0)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_FailedApprovedSpendCanBeRetriedAfterFunding(uint256 held, uint256 amount, bool infinite) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        token.transfer(ALICE, held);
        uint256 approved = infinite ? type(uint256).max : amount;
        vm.prank(ALICE);
        token.approve(SPENDER, approved);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, amount));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, amount);
        assertEq(token.allowance(ALICE, SPENDER), approved);
        assertEq(token.balanceOf(ALICE), held);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);

        // The failed spend must not consume permission: fund the owner and retry unchanged.
        assertTrue(token.transfer(ALICE, amount - held));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, amount));
        assertEq(token.allowance(ALICE, SPENDER), infinite ? type(uint256).max : 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_InsufficientApprovalCannotSpendFundedBalance(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY - 1);
        amount = bound(amount, approved + 1, SUPPLY);
        token.approve(SPENDER, approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, approved, amount)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, amount);
        assertEq(token.allowance(address(this), SPENDER), approved);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_RoundTripPreservesExistingBalancesAndApprovals(
        uint256 aliceBalance,
        uint256 bobBalance,
        uint256 amount,
        uint256 approval
    ) public {
        aliceBalance = bound(aliceBalance, 0, SUPPLY);
        bobBalance = bound(bobBalance, 0, SUPPLY - aliceBalance);
        amount = bound(amount, 0, aliceBalance);
        token.transfer(ALICE, aliceBalance);
        token.transfer(BOB, bobBalance);
        vm.prank(ALICE);
        token.approve(SPENDER, approval);

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, amount));
        // Checking the intermediate state prevents two incorrect operations cancelling out.
        assertEq(token.balanceOf(ALICE), aliceBalance - amount);
        assertEq(token.balanceOf(BOB), bobBalance + amount);
        vm.prank(BOB);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), aliceBalance);
        assertEq(token.balanceOf(BOB), bobBalance);
        assertEq(token.balanceOf(address(this)), SUPPLY - aliceBalance - bobBalance);
        assertEq(token.allowance(ALICE, SPENDER), approval);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
