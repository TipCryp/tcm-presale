// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80  roundId,
        int256  answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80  answeredInRound
    );
    function decimals() external view returns (uint8);
}

// -----------------------------------------------
// SAFE ERC20
// -----------------------------------------------

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}

// -----------------------------------------------
// REENTRANCY GUARD
// -----------------------------------------------

abstract contract ReentrancyGuard {
    uint256 private _status = 1;
    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }
}

// -----------------------------------------------
// MAIN CONTRACT
// -----------------------------------------------

contract TCMPresale is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -- CORE --
    address public owner;
    address public pendingOwner;
    address public treasury;
    address public pendingTreasury;

    IERC20 public tcmToken;
    IERC20 public usdtToken;
    IERC20 public usdcToken;
    AggregatorV3Interface public ethFeed;
    uint8 public ethFeedDecimals;


    uint256 public tgeTimestamp;
    bool public claimEnabled;
    bool public salePaused;

    // -- GLOBAL SAFETY CAP --
    uint256 public constant MAX_PRESALE_SUPPLY = 100_000_000 * 1e18;

    // -- STABLECOIN SCALE --
    // Both USDT and USDC use 6 decimals on Base/Polygon.
    // 1 token = 1_000_000 raw units = 100 cents.
    // Enforced in constructor via decimals() check.
    uint256 private constant STABLE_SCALE = 1e4;

    // -- STAGES --
    // Arrays sized 6 to support 1-based indexing (index 0 unused).
    uint8 public currentStage = 1;

    uint256[6] public stagePrice;
    uint256[6] public stageCap;
    uint256[6] public stageSold;
    uint256[6] public stageClose;
    uint256[6] public stageBonus;

    // -- LIMITS --
    uint256 public constant MAX_WALLET = 1_500_000; // $15,000 in cents

    mapping(address => uint256) public invested;
    mapping(address => uint256) public allocation;
    mapping(address => bool)    public claimed;
    uint256 public totalAllocated;

    // -- EVENTS --
    event Purchased(address indexed user, uint256 usdCents, uint256 tokens, uint8 stage);
    event Claimed(address indexed user, uint256 tokens);
    event OwnershipTransferInitiated(address indexed current, address indexed pending);
    event OwnershipTransferred(address indexed previous, address indexed newOwner);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event StageAdvanced(uint8 indexed fromStage, uint8 indexed toStage, uint256 rolledOver);
    event ClaimEnabled();
    event SalePaused(bool paused);
    event TreasuryUpdated(address indexed previous, address indexed newTreasury);
    event TreasuryTransferInitiated(address indexed current, address indexed pending);
    event TgeTimestampUpdated(uint256 previous, uint256 updated);

    // -----------------------------------------------
    // CONSTRUCTOR
    // -----------------------------------------------

    constructor(
        address _tcm,
        address _usdt,
        address _usdc,
        address _owner,
        address _treasury,
        address _feed
    ) {
        require(_tcm           != address(0), "ZERO_TCM");
        require(_usdt          != address(0), "ZERO_USDT");
        require(_usdc          != address(0), "ZERO_USDC");
        require(_owner         != address(0), "ZERO_OWNER");
        require(_treasury      != address(0), "ZERO_TREASURY");
        require(_feed          != address(0), "ZERO_FEED");
        owner    = _owner;
        treasury = _treasury;

        tcmToken  = IERC20(_tcm);
        usdtToken = IERC20(_usdt);
        usdcToken = IERC20(_usdc);

        // Use low-level calls for decimals() so a non-standard token doesn't
        // brick deployment - fall back to 6 if the call fails (safe for USDT/USDC on Base).
        {
            (bool ok, bytes memory data) = _usdt.staticcall(abi.encodeWithSignature("decimals()"));
            uint8 d = (ok && data.length == 32) ? abi.decode(data, (uint8)) : 6;
            require(d == 6, "USDT_DECIMALS");
        }
        {
            (bool ok, bytes memory data) = _usdc.staticcall(abi.encodeWithSignature("decimals()"));
            uint8 d = (ok && data.length == 32) ? abi.decode(data, (uint8)) : 6;
            require(d == 6, "USDC_DECIMALS");
        }

        // Feed decimals - also via low-level call, default to 8 (standard Chainlink)
        {
            (bool ok, bytes memory data) = _feed.staticcall(abi.encodeWithSignature("decimals()"));
            ethFeedDecimals = (ok && data.length == 32) ? abi.decode(data, (uint8)) : 8;
        }
        require(ethFeedDecimals >= 2,  "FEED_DECIMALS_TOO_LOW");
        require(ethFeedDecimals <= 18, "FEED_DECIMALS_TOO_HIGH");

        ethFeed = AggregatorV3Interface(_feed);

        tgeTimestamp = 1798761600;

        // Prices in cents-per-token (e.g. 5 = $0.05)
        stagePrice[1] = 5;
        stagePrice[2] = 10;
        stagePrice[3] = 15;
        stagePrice[4] = 25;

        stageCap[1] = 15_000_000 * 1e18;
        stageCap[2] = 20_000_000 * 1e18;
        stageCap[3] = 25_000_000 * 1e18;
        stageCap[4] = 40_000_000 * 1e18;

        stageClose[1] = 1783209600; // Jul 05 2026
        stageClose[2] = 1788134400; // Aug 31 2026
        stageClose[3] = 1793404800; // Oct 31 2026
        stageClose[4] = 1798761600; // Jan 01 2027

        stageBonus[1] = 15;
        stageBonus[2] = 10;
        stageBonus[3] = 5;
        stageBonus[4] = 0;
    }

    // -----------------------------------------------
    // OWNERSHIP
    // -----------------------------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "OWNER");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_ADDR");
        require(newOwner != owner,      "ALREADY_OWNER");
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "NOT_PENDING");
        emit OwnershipTransferred(owner, pendingOwner);
        owner        = pendingOwner;
        pendingOwner = address(0);
    }

    // -----------------------------------------------
    // ETH PRICE ORACLE
    // -----------------------------------------------

    function _ethPrice() internal view returns (uint256) {
        (uint80 roundId, int256 a,, uint256 updatedAt, uint80 answeredInRound) =
            ethFeed.latestRoundData();
        require(a > 0,                               "BAD_PRICE");
        require(updatedAt <= block.timestamp,        "BAD_TIME");
        require(block.timestamp - updatedAt < 90000, "STALE_PRICE");
        require(answeredInRound >= roundId,           "STALE_ROUND");
        return uint256(a);
    }

    // -----------------------------------------------
    // STAGE ADVANCEMENT
    // -----------------------------------------------

    /// @dev Rolls unsold supply from expired stages into the next stage.
    ///      Called internally before every purchase. Also callable externally
    ///      so the frontend can trigger a UI update when a deadline passes.
    function _advanceExpiredStages() internal {
        while (currentStage < 4 && block.timestamp > stageClose[currentStage]) {
            uint256 unsold = stageCap[currentStage] - stageSold[currentStage];
            if (unsold > 0) {
                stageCap[currentStage + 1] += unsold;
            }
            emit StageAdvanced(currentStage, currentStage + 1, unsold);
            currentStage++;
        }
    }

    /// @notice Permissionless - advances expired stages and rolls over unsold supply.
    function stageAdvance() external {
        uint8 before = currentStage;
        _advanceExpiredStages();
        require(currentStage > before, "NOTHING_TO_ADVANCE");
    }

    // -----------------------------------------------
    // PURCHASE CORE
    // -----------------------------------------------

    function _buy(address user, uint256 usdCents) internal {
        require(!salePaused, "PAUSED");

        _advanceExpiredStages();

        require(currentStage >= 1 && currentStage <= 4, "NO_ACTIVE_STAGE");
        require(block.timestamp <= stageClose[currentStage], "STAGE_CLOSED");
        require(invested[user] + usdCents <= MAX_WALLET, "WALLET_LIMIT");

        uint256 base  = (usdCents * 1e19) / stagePrice[currentStage];
        uint256 bonus = (base * stageBonus[currentStage]) / 100;
        uint256 total = base + bonus;
        require(total > 0, "ZERO_TOKENS");

        require(stageSold[currentStage] + total <= stageCap[currentStage], "STAGE_FULL");
        require(totalAllocated + total <= MAX_PRESALE_SUPPLY, "PRESALE_SUPPLY_EXCEEDED");
        require(
            tcmToken.balanceOf(address(this)) >= totalAllocated + total,
            "INSUFFICIENT_TCM_BACKING"
        );

        allocation[user]        += total;
        totalAllocated          += total;
        stageSold[currentStage] += total;
        invested[user]          += usdCents;

        // Capture stage before potential cap-advance for accurate event reporting
        uint8 purchasedInStage = currentStage;

        if (stageSold[currentStage] >= stageCap[currentStage] && currentStage < 4) {
            currentStage++;
        }

        emit Purchased(user, usdCents, total, purchasedInStage);
    }

    // -----------------------------------------------
    // INVEST FUNCTIONS
    // -----------------------------------------------

    /// @param minTokensOut Slippage guard. Pass 0 to skip.
    function investETH(uint256 minTokensOut) external payable nonReentrant {
        require(msg.value > 0, "ZERO_ETH");

        // Normalize to cents regardless of feed decimal count:
        // usdCents = (wei * rawPrice) / (1e18 * 10^(feedDecimals - 2))
        uint256 divisor  = 1e18 * (10 ** (uint256(ethFeedDecimals) - 2));
        uint256 usdCents = (msg.value * _ethPrice()) / divisor;
        require(usdCents >= 2500, "MIN_$25");

        if (minTokensOut > 0) {
            uint256 base    = (usdCents * 1e19) / stagePrice[currentStage];
            uint256 preview = base + (base * stageBonus[currentStage]) / 100;
            require(preview >= minTokensOut, "SLIPPAGE");
        }

        _buy(msg.sender, usdCents);
    }

    function investUSDT(uint256 amt) external nonReentrant {
        require(amt > 0, "ZERO_AMT");
        uint256 usdCents = amt / STABLE_SCALE;
        require(usdCents >= 2500, "MIN_$25");
        usdtToken.safeTransferFrom(msg.sender, address(this), amt);
        _buy(msg.sender, usdCents);
    }

    function investUSDC(uint256 amt) external nonReentrant {
        require(amt > 0, "ZERO_AMT");
        uint256 usdCents = amt / STABLE_SCALE;
        require(usdCents >= 2500, "MIN_$25");
        usdcToken.safeTransferFrom(msg.sender, address(this), amt);
        _buy(msg.sender, usdCents);
    }

    // -----------------------------------------------
    // CLAIM
    // -----------------------------------------------

    function claim() external nonReentrant {
        require(claimEnabled,                    "NOT_ENABLED");
        require(block.timestamp >= tgeTimestamp, "TGE_NOT_READY");
        require(!claimed[msg.sender],            "ALREADY_CLAIMED");
        require(allocation[msg.sender] > 0,      "NO_ALLOCATION");

        uint256 amt = allocation[msg.sender];
        claimed[msg.sender]    = true;
        allocation[msg.sender] = 0;

        tcmToken.safeTransfer(msg.sender, amt);
        emit Claimed(msg.sender, amt);
    }

    // -----------------------------------------------
    // TREASURY WITHDRAWALS
    // -----------------------------------------------

    function withdrawETH() external nonReentrant {
        require(msg.sender == treasury, "TREASURY_ONLY");
        uint256 bal = address(this).balance;
        require(bal > 0, "NO_ETH");
        (bool ok,) = treasury.call{value: bal}("");
        require(ok, "ETH_TRANSFER_FAILED");
        emit Withdrawn(address(0), treasury, bal);
    }

    function withdrawUSDT() external nonReentrant {
        require(msg.sender == treasury, "TREASURY_ONLY");
        uint256 bal = usdtToken.balanceOf(address(this));
        require(bal > 0, "NO_USDT");
        usdtToken.safeTransfer(treasury, bal);
        emit Withdrawn(address(usdtToken), treasury, bal);
    }

    function withdrawUSDC() external nonReentrant {
        require(msg.sender == treasury, "TREASURY_ONLY");
        uint256 bal = usdcToken.balanceOf(address(this));
        require(bal > 0, "NO_USDC");
        usdcToken.safeTransfer(treasury, bal);
        emit Withdrawn(address(usdcToken), treasury, bal);
    }

    // -----------------------------------------------
    // OWNER FUNCTIONS
    // -----------------------------------------------

    function enableClaim() external onlyOwner {
        require(!claimEnabled, "ALREADY_ENABLED");
        require(
            tcmToken.balanceOf(address(this)) >= totalAllocated,
            "NOT_FUNDED"
        );
        claimEnabled = true;
        emit ClaimEnabled();
    }

    function setPause(bool p) external onlyOwner {
        require(salePaused != p, "NO_CHANGE");
        salePaused = p;
        emit SalePaused(p);
    }

    function initiateTreasuryTransfer(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "ZERO_ADDR");
        require(newTreasury != treasury,   "NO_CHANGE");
        pendingTreasury = newTreasury;
        emit TreasuryTransferInitiated(treasury, newTreasury);
    }

    function acceptTreasury() external {
        require(msg.sender == pendingTreasury, "NOT_PENDING_TREASURY");
        address previous = treasury;
        treasury = pendingTreasury;
        pendingTreasury = address(0);
        emit TreasuryUpdated(previous, treasury);
    }

    function setTgeTimestamp(uint256 ts) external onlyOwner {
        require(!claimEnabled,        "CLAIM_LIVE");
        require(ts > block.timestamp, "MUST_BE_FUTURE");
        uint256 previous = tgeTimestamp;
        tgeTimestamp = ts;
        emit TgeTimestampUpdated(previous, ts);
    }

    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "ZERO_ADDR");
        require(token != address(tcmToken) || totalAllocated == 0, "TCM_ALLOCATED");
        IERC20(token).safeTransfer(owner, amount);
    }

    // -----------------------------------------------
    // VIEW HELPERS
    // -----------------------------------------------

    function currentStageInfo() external view returns (
        uint8   stage,
        uint256 price,
        uint256 cap,
        uint256 sold,
        uint256 bonus,
        uint256 closes
    ) {
        stage  = currentStage;
        price  = stagePrice[currentStage];
        cap    = stageCap[currentStage];
        sold   = stageSold[currentStage];
        bonus  = stageBonus[currentStage];
        closes = stageClose[currentStage];
    }

    function userInfo(address user) external view returns (
        uint256 investedCents,
        uint256 tokenAllocation,
        bool    hasClaimed
    ) {
        require(user != address(0), "ZERO_ADDR");
        investedCents   = invested[user];
        tokenAllocation = allocation[user];
        hasClaimed      = claimed[user];
    }

    receive() external payable {
        revert("USE_investETH");
    }
}
