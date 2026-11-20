// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pactboard, IAgentID} from "../src/Pactboard.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Tether", "USDT") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract MockAgentID is IAgentID {
    mapping(address => string) public h;

    function set(address a, string calldata handle) external {
        h[a] = handle;
    }

    function balanceOf(address o) external view returns (uint256) {
        return bytes(h[o]).length > 0 ? 1 : 0;
    }

    function handleOf(address o) external view returns (string memory) {
        return h[o];
    }
}


contract PactboardTest is Test {
    MockUSDT usdt;
    MockAgentID aid;
    Pactboard pb;

    address poster = address(0xA11CE);
    address worker = address(0xB0B);
    address worker2 = address(0xB0B2);
    address nobody = address(0xDEAD);

    uint256 constant R = 10 ether; // 10 USDT (18 decimals)

    function setUp() public {
        usdt = new MockUSDT();
        aid = new MockAgentID();
        pb = new Pactboard(IERC20(address(usdt)), IAgentID(address(aid)));
        aid.set(poster, "alice");
        aid.set(worker, "bob");
        aid.set(worker2, "carol");
        usdt.mint(poster, 1000 ether);
        usdt.mint(nobody, 1000 ether);
        vm.prank(poster);
        usdt.approve(address(pb), type(uint256).max); // test convenience only
    }

    function _post() internal returns (uint256 id) {
        vm.prank(poster);
        id = pb.postJob("Research token X", "ipfs://details", R, uint64(block.timestamp + 2 days));
    }

    function _toSubmitted() internal returns (uint256 id) {
        id = _post();
        vm.prank(worker);
        pb.acceptJob(id);
        vm.prank(worker);
        pb.submitResult(id, "ipfs://result");
    }

    // ------------------------------------------------------------- posting
    function test_post_escrows_and_records() public {
        uint256 id = _post();
        assertEq(id, 1);
        assertEq(usdt.balanceOf(address(pb)), R);
        assertEq(usdt.balanceOf(poster), 1000 ether - R);
        Pactboard.Job memory j = pb.getJob(id);
        assertEq(j.poster, poster);
        assertEq(uint8(j.status), uint8(Pactboard.Status.Open));
        (uint32 posted,,,,,,) = pb.reputation(poster);
        assertEq(posted, 1);
    }

    function test_post_requires_agent_id() public {
        vm.startPrank(nobody);
        usdt.approve(address(pb), R);
        vm.expectRevert(Pactboard.NotAgent.selector);
        pb.postJob("t", "d", R, uint64(block.timestamp + 2 days));
        vm.stopPrank();
    }

    function test_post_needs_approval_exact_amount() public {
        vm.startPrank(worker);
        usdt.mint(worker, 100 ether);
        usdt.approve(address(pb), R - 1);
        vm.expectRevert();
        pb.postJob("t", "d", R, uint64(block.timestamp + 2 days));
        usdt.approve(address(pb), R);
        pb.postJob("t", "d", R, uint64(block.timestamp + 2 days));
        assertEq(usdt.allowance(worker, address(pb)), 0);
        vm.stopPrank();
    }

    function test_post_input_validation() public {
        vm.startPrank(poster);
        uint64 ok = uint64(block.timestamp + 2 days);
        vm.expectRevert(Pactboard.BadInput.selector);
        pb.postJob("t", "d", 0, ok);
        vm.expectRevert(Pactboard.BadInput.selector);
        pb.postJob("", "d", R, ok);
        vm.expectRevert(Pactboard.BadInput.selector);
        pb.postJob("t", "d", R, uint64(block.timestamp + 10 minutes));
        vm.expectRevert(Pactboard.BadInput.selector);
        pb.postJob("t", "d", R, uint64(block.timestamp + 91 days));
        vm.expectRevert(Pactboard.BadInput.selector);
        pb.postJob(string(new bytes(101)), "d", R, ok);
        vm.expectRevert(Pactboard.BadInput.selector);
        pb.postJob("t", string(new bytes(1025)), R, ok);
        vm.stopPrank();
    }

    function test_cancel_open_job() public {
        uint256 id = _post();
        vm.prank(worker);
        vm.expectRevert(Pactboard.NotPoster.selector);
        pb.cancelJob(id);
        vm.prank(poster);
        pb.cancelJob(id);
        assertEq(usdt.balanceOf(poster), 1000 ether);
        assertEq(usdt.balanceOf(address(pb)), 0);
        vm.prank(poster);
        vm.expectRevert(Pactboard.BadStatus.selector);
        pb.cancelJob(id);
    }

    // ------------------------------------------------------------ accepting
    function test_accept_rules() public {
        uint256 id = _post();
        vm.prank(nobody);
        vm.expectRevert(Pactboard.NotAgent.selector);
        pb.acceptJob(id);
        vm.prank(poster);
        vm.expectRevert(Pactboard.OwnJob.selector);
        pb.acceptJob(id);
        vm.prank(worker);
        pb.acceptJob(id);
        vm.prank(worker2);
        vm.expectRevert(Pactboard.BadStatus.selector);
        pb.acceptJob(id);
        // poster can no longer cancel
        vm.prank(poster);
        vm.expectRevert(Pactboard.BadStatus.selector);
        pb.cancelJob(id);
    }

    function test_accept_after_deadline_reverts() public {
        uint256 id = _post();
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(worker);
        vm.expectRevert(Pactboard.TooLate.selector);
        pb.acceptJob(id);
    }

    function test_resign_reopens() public {
        uint256 id = _post();
        vm.prank(worker);
        pb.acceptJob(id);
        vm.prank(worker2);
        vm.expectRevert(Pactboard.NotWorker.selector);
        pb.resign(id);
        vm.prank(worker);
        pb.resign(id);
        vm.prank(worker2);
        pb.acceptJob(id);
        assertEq(pb.getJob(id).worker, worker2);
        (,,,, uint32 failed,,) = pb.reputation(worker);
        assertEq(failed, 0);
    }

    // ------------------------------------------------------------ submitting
    function test_submit_rules() public {
        uint256 id = _post();
        vm.prank(worker);
        vm.expectRevert(Pactboard.BadStatus.selector);
        pb.submitResult(id, "x");
        vm.prank(worker);
        pb.acceptJob(id);
        vm.prank(worker2);
        vm.expectRevert(Pactboard.NotWorker.selector);
        pb.submitResult(id, "x");
        vm.prank(worker);
        vm.expectRevert(Pactboard.BadInput.selector);
        pb.submitResult(id, "");
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(worker);
        vm.expectRevert(Pactboard.TooLate.selector);
        pb.submitResult(id, "late");
    }

    // ------------------------------------------------------------ approve
    function test_approve_pays_worker_and_updates_reputation() public {
        uint256 id = _toSubmitted();
        vm.prank(worker);
        vm.expectRevert(Pactboard.NotPoster.selector);
        pb.approve(id);
        vm.prank(poster);
        pb.approve(id);
        assertEq(usdt.balanceOf(worker), R);
        assertEq(usdt.balanceOf(address(pb)), 0);
        (uint32 posted, uint32 paid, uint32 rej,,, , uint128 spent) = pb.reputation(poster);
        assertEq(posted, 1);
        assertEq(paid, 1);
        assertEq(rej, 0);
        assertEq(spent, R);
        (,,, uint32 completed, uint32 failed, uint128 earned,) = pb.reputation(worker);
        assertEq(completed, 1);
        assertEq(failed, 0);
        assertEq(earned, R);
        // cannot pay twice
        vm.prank(poster);
        vm.expectRevert(Pactboard.BadStatus.selector);
        pb.approve(id);
    }

    // ------------------------------------------------------------ reject
    function test_reject_refunds_poster_and_marks_worker_failed() public {
        uint256 id = _toSubmitted();
        vm.prank(poster);
        pb.reject(id);
        assertEq(usdt.balanceOf(poster), 1000 ether);
        assertEq(usdt.balanceOf(worker), 0);
        (,,, uint32 completed, uint32 failed,,) = pb.reputation(worker);
        assertEq(completed, 0);
        assertEq(failed, 1);
        (,, uint32 rej,,,,) = pb.reputation(poster);
        assertEq(rej, 1);
        vm.prank(worker);
        vm.expectRevert(Pactboard.BadStatus.selector);
        pb.claim(id);
    }

    function test_reject_after_window_reverts_and_worker_claims() public {
        uint256 id = _toSubmitted();
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(poster);
        vm.expectRevert(Pactboard.TooLate.selector);
        pb.reject(id);
        vm.prank(worker);
        pb.claim(id);
        assertEq(usdt.balanceOf(worker), R);
    }

    // ------------------------------------------------------------ claim
    function test_claim_too_early_and_only_worker() public {
        uint256 id = _toSubmitted();
        vm.prank(worker);
        vm.expectRevert(Pactboard.TooEarly.selector);
        pb.claim(id);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(poster);
        vm.expectRevert(Pactboard.NotWorker.selector);
        pb.claim(id);
        vm.prank(worker);
        pb.claim(id);
        (,,, uint32 completed,, uint128 earned,) = pb.reputation(worker);
        assertEq(completed, 1);
        assertEq(earned, R);
        (, uint32 paid,,,,,) = pb.reputation(poster);
        assertEq(paid, 1);
        vm.prank(worker);
        vm.expectRevert(Pactboard.BadStatus.selector);
        pb.claim(id);
    }

    function test_poster_can_still_approve_after_window_if_unclaimed() public {
        uint256 id = _toSubmitted();
        vm.warp(block.timestamp + 10 days);
        vm.prank(poster);
        pb.approve(id);
        assertEq(usdt.balanceOf(worker), R);
    }

    // ------------------------------------------------------------ reclaim
    function test_reclaim_open_after_deadline() public {
        uint256 id = _post();
        vm.prank(poster);
        vm.expectRevert(Pactboard.TooEarly.selector);
        pb.reclaim(id);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(worker);
        vm.expectRevert(Pactboard.NotPoster.selector);
        pb.reclaim(id);
        vm.prank(poster);
        pb.reclaim(id);
        assertEq(usdt.balanceOf(poster), 1000 ether);
    }

    function test_reclaim_accepted_not_delivered_marks_worker_failed() public {
        uint256 id = _post();
        vm.prank(worker);
        pb.acceptJob(id);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(poster);
        pb.reclaim(id);
        assertEq(usdt.balanceOf(poster), 1000 ether);
        (,,,, uint32 failed,,) = pb.reputation(worker);
        assertEq(failed, 1);
    }

    function test_cannot_reclaim_submitted() public {
        uint256 id = _toSubmitted();
        vm.warp(block.timestamp + 5 days);
        vm.prank(poster);
        vm.expectRevert(Pactboard.BadStatus.selector);
        pb.reclaim(id);
    }

    // ------------------------------------------------------------ views
    function test_getJobs_paging_newest_first() public {
        for (uint256 i = 0; i < 5; i++) {
            _post();
        }
        (uint256[] memory ids, Pactboard.Job[] memory js) = pb.getJobs(0, 3);
        assertEq(ids.length, 3);
        assertEq(ids[0], 5);
        assertEq(ids[2], 3);
        assertEq(js[1].poster, poster);
        (ids,) = pb.getJobs(3, 10);
        assertEq(ids.length, 2);
        assertEq(ids[1], 1);
        (ids,) = pb.getJobs(9, 10);
        assertEq(ids.length, 0);
    }

    function test_no_owner_surface() public view {
        // the contract exposes no privileged functions: only immutables
        assertEq(address(pb.usdt()), address(usdt));
        assertEq(address(pb.agentId()), address(aid));
    }

    // ------------------------------------------------------------ fuzz: funds conservation
    function testFuzz_escrow_conservation(uint96 reward, uint8 path) public {
        reward = uint96(bound(reward, 1, 1000 ether));
        vm.prank(poster);
        uint256 id = pb.postJob("t", "d", reward, uint64(block.timestamp + 2 days));
        vm.prank(worker);
        pb.acceptJob(id);
        vm.prank(worker);
        pb.submitResult(id, "r");
        path = path % 3;
        if (path == 0) {
            vm.prank(poster);
            pb.approve(id);
        } else if (path == 1) {
            vm.prank(poster);
            pb.reject(id);
        } else {
            vm.warp(block.timestamp + 3 days + 1);
            vm.prank(worker);
            pb.claim(id);
        }
        assertEq(usdt.balanceOf(address(pb)), 0);
        assertEq(usdt.balanceOf(poster) + usdt.balanceOf(worker), 1000 ether);
    }
}
