pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import  "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title Pika token generation contract(adapted from Jones Dao token generation contract)
/// Whitelist Phase 1: whitelist address can get Pika with fixed price with a maximum ETH size that is same for each whitelist addresses
/// Whitelist Phase 2: whitelist address can get Pika with fixed price with a remaining maximum ETH size allocated for each address(subtract amount in phase 1.1)
/// (example: whitelist address A has 3 eth allocation for whitelist phase, and for the first 30 mins,
/// each whitelist address can contribute 1 eth maximum, so A can contribute 1 eth in the first 30 mins, and 2 eth after 30 mins and before whitelist phase ends)
/// Public Phase: any address can contribute any amount of ETH. The final price of the phase is decided by
/// (total ETH contributed for this phase / total Pika tokens for this phase)
contract PikaTokenGeneration is ReentrancyGuard {
    using SafeMath for uint256;
    using Math for uint256;
    using SafeERC20 for IERC20;

    // Pika Token
    IERC20 public pika;
    // Withdrawer
    address public owner;
    // Keeps track of ETH deposited during whitelist phase
    uint256 public weiDepositedWhitelist;
    // Keeps track of ETH deposited
    uint256 public weiDeposited;
    // Time when the whitelist phase 1 starts for whitelisted address with limited cap
    uint256 public saleWhitelistStart;
    // Time when the whitelist phase 2 starts for whitelisted address with unlimited cap(still limited by individual cap)
    uint256 public saleWhitelist2Start;
    // Time when the token sale starts
    uint256 public saleStart;
    // Time when the token sale closes
    uint256 public saleClose;
    // Max cap on wei raised during whitelist
    uint256 public maxDepositsWhitelist;
    // Max cap on wei raised
    uint256 public maxDepositsTotal;
    // Pika Tokens allocated to this contract
    uint256 public pikaTokensAllocated;
    // Pika Tokens allocated to whitelist
    uint256 public pikaTokensAllocatedWhitelist;
    // Max deposit that can be done for each address before saleWhitelist2Start
    uint256 public whitelistDepositLimit;
    // Max ETH that can be deposited by tier 1 whitelist address for entire whitelist phase
    uint256 public whitelistMaxDeposit1;
    // Max ETH that can be deposited by tier 2 whitelist address for entire whitelist phase
    uint256 public whitelistMaxDeposit2;
    // Max ETH that can be deposited by tier 3 whitelist address for entire whitelist phase
    uint256 public whitelistMaxDeposit3;
    // Merkleroot of whitelisted addresses
    bytes32 public merkleRoot;
    // Amount each whitelisted user deposited
    mapping(address => uint256) public depositsWhitelist;
    // Amount each user deposited
    mapping(address => uint256) public deposits;

    event TokenDeposit(
        address indexed purchaser,
        address indexed beneficiary,
        bool indexed isWhitelistDeposit,
        uint256 value,
        uint256 time,
        string referralCode
    );
    event TokenClaim(
        address indexed claimer,
        address indexed beneficiary,
        uint256 amount
    );
    event EthRefundClaim(
        address indexed claimer,
        address indexed beneficiary,
        uint256 amount
    );
    event WithdrawEth(uint256 amount);
    event WithdrawPika(uint256 amount);
    event SaleStartUpdated(uint256 saleStart);
    event SaleWhitelist2StartUpdated(uint256 saleWhitelist2Start);
    event MaxDepositsWhitelistUpdated(uint256 maxDepositsWhitelist);
    event MaxDepositsTotalUpdated(uint256 maxDepositsTotal);

    /// @param _pika Pika
    /// @param _owner withdrawer
    /// @param _saleWhitelistStart time when the whitelist phase 1 starts for whitelisted addresses with limited cap
    /// @param _saleWhitelist2Start time when the whitelist phase 2 starts for whitelisted addresses with unlimited cap
    /// @param _saleStart time when the token sale starts
    /// @param _saleClose time when the token sale closes
    /// @param _maxDeposits max cap on wei raised during whitelist and max cap on wei raised
    /// @param _pikaTokensAllocated Pika tokens allocated to this contract
    /// @param _whitelistDepositLimit max deposit that can be done for each whitelist address before _saleWhitelist2Start
    /// @param _whitelistMaxDeposits max deposit that can be done via the whitelist deposit fn for 3 tiers of whitelist addresses for entire whitelist phase
    /// @param _merkleRoot the merkle root of all the whitelisted addresses
    constructor(
        address _pika,
        address _owner,
        uint256 _saleWhitelistStart,
        uint256 _saleWhitelist2Start,
        uint256 _saleStart,
        uint256 _saleClose,
        uint256[] memory _maxDeposits,
        uint256 _pikaTokensAllocated,
        uint256 _whitelistDepositLimit,
        uint256[] memory _whitelistMaxDeposits,
        bytes32 _merkleRoot
    ) {
        require(_owner != address(0), "invalid owner address");
        require(_pika != address(0), "invalid token address");
        require(_saleWhitelistStart <= _saleWhitelist2Start, "invalid saleWhitelistStart");
        require(_saleWhitelistStart >= block.timestamp, "invalid saleWhitelistStart");
        require(_saleStart > _saleWhitelist2Start, "invalid saleStart");
        require(_saleClose > _saleStart, "invalid saleClose");
        require(_maxDeposits[0] > 0, "invalid maxDepositsWhitelist");
        require(_maxDeposits[1] > 0, "invalid maxDepositsTotal");
        require(_pikaTokensAllocated > 0, "invalid pikaTokensAllocated");

        pika = IERC20(_pika);
        owner = _owner;
        saleWhitelistStart = _saleWhitelistStart;
        saleWhitelist2Start = _saleWhitelist2Start;
        saleStart = _saleStart;
        saleClose = _saleClose;
        maxDepositsWhitelist = _maxDeposits[0];
        maxDepositsTotal = _maxDeposits[1];
        pikaTokensAllocated = _pikaTokensAllocated;
        pikaTokensAllocatedWhitelist = pikaTokensAllocated.mul(50).div(190);
        whitelistDepositLimit = _whitelistDepositLimit;
        whitelistMaxDeposit1 = _whitelistMaxDeposits[0];
        whitelistMaxDeposit2 = _whitelistMaxDeposits[1];
        whitelistMaxDeposit3 = _whitelistMaxDeposits[2];
        merkleRoot = _merkleRoot;
    }

    /// Deposit fallback
    /// @dev must be equivalent to deposit(address beneficiary)
    receive() external payable isEligibleSender nonReentrant {
        address beneficiary = msg.sender;
        require(beneficiary != address(0), "invalid address");
        require(weiDeposited + msg.value <= maxDepositsTotal, "max deposit for public phase reached");
        require(saleStart <= block.timestamp, "sale hasn't started yet");
        require(block.timestamp <= saleClose, "sale has closed");

        deposits[beneficiary] = deposits[beneficiary].add(msg.value);
        require(deposits[beneficiary] <= 100 ether, "maximum deposits per address reached");
        weiDeposited = weiDeposited.add(msg.value);
        emit TokenDeposit(
            msg.sender,
            beneficiary,
            false,
            msg.value,
            block.timestamp,
            ""
        );
    }

    /// Deposit for whitelisted address
    /// @param beneficiary will be able to claim tokens after saleClose
    /// @param merkleProof the merkle proof
    function depositForWhitelistedAddress(
        address beneficiary,
        bytes32[] calldata merkleProof,
        string calldata referralCode
    ) external payable nonReentrant {
        require(beneficiary != address(0), "invalid address");
        require(beneficiary == msg.sender, "beneficiary not message sender");
        require(msg.value > 0, "must deposit greater than 0");
        require((weiDepositedWhitelist + msg.value) <= maxDepositsWhitelist, "maximum deposits for whitelist reached");
        require(saleWhitelistStart <= block.timestamp, "sale hasn't started yet");
        require(block.timestamp <= saleStart, "whitelist sale has closed");

        // Whitelist phase 1 only allows deposits up to whitelistDepositLimit
        if (block.timestamp < saleWhitelist2Start) {
            require(depositsWhitelist[beneficiary] + msg.value <= whitelistDepositLimit, "whitelist phase 1 deposit limit reached");
        }

        // Verify the merkle proof.
        uint256 whitelistMaxDeposit = verifyAndGetTierAmount(beneficiary, merkleProof);
        require(msg.value <= depositableLeftWhitelist(beneficiary, whitelistMaxDeposit), "user whitelist allocation used up");

        // Add user deposit to depositsWhitelist
        depositsWhitelist[beneficiary] = depositsWhitelist[beneficiary].add(
            msg.value
        );

        weiDepositedWhitelist = weiDepositedWhitelist.add(msg.value);
        weiDeposited = weiDeposited.add(msg.value);

        emit TokenDeposit(
            msg.sender,
            beneficiary,
            true,
            msg.value,
            block.timestamp,
            referralCode
        );
    }

    /// Deposit
    /// @param beneficiary will be able to claim tokens after saleClose
    /// @dev must be equivalent to receive()
    function deposit(address beneficiary, string calldata referralCode) public payable isEligibleSender nonReentrant {
        require(beneficiary != address(0), "invalid address");
        require(weiDeposited + msg.value <= maxDepositsTotal, "maximum deposits reached");
        require(saleStart <= block.timestamp, "sale hasn't started yet");
        require(block.timestamp <= saleClose, "sale has closed");

        deposits[beneficiary] = deposits[beneficiary].add(msg.value);
        require(deposits[beneficiary] <= 100 ether, "maximum deposits per address reached");
        weiDeposited = weiDeposited.add(msg.value);
        emit TokenDeposit(
            msg.sender,
            beneficiary,
            false,
            msg.value,
            block.timestamp,
            referralCode
        );
    }

    /// Claim
    /// @param beneficiary receives the tokens they claimed
    /// @dev claim calculation must be equivalent to claimAmount(address beneficiary)
    function claim(address beneficiary) external nonReentrant returns (uint256) {
        require(
            deposits[beneficiary] + depositsWhitelist[beneficiary] > 0,
            "no deposit"
        );
        require(block.timestamp > saleClose, "sale hasn't closed yet");

        // total Pika allocated * user share in the ETH deposited
        uint256 beneficiaryClaim = claimAmountPika(beneficiary);
        depositsWhitelist[beneficiary] = 0;
        deposits[beneficiary] = 0;

        pika.safeTransfer(beneficiary, beneficiaryClaim);

        emit TokenClaim(msg.sender, beneficiary, beneficiaryClaim);

        return beneficiaryClaim;
    }

    /// @dev Withdraws eth deposited into the contract. Only owner can call this.
    function withdraw() external {
        require(owner == msg.sender, "caller is not the owner");
        uint256 ethBalance = payable(address(this)).balance;
        payable(msg.sender).transfer(ethBalance);

        emit WithdrawEth(ethBalance);
    }

    /// @dev Withdraws unsold PIKA tokens(if any). Only owner can call this.
    function withdrawUnsoldPika() external {
        require(owner == msg.sender, "caller is not the owner");
        uint256 unsoldAmount = getUnsoldPika();
        pika.safeTransfer(owner, unsoldAmount);

        emit WithdrawPika(unsoldAmount);
    }

    function getUnsoldPika() public view returns(uint256) {
        require(block.timestamp > saleClose, "sale has not ended");
        // amount of Pika unsold during whitelist sale
        uint256 unsoldWlPika = pikaTokensAllocatedWhitelist
        .mul((maxDepositsWhitelist.sub(weiDepositedWhitelist)))
        .div(maxDepositsWhitelist);

        // amount of Pika tokens allocated to whitelist sale
        uint256 pikaForWl = pikaTokensAllocatedWhitelist.sub(unsoldWlPika);

        // amount of Pika tokens allocated to public sale
        uint256 pikaForPublic = pikaTokensAllocated.sub(pikaForWl);

        // total wei deposited during the public sale
        uint256 totalDepoPublic = weiDeposited.sub(weiDepositedWhitelist);

        // the amount of Pika sold in public if it is sold at the whitelist price
        uint256 pikaSoldPublicAtWhitelistPrice = pikaForWl.mul(totalDepoPublic).div(weiDepositedWhitelist);

        // if the amount is larger than pikaForPublic, it means the actual price in public phase is higher than
        // whitelist price and therefore all the PIKA tokens are sold out.
        if (pikaSoldPublicAtWhitelistPrice >= pikaForPublic) {
            return 0;
        }
        return pikaForPublic.sub(pikaSoldPublicAtWhitelistPrice);
    }

    /// View beneficiary's claimable token amount
    /// @param beneficiary address to view claimable token amount of
    function claimAmountPika(address beneficiary) public view returns (uint256) {
        // wei deposited during whitelist sale by beneficiary
        uint256 userDepoWl = depositsWhitelist[beneficiary];

        // wei deposited during public sale by beneficiary
        uint256 userDepoPub = deposits[beneficiary];

        if (userDepoPub.add(userDepoWl) == 0) {
            return 0;
        }

        // amount of Pika unsold during whitelist sale
        uint256 unsoldWlPika = pikaTokensAllocatedWhitelist
        .mul((maxDepositsWhitelist.sub(weiDepositedWhitelist)))
        .div(maxDepositsWhitelist);

        // amount of Pika tokens allocated to whitelist sale
        uint256 pikaForWl = pikaTokensAllocatedWhitelist.sub(unsoldWlPika);

        // amount of Pika tokens allocated to public sale
        uint256 pikaForPublic = pikaTokensAllocated.sub(pikaForWl);

        // total wei deposited during the public sale
        uint256 totalDepoPublic = weiDeposited.sub(weiDepositedWhitelist);

        uint256 userClaimablePika = 0;

        if (userDepoWl > 0) {
            userClaimablePika = pikaForWl.mul(userDepoWl).div(weiDepositedWhitelist);
        }
        if (userDepoPub > 0) {
            uint256 userClaimablePikaPublic = Math.min(pikaForPublic.mul(userDepoPub).div(totalDepoPublic),
                pikaForWl.mul(userDepoPub).div(weiDepositedWhitelist));
            userClaimablePika = userClaimablePika.add(userClaimablePikaPublic);
        }
        return userClaimablePika;
    }

    /// View leftover depositable eth for whitelisted user
    /// @param beneficiary user address
    /// @param whitelistMaxDeposit max deposit amount for user address
    function depositableLeftWhitelist(address beneficiary, uint256 whitelistMaxDeposit) public view returns (uint256) {
        return whitelistMaxDeposit.sub(depositsWhitelist[beneficiary]);
    }

    function verifyAndGetTierAmount(address beneficiary, bytes32[] calldata merkleProof) public returns(uint256) {
        bytes32 node1 = keccak256(abi.encodePacked(beneficiary, whitelistMaxDeposit1));
        if (MerkleProof.verify(merkleProof, merkleRoot, node1)) {
            return whitelistMaxDeposit1;
        }
        bytes32 node2 = keccak256(abi.encodePacked(beneficiary, whitelistMaxDeposit2));
        if (MerkleProof.verify(merkleProof, merkleRoot, node2)) {
            return whitelistMaxDeposit2;
        }
        bytes32 node3 = keccak256(abi.encodePacked(beneficiary, whitelistMaxDeposit3));
        if (MerkleProof.verify(merkleProof, merkleRoot, node3)) {
            return whitelistMaxDeposit3;
        }
        revert("invalid proof");
    }

    function getCurrentPikaPrice() external view returns(uint256) {
        uint256 minPrice = maxDepositsWhitelist.mul(1e18).div(pikaTokensAllocatedWhitelist);
        if (block.timestamp <= saleStart) {
            return minPrice;
        }
        // amount of Pika unsold during whitelist sale
        uint256 unsoldWlPika = pikaTokensAllocatedWhitelist
        .mul((maxDepositsWhitelist.sub(weiDepositedWhitelist)))
        .div(maxDepositsWhitelist);
        // amount of Pika tokens allocated to whitelist sale
        uint256 pikaForWl = pikaTokensAllocatedWhitelist.sub(unsoldWlPika);

        // amount of Pika tokens allocated to public sale
        uint256 pikaForPublic = pikaTokensAllocated.sub(pikaForWl);
        uint256 priceForPublic = (weiDeposited.sub(weiDepositedWhitelist)).mul(1e18).div(pikaForPublic);
        return priceForPublic > minPrice ? priceForPublic : minPrice;
    }

    /// option to increase whitelist phase 2 sale start time
    /// @param _saleWhitelist2Start new whitelist phase 2 start time
    function setSaleWhitelist2Start(uint256 _saleWhitelist2Start) external onlyOwner {
        // can only set new whitelist phase 2 start before sale starts
        require(block.timestamp < saleStart, "already started");
        // can only set new whitelist phase 2 start before the current public phase start, and after the current whitelist phase 2 start
        require(_saleWhitelist2Start < saleStart && _saleWhitelist2Start > saleWhitelist2Start, "invalid sale start time");
        saleWhitelist2Start = _saleWhitelist2Start;
        emit SaleWhitelist2StartUpdated(_saleWhitelist2Start);
    }

    /// adjust whitelist allocation in case whitelist is fully filled before whitelist phase 1 ends
    /// @param _maxDepositsWhitelist new whitelist allocation
    function setMaxDepositsWhitelist(uint256 _maxDepositsWhitelist) external onlyOwner {
        require(block.timestamp < saleWhitelist2Start, "whitelist phase 1 already ended");
        require(_maxDepositsWhitelist > maxDepositsWhitelist && _maxDepositsWhitelist <= maxDepositsTotal, "invalid max whitelist amount");
        pikaTokensAllocatedWhitelist = pikaTokensAllocatedWhitelist * _maxDepositsWhitelist / maxDepositsWhitelist;
        require(pikaTokensAllocatedWhitelist <= pikaTokensAllocated, "invalid max whitelist pika allocation amount");
        maxDepositsWhitelist = _maxDepositsWhitelist;
        emit MaxDepositsWhitelistUpdated(_maxDepositsWhitelist);
    }

    /// adjust max deposits amount total in case setMaxDepositsWhitelist is called or whitelist phase is not fully filled,
    /// to make sure the max token price does not change for public phase
    /// @param _maxDepositsTotal new max deposits total amount
    function setMaxDepositsTotal(uint256 _maxDepositsTotal) external onlyOwner {
        require(_maxDepositsTotal < maxDepositsTotal + maxDepositsWhitelist && _maxDepositsTotal > maxDepositsWhitelist, "invalid max deposit amount");
        maxDepositsTotal = _maxDepositsTotal;
        emit MaxDepositsTotalUpdated(_maxDepositsTotal);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    // Modifier is eligible sender modifier
    modifier isEligibleSender() {
        require(msg.sender == tx.origin, "Contracts are not allowed to snipe the sale");
        _;
    }
}
