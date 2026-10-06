// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMD} from "../src/IMD.sol";

/// @dev Closed set of holders, allowing the invariant to sum every possible balance.
contract IMDHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    IMD public immutable token;
    address[4] public actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor() {
        token = new IMD();
        assertEq(token.totalSupply(), SUPPLY);
        // Fund every actor so random sequences start with useful transfers.
        for (uint256 i; i < actors.length; ++i) {
            assertTrue(token.transfer(actors[i], SUPPLY / actors.length));
            expectedBalance[actors[i]] = SUPPLY / actors.length;
        }
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[from]);

        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];

        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function spend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        amount = bound(amount, 0, allowance < balance ? allowance : balance);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowance != type(uint256).max) {
            expectedAllowance[owner][spender] -= amount;
        }
    }

    function moveAll(uint256 fromSeed, uint256 toSeed) external {
        move(fromSeed, toSeed, expectedBalance[actors[fromSeed % actors.length]]);
    }

    function approveBoundary(uint256 ownerSeed, uint256 spenderSeed, uint256 edgeSeed) external {
        uint256[5] memory edges = [uint256(0), 1, SUPPLY, type(uint256).max - 1, type(uint256).max];
        approve(ownerSeed, spenderSeed, edges[edgeSeed % edges.length]);
    }

    // Expected failures are consumed here; unexpected handler reverts fail the campaign.
    // Ghost balances and allowances stay unchanged on rejected token calls, so the
    // invariants also check that each failure rolls back all observable accounting.
    function rejectTransfer(uint256 fromSeed, uint256 toSeed, uint256 amount, bool zeroRecipient) external {
        address from = actors[fromSeed % actors.length];
        address to = zeroRecipient ? address(0) : actors[toSeed % actors.length];
        uint256 balance = expectedBalance[from];
        if (zeroRecipient) {
            amount = bound(amount, 0, balance);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        } else {
            amount = bound(amount, balance + 1, type(uint256).max);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
            );
        }
        vm.prank(from);
        token.transfer(to, amount);
    }

    function revokeAndRejectSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        approve(ownerSeed, spenderSeed, 0);
        amount = bound(amount, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
    }

    function rejectSpendOverBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = expectedBalance[owner];
        uint256 amount = balance + 1;
        // A finite approval makes rollback of the attempted allowance deduction observable.
        approve(ownerSeed, spenderSeed, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
    }

    function rejectSpendToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        amount = bound(amount, 0, allowance < balance ? allowance : balance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
    }

    function rejectApproveZero(uint256 ownerSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract IMDInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    IMDHandler internal handler;
    IMD internal token;

    function setUp() public {
        handler = new IMDHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = IMDHandler.move.selector;
        selectors[1] = IMDHandler.approve.selector;
        selectors[2] = IMDHandler.spend.selector;
        selectors[3] = IMDHandler.moveAll.selector;
        selectors[4] = IMDHandler.approveBoundary.selector;
        selectors[5] = IMDHandler.rejectTransfer.selector;
        selectors[6] = IMDHandler.revokeAndRejectSpend.selector;
        selectors[7] = IMDHandler.rejectSpendOverBalance.selector;
        selectors[8] = IMDHandler.rejectSpendToZero.selector;
        selectors[9] = IMDHandler.rejectApproveZero.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_SupplyAndBalancesRemainConserved() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor));
            sum += balance;
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function invariant_AllowancesMatchAuthorizations() public view {
        for (uint256 i; i < 4; ++i) {
            assertEq(token.allowance(handler.actors(i), address(0)), 0);
            for (uint256 j; j < 4; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }
}
