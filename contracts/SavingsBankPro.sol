// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

/**
 * @title SavingsBankPro
 * @notice A more "real-world" evolution of a classroom CryptoBank:
 *         - Users create multiple time-locked savings plans (goals).
 *         - Deposits are capped per user.
 *         - Withdrawals before unlock time incur a penalty sent to treasury.
 *         - Includes nonReentrant + pause + owner admin controls.
 *
 *         This is a realistic "on-chain savings account" primitive.
 */

// -------------------------
// Minimal Security Modules
// -------------------------

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status == _NOT_ENTERED, "REENTRANCY");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

abstract contract Pausable {
    bool private _paused;

    event Paused(address account);
    event Unpaused(address account);

    modifier whenNotPaused() {
        require(!_paused, "PAUSED");
        _;
    }

    modifier whenPaused() {
        require(_paused, "NOT_PAUSED");
        _;
    }

    function paused() public view returns (bool) {
        return _paused;
    }

    function _pause() internal whenNotPaused {
        _paused = true;
        emit Paused(msg.sender);
    }

    function _unpause() internal whenPaused {
        _paused = false;
        emit Unpaused(msg.sender);
    }
}

abstract contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == _owner, "NOT_OWNER");
        _;
    }

    constructor() {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_ADDR");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

// -------------------------
// Savings Bank
// -------------------------

contract SavingsBankPro is ReentrancyGuard, Pausable, Ownable {
    // --- Config ---
    uint256 public maxBalancePerUser;         // total cap across all plans per user
    uint256 public earlyWithdrawPenaltyBps;   // e.g., 300 = 3%
    address public treasury;                  // receives penalties

    // --- Accounting ---
    struct Plan {
        uint256 balance;
        uint64  unlockTime;
        bool    exists;
        string  label; // optional: "Rent", "Emergency", "Trip"
    }

    mapping(address => uint256) public planCount;
    mapping(address => mapping(uint256 => Plan)) public plans;
    mapping(address => uint256) public userTotalBalance;

    // --- Events ---
    event PlanCreated(address indexed user, uint256 indexed planId, uint64 unlockTime, string label);
    event PlanLabelUpdated(address indexed user, uint256 indexed planId, string newLabel);

    event Deposited(address indexed user, uint256 indexed planId, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed planId, uint256 amount, uint256 penalty);

    event MaxBalancePerUserUpdated(uint256 newMax);
    event PenaltyUpdated(uint256 newPenaltyBps);
    event TreasuryUpdated(address newTreasury);

    // --- Errors (gas + clarity) ---
    error ZeroAmount();
    error MaxBalanceReached();
    error InvalidPlan();
    error InvalidUnlockTime();
    error PenaltyTooHigh();
    error TransferFailed();

    constructor(
        uint256 maxBalancePerUser_,
        address treasury_,
        uint256 earlyWithdrawPenaltyBps_
    ) {
        if (treasury_ == address(0)) revert TransferFailed();
        if (earlyWithdrawPenaltyBps_ > 2000) revert PenaltyTooHigh(); // cap at 20%

        maxBalancePerUser = maxBalancePerUser_;
        treasury = treasury_;
        earlyWithdrawPenaltyBps = earlyWithdrawPenaltyBps_;
    }

    // -------------------------
    // User: Plans
    // -------------------------

    /**
     * @notice Create a new savings plan with a future unlock time.
     * @param unlockTime_ Unix timestamp when funds become penalty-free.
     * @param label_ Optional friendly label.
     */
    function createPlan(uint64 unlockTime_, string calldata label_)
        external
        whenNotPaused
        returns (uint256 planId)
    {
        if (unlockTime_ <= block.timestamp) revert InvalidUnlockTime();

        planId = planCount[msg.sender];
        planCount[msg.sender] = planId + 1;

        plans[msg.sender][planId] = Plan({
            balance: 0,
            unlockTime: unlockTime_,
            exists: true,
            label: label_
        });

        emit PlanCreated(msg.sender, planId, unlockTime_, label_);
    }

    function updatePlanLabel(uint256 planId_, string calldata newLabel_)
        external
        whenNotPaused
    {
        Plan storage p = plans[msg.sender][planId_];
        if (!p.exists) revert InvalidPlan();

        p.label = newLabel_;
        emit PlanLabelUpdated(msg.sender, planId_, newLabel_);
    }

    function getPlan(address user_, uint256 planId_)
        external
        view
        returns (uint256 balance, uint64 unlockTime, bool exists, string memory label)
    {
        Plan storage p = plans[user_][planId_];
        return (p.balance, p.unlockTime, p.exists, p.label);
    }

    // -------------------------
    // User: Deposit / Withdraw
    // -------------------------

    function depositToPlan(uint256 planId_)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (msg.value == 0) revert ZeroAmount();

        Plan storage p = plans[msg.sender][planId_];
        if (!p.exists) revert InvalidPlan();

        uint256 newTotal = userTotalBalance[msg.sender] + msg.value;
        if (newTotal > maxBalancePerUser) revert MaxBalanceReached();

        // Effects
        p.balance += msg.value;
        userTotalBalance[msg.sender] = newTotal;

        emit Deposited(msg.sender, planId_, msg.value);
    }

    /**
     * @notice Withdraw from a plan.
     *         If before unlockTime, a penalty is applied.
     */
    function withdrawFromPlan(uint256 planId_, uint256 amount_)
        external
        nonReentrant
        whenNotPaused
    {
        if (amount_ == 0) revert ZeroAmount();

        Plan storage p = plans[msg.sender][planId_];
        if (!p.exists) revert InvalidPlan();
        require(amount_ <= p.balance, "INSUFFICIENT_PLAN_BALANCE");

        uint256 penalty = 0;

        // Calculate penalty if early
        if (block.timestamp < p.unlockTime && earlyWithdrawPenaltyBps > 0) {
            penalty = (amount_ * earlyWithdrawPenaltyBps) / 10_000;
        }

        uint256 payout = amount_ - penalty;

        // Effects
        p.balance -= amount_;
        userTotalBalance[msg.sender] -= amount_;

        // Interactions
        if (penalty > 0) {
            (bool okT, ) = treasury.call{value: penalty}("");
            if (!okT) revert TransferFailed();
        }

        (bool okU, ) = msg.sender.call{value: payout}("");
        if (!okU) revert TransferFailed();

        emit Withdrawn(msg.sender, planId_, amount_, penalty);
    }

    // -------------------------
    // Owner: Risk / Ops
    // -------------------------

    function setMaxBalancePerUser(uint256 newMax_) external onlyOwner {
        maxBalancePerUser = newMax_;
        emit MaxBalancePerUserUpdated(newMax_);
    }

    function setEarlyWithdrawPenaltyBps(uint256 newBps_) external onlyOwner {
        if (newBps_ > 2000) revert PenaltyTooHigh(); // 20% cap
        earlyWithdrawPenaltyBps = newBps_;
        emit PenaltyUpdated(newBps_);
    }

    function setTreasury(address newTreasury_) external onlyOwner {
        require(newTreasury_ != address(0), "ZERO_ADDR");
        treasury = newTreasury_;
        emit TreasuryUpdated(newTreasury_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // We do not allow direct ETH transfers without plan accounting
    receive() external payable {
        revert("USE_depositToPlan");
    }
}
