// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMD} from "../src/IMD.sol";

/// @dev Test-only factory; intentionally has no access control.
contract TokenFactoryProbe {
    function deploy(bytes32 salt) external returns (IMD) {
        return new IMD{salt: salt}();
    }

    function move(IMD token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract RejectingRecipient {
    fallback() external {
        revert("recipient must not be called");
    }
}

contract IMDTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5EED);

    IMD internal token;

    function setUp() public {
        token = new IMD();
    }

    function test_MetadataAndInitialSupply() public view {
        assertEq(token.name(), "Infinite Money Dopamine");
        assertEq(token.symbol(), "IMD");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(address(this), SPENDER), 0);
    }

    function test_ConstructorEmitsMintToImmediateDeployer() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), ALICE, SUPPLY);
        vm.prank(ALICE);
        IMD deployed = new IMD();

        assertEq(deployed.balanceOf(ALICE), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    function test_Create2FactoryReceivesEntireSupply() public {
        TokenFactoryProbe factory = new TokenFactoryProbe();
        bytes32 salt = keccak256("IMD launch");
        bytes32 digest =
            keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(type(IMD).creationCode)));
        address predicted = address(uint160(uint256(digest)));

        vm.prank(ALICE);
        IMD deployed = factory.deploy(salt);

        assertEq(address(deployed), predicted);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(ALICE), 0);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    function test_ExactFactoryDistributionClaimsAndPoolTransfers() public {
        TokenFactoryProbe factory = new TokenFactoryProbe();
        IMD launched = factory.deploy(bytes32(uint256(1)));
        address distributor = address(0xD157);
        address pool = address(0x9001);
        uint256 swarm = SUPPLY / 10;
        uint256 poolShare = SUPPLY * 6 / 10; // Illustrative test allocation, not a deployment parameter.
        uint256 remainder = SUPPLY - swarm - poolShare;

        assertTrue(factory.move(launched, distributor, swarm));
        assertTrue(factory.move(launched, pool, poolShare));
        assertTrue(factory.move(launched, ALICE, remainder));
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(pool), poolShare);
        assertEq(launched.balanceOf(ALICE), remainder);

        vm.prank(distributor);
        assertTrue(launched.transfer(BOB, swarm));
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.balanceOf(BOB), swarm);

        // Exercise ERC-20 movement in both pool directions; this is not a DEX simulation.
        vm.prank(pool);
        assertTrue(launched.transfer(SPENDER, 42 ether));
        assertEq(launched.balanceOf(SPENDER), 42 ether);
        vm.prank(SPENDER);
        assertTrue(launched.transfer(pool, 42 ether));
        assertEq(launched.balanceOf(SPENDER), 0);
        assertEq(launched.balanceOf(pool), poolShare);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_TransferEmitsEventAndMovesExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), ALICE, 100 ether);
        assertTrue(token.transfer(ALICE, 100 ether));

        assertEq(token.balanceOf(address(this)), SUPPLY - 100 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferEntireBalance() public {
        assertTrue(token.transfer(ALICE, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(ALICE), SUPPLY);
    }

    function test_ZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_SelfTransferPreservesBalance() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferToContractDoesNotCallRecipient() public {
        RejectingRecipient recipient = new RejectingRecipient();
        assertTrue(token.transfer(address(recipient), 1 ether));
        assertEq(token.balanceOf(address(recipient)), 1 ether);
    }

    function test_ApproveEmitsEventAndCanBeReplacedOrRevoked() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), SPENDER, 100 ether);
        assertTrue(token.approve(SPENDER, 100 ether));
        assertEq(token.allowance(address(this), SPENDER), 100 ether);
        assertTrue(token.approve(SPENDER, 7 ether));
        assertEq(token.allowance(address(this), SPENDER), 7 ether);
        assertTrue(token.approve(SPENDER, 0));
        assertEq(token.allowance(address(this), SPENDER), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_TransferFromEmitsEventAndConsumesAllowance() public {
        token.approve(SPENDER, 100 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), ALICE, 40 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 40 ether));

        assertEq(token.allowance(address(this), SPENDER), 60 ether);
        assertEq(token.balanceOf(ALICE), 40 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 40 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), BOB, 60 ether));
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(BOB), 60 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_InfiniteAllowanceIsNotDecremented() public {
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, SUPPLY));
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_TransferFromToSelfConsumesAllowanceWithoutChangingBalance() public {
        token.approve(SPENDER, 1 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), address(this), 1 ether));
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_ZeroTransferFromNeedsNoAllowance() public {
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_RevertWhenTransferringToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenApprovingZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_RevertWhenAllowanceIsInsufficient() public {
        token.approve(SPENDER, 5 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 5 ether, 6 ether)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 6 ether);
        assertEq(token.allowance(address(this), SPENDER), 5 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_RevertWhenApprovedTransferExceedsBalanceRestoresAllowance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 10 ether));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 10 ether);
        assertEq(token.allowance(ALICE, SPENDER), 10 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_RevertWhenApprovedTransferGoesToZeroRestoresAllowance() public {
        token.approve(SPENDER, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 10 ether);
        assertEq(token.allowance(address(this), SPENDER), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_DeployerCannotSpendHolderFundsWithoutApproval() public {
        token.transfer(ALICE, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_NoMintBurnUpgradeOrHolderControlEntrypoints() public {
        token.transfer(ALICE, 100 ether);
        string[24] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "burn(uint256)",
            "_mint(address,uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, uint256(1));
            (bool deployerSucceeded,) = address(token).call(data);
            assertFalse(deployerSucceeded, signatures[i]);
            vm.prank(BOB);
            (bool strangerSucceeded,) = address(token).call(data);
            assertFalse(strangerSucceeded, signatures[i]);
            assertEq(token.balanceOf(ALICE), 100 ether);
            assertEq(token.balanceOf(BOB), 0);
            assertEq(token.totalSupply(), SUPPLY);
        }
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100 ether));
        assertEq(token.balanceOf(BOB), 100 ether);
    }

    function test_RuntimeContainsNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode");
        }
    }

    function test_RevertWhenSendingNativeCurrency() public {
        vm.deal(address(this), 1 ether);
        (bool succeeded,) = address(token).call{value: 1 ether}("");
        assertFalse(succeeded);
        assertEq(address(token).balance, 0);
    }

    function testFuzz_TransfersConserveSupply(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0) && recipient != address(this));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount)
        );
        token.transfer(ALICE, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_AllowanceAccounting(uint256 approved, uint256 amount) public {
        amount = bound(amount, 0, approved < SUPPLY ? approved : SUPPLY);
        assertTrue(token.approve(SPENDER, approved));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, amount));
        assertEq(token.allowance(address(this), SPENDER), approved == type(uint256).max ? approved : approved - amount);
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
