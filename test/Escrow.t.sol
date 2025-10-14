// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {SynledgerEscrow} from "../src/Escrow.sol";

// Minimal ERC20 mock used for tests (top-level)
contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(uint256 initialSupply) {
        totalSupply = initialSupply;
        balanceOf[msg.sender] = initialSupply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract EscrowTest is Test {
    SynledgerEscrow escrow;
    address CLIENT = makeAddr('client');
    uint constant SEND_VALUE = 0.1 ether;   // 100000000000000000
    uint256 constant INITIAL_BALANCE = 10 ether;


    function setUp() public {
        escrow = new SynledgerEscrow();
    }

    function testCreateEscrow() public {
        address FREELANCER = makeAddr("freelancer");
        address TOKEN = makeAddr("token");
        uint256[] memory milestones = new uint256[](3);
        milestones[0] = 200 ether;
        milestones[1] = 300 ether;
        milestones[2] = 500 ether;
        
        uint256 escrowId = escrow.createEscrow(FREELANCER, TOKEN, 1000 ether, milestones, true);
        SynledgerEscrow.Escrow memory  escrowCreated = escrow.getEscrowById(escrowId);

        assertEq(escrowCreated.milestones.length, 3);
        assertEq(escrowCreated.totalAmount, 1000 ether);
        assertEq(escrow.getEscrowsCount(), 1);
    }

    function testFundEscrow() public {
        address FREELANCER = makeAddr("freelancer");
        
        // Deploy token as CLIENT so CLIENT initially owns the tokens
        vm.startPrank(CLIENT);
        MockERC20 token = new MockERC20(1_000_000 ether);

        uint256[] memory milestones = new uint256[](3);
        milestones[0] = 200 ether;
        milestones[1] = 300 ether;
        milestones[2] = 500 ether;

        uint256 escrowId = escrow.createEscrow(FREELANCER, address(token), 1000 ether, milestones, true);

        // approve and fund
        token.approve(address(escrow), 150 ether);
        escrow.fund(escrowId, 150 ether);
        vm.stopPrank();

        SynledgerEscrow.Escrow memory  escrowCreated = escrow.getEscrowById(escrowId);
        assertEq(escrowCreated.client, CLIENT);
        assertEq(escrowCreated.fundedAmount, 150 ether);
    }

    function testApproveMilestone() public {
        address FREELANCER = makeAddr("freelancer");
        address TOKEN = makeAddr("token");
        uint256[] memory milestones = new uint256[](3);
        milestones[0] = 200 ether;
        milestones[1] = 300 ether;
        milestones[2] = 500 ether;
        uint256 escrowId = escrow.createEscrow(FREELANCER, TOKEN, 1000 ether, milestones, true);

        escrow.approveMilestone(escrowId, 0);

        SynledgerEscrow.Escrow memory  escrowCreated = escrow.getEscrowById(escrowId);

        assertEq(escrowCreated.milestones.length, 3);
        assertEq(uint256(escrowCreated.milestones[0].status), uint256(SynledgerEscrow.MilestoneStatus.Approved));
        assertEq(uint256(escrowCreated.milestones[2].status), uint256(SynledgerEscrow.MilestoneStatus.Pending));
    }
}