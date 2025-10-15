// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SynledgerEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    constructor() {
        
    }

    enum EscrowStatus { Unfunded, Funded, Inprogress, Completed, Refunded, Disputed, Resolved }
    enum MilestoneStatus { Pending, Approved, PartialRelease, Released, Canceled }

    struct Milestone {
        uint256 amount;
        uint256 balanceToRelease;
        uint256 amountReleased;
        MilestoneStatus status;
        uint64 createdAt;
        uint64 approvedAt;
        uint64 releasedAt;
        string meta;
    }

    struct Escrow {
        address client;
        address freelancer;
        address token;  // ERC-20 address (USDC/USDT)
        uint256 totalAmount;
        uint256 fundedAmount;
        uint256 releasedAmount;
        uint256 createdAt;
        EscrowStatus status;
        bool cancellable;   // this has to be checked before work starts
        Milestone[] milestones;
    }

    Escrow[] private escrows;

    /* Events */
    event EscrowCreated(uint256 indexed escrowId, address indexed client, address indexed freelancer, address token, uint256 totalAmount);
    event Funded(uint256 indexed escrowId, uint256 amount);
    event MilestoneApproved(uint256 indexed escrowId, uint256 index, uint256 amount);
    event Released(uint256 indexed escrowId, uint256 amount, address to);
    event PartialRelease(uint256 indexed escrowId, uint256 amount, address to);
    event Refunded(uint256 indexed escrowId, uint256 amount, address to);
    event Disputed(uint256 indexed escrowId, address raisedBy);
    event Resolved(uint256 indexed escrowId, address winner, uint256 amountReleased);

    function createEscrow(
        address _freelancer,
        address _token,
        uint256 _totalAmount,
        uint256[] calldata _milestones,
        bool _cancellable
    ) external returns (uint256 escrowId) {
        if(_totalAmount == 0) {
            revert("total amount must not be zero");
        }

        uint256 milestoneTotalAmount = 0;
        Milestone[] memory tempMilestones = new Milestone[](_milestones.length);
        for(uint256 i = 0; i < _milestones.length; i++) {
            uint256 amt = _milestones[i];
            milestoneTotalAmount += amt;
            tempMilestones[i] = Milestone({
                amount: amt,
                balanceToRelease: 0,
                amountReleased: 0,
                status: MilestoneStatus.Pending,
                createdAt: uint64(block.timestamp),
                approvedAt: 0,
                releasedAt: 0,
                meta: ""
            });
        }

        if(milestoneTotalAmount != _totalAmount) {
            revert("Total milestone amount must equal totalAmount");
        }

        // create new
        escrows.push();

        uint256 newEscrowId = escrows.length - 1;
        Escrow storage newEscrow = escrows[newEscrowId];

        // Assign fields one by one
        newEscrow.client = msg.sender;  // this is the person who created the contract
        newEscrow.freelancer = _freelancer;
        newEscrow.token = _token;
        newEscrow.totalAmount = _totalAmount;
        newEscrow.fundedAmount = 0;
        newEscrow.createdAt = block.timestamp;
        newEscrow.status = EscrowStatus.Unfunded;
        newEscrow.cancellable = _cancellable;

        // Manually copy milestones from memory to storage
        for (uint256 i = 0; i < tempMilestones.length; i++) {
            newEscrow.milestones.push(tempMilestones[i]);
        }

        emit EscrowCreated(newEscrowId, msg.sender, _freelancer, _token, _totalAmount);

        return newEscrowId;
    }

    function fund(uint256 id, uint256 amount) external {
        require(id < escrows.length, "Invalid escrow ID");

        Escrow storage e = escrows[id];
        require(msg.sender == e.client, "Only client");
        require(amount > 0, "Amount must greater than zero");

        // transfer from the CLIENT to this CONTRACT ADDRESS
        // require(IERC20(e.token).transferFrom(msg.sender, address(this), amount), "Failed to transfer");
        IERC20(e.token).safeTransferFrom(msg.sender, address(this), amount);

        e.fundedAmount += amount;

        if(e.fundedAmount < e.totalAmount) {
            e.status = EscrowStatus.Inprogress;
        } else {
            e.status = EscrowStatus.Funded;
        }

        emit Funded(id, amount);
    }

    function approveMilestone(uint256 id, uint256 mIndex) external {
        require(id < escrows.length, "Invalid escrow ID");
        Escrow storage e = escrows[id];
        require(msg.sender == e.client, "Only client");
        Milestone storage m = e.milestones[mIndex];
        require(m.status == MilestoneStatus.Pending, "Already handled");
        m.status = MilestoneStatus.Approved;
        m.approvedAt = uint64(block.timestamp);

        emit MilestoneApproved(id, mIndex, m.amount);
    }

    /** 
     * NOTE: if the current milestone amount m.amount is greater than the remaining amount,
     * then it means that the milestone m will not be fully paid and hence, should not be marked as Released but partial release
     * and the balance tracked in a field called 'balanceToRelease' within the milestone
    */
    function releaseApproved(uint256 id) external nonReentrant {
        require(id < escrows.length, "Invalid escrow ID");

        Escrow storage e = escrows[id];
        require(e.status == EscrowStatus.Funded || e.status == EscrowStatus.Inprogress);

        uint256 approvedButUnreleased;
        for (uint256 i = 0; i < e.milestones.length; i++) {
            if (e.milestones[i].status == MilestoneStatus.Approved) {
                approvedButUnreleased += e.milestones[i].amount;
            } else if(e.milestones[i].status == MilestoneStatus.PartialRelease) {
                approvedButUnreleased += e.milestones[i].balanceToRelease;
            }
        }

        uint256 pendingToRelease = approvedButUnreleased;

        // ensure accounting sanity before subtraction
        require(e.fundedAmount >= e.releasedAmount, "Invalid escrow accounting");
        uint256 buffer = e.fundedAmount - e.releasedAmount;
        uint256 toPay = buffer < pendingToRelease ? buffer : pendingToRelease;

        require(toPay > 0, "Insufficient funds");

        uint256 remaining = toPay;
        bool isPartialRelease = false;
        for (uint256 i = 0; i < e.milestones.length && remaining > 0; i++) {
            Milestone storage m = e.milestones[i];
            uint256 used = 0;

            if (m.status == MilestoneStatus.Approved) {
                if(m.amount <= remaining) {
                    used = m.amount;
                    m.amountReleased += m.amount;
                    m.status = MilestoneStatus.Released;
                    m.releasedAt = uint64(block.timestamp);
                } else {
                    used = remaining;
                    m.status = MilestoneStatus.PartialRelease;
                    m.balanceToRelease = m.amount - remaining;
                    m.amountReleased += remaining;
                    isPartialRelease = true;
                }
            } else if(m.status == MilestoneStatus.PartialRelease) {
                if(m.balanceToRelease <= remaining) {
                    used = m.balanceToRelease;
                    m.status = MilestoneStatus.Released;
                    m.amountReleased += m.balanceToRelease;
                    m.balanceToRelease = 0;
                    m.releasedAt = uint64(block.timestamp);
                } else {
                    used = remaining;
                    m.balanceToRelease = m.balanceToRelease - remaining;
                    m.amountReleased += remaining;
                    isPartialRelease = true;
                }
            }

            remaining -= used;
        }

        e.releasedAmount += toPay;
        IERC20(e.token).safeTransfer(e.freelancer, toPay);

        if(isPartialRelease) {
            emit PartialRelease(id, toPay, e.freelancer);
        } else {
            emit Released(id, toPay, e.freelancer);
        }
    }

    function cancel(uint256 id) external nonReentrant {
        require(id < escrows.length, "Invalid escrow ID");

        Escrow storage e = escrows[id];
        require(msg.sender == e.client, "Only Client can cancel");
        require(e.cancellable, "Escrow is not cancellable");
        for (uint256 i = 0; i < e.milestones.length; i++) {
            require(e.milestones[i].status == MilestoneStatus.Pending, "All Milestones must be in pending state");
        }
        uint256 refundable = e.fundedAmount - e.releasedAmount;
        e.status = EscrowStatus.Canceled;
        
        if (refundable > 0) {
            emit Refunded(id, uint256 amount, e.client);
            IERC20(e.token).safeTransfer(e.client, refundable);
        }
    }

    function getEscrowById(uint256 index) public view returns (Escrow memory) {
        require(index < escrows.length, "Invalid escrow ID");
        return escrows[index];
    }

    function getEscrowsCount() public view returns (uint256) {
        return escrows.length;
    }
}
