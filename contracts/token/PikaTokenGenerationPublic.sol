pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import  "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title Pika token generation contract(adapted from Jones Dao token generation contract)
/// In the first 1 hour, only whitelisted address can participate with whitelisted amount.
/// Afterwards, any address can contribute any amount of ETH.
/// The final price of the both phases is decided by
/// (total ETH contributed for this phase / total Pika tokens for this phase)
contract PikaTokenGenerationPublic is ReentrancyGuard {
    using SafeMath for uint256;
    using Math for uint256;
    using SafeERC20 for IERC20;

    // Withdrawer
    address public owner;
    // Keeps track of ETH deposited
    uint256 public weiDeposited;
    // Time when the token sale starts
    uint256 public saleStart;
    // Time when the token sale is open to public
    uint256 public sale2Start;
    // Time when the token sale closes
    uint256 public saleClose;
    // Min price of the sale
    uint256 public minPrice;
    // Max cap on wei raised
    uint256 public maxDepositsTotal;
    // Pika Tokens allocated to this contract
    uint256 public pikaTokensAllocated;
    // Max ETH that can be deposited by tier 1 whitelist address for entire whitelist phase
    uint256 public whitelistMaxDeposit1;
    // Max ETH that can be deposited by tier 2 whitelist address for entire whitelist phase
    uint256 public whitelistMaxDeposit2;
    // Max ETH that can be deposited by tier 3 whitelist address for entire whitelist phase
    uint256 public whitelistMaxDeposit3;
    // Merkleroot of whitelisted addresses
    bytes32 public merkleRoot;
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
    event WithdrawEth(uint256 amount);
    event MaxDepositsTotalUpdated(uint256 maxDepositsTotal);

    /// @param _owner withdrawer
    /// @param _saleStart time when the token sale starts
    /// @param _saleClose time when the token sale closes
    /// @param _minPrice min price of the sale
    /// @param _maxDepositsTotal max cap on wei raised during public phase
    /// @param _pikaTokensAllocated Pika tokens allocated to this contract
    /// @param _whitelistMaxDeposits max deposit that can be done via the whitelist deposit fn for 3 tiers of whitelist addresses for entire whitelist phase
    /// @param _merkleRoot the merkle root of all the whitelisted addresses
    constructor(
        address _owner,
        uint256 _saleStart,
        uint256 _sale2Start,
        uint256 _saleClose,
        uint256 _minPrice,
        uint256 _maxDepositsTotal,
        uint256 _pikaTokensAllocated,
        uint256[] memory _whitelistMaxDeposits,
        bytes32 _merkleRoot
    ) {
        require(_owner != address(0), "invalid owner address");
        require(_saleStart <= _sale2Start, "invalid saleStart");
        require(_saleStart >= block.timestamp, "invalid saleStart");
        require(_saleClose > _saleStart2, "invalid saleClose");
        require(_minPrice > 0, "invalid minPrice");
        require(_maxDepositsTotal > 0, "invalid maxDepositsTotal");
        require(_pikaTokensAllocated > 0, "invalid pikaTokensAllocated");

        owner = _owner;
        saleStart = _saleStart;
        sale2Start = _sale2Start;
        saleClose = _saleClose;
        minPrice = _minPrice;
        maxDepositsTotal = _maxDepositsTotal;
        pikaTokensAllocated = _pikaTokensAllocated;
        whitelistMaxDeposit1 = _whitelistMaxDeposits[0];
        whitelistMaxDeposit2 = _whitelistMaxDeposits[1];
        whitelistMaxDeposit3 = _whitelistMaxDeposits[2];
        merkleRoot = _merkleRoot;
    }

    /// Deposit fallback
    /// @dev must be equivalent to deposit(address beneficiary)
    receive() external payable isEligibleSender nonReentrant {
        require(block.timestamp >= sale2Start, "public phase 2 hasn't started yet");
        address beneficiary = msg.sender;
        require(weiDeposited + msg.value <= maxDepositsTotal, "max deposit for public phase reached");
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

    /// Deposit
    /// @param beneficiary will be able to claim tokens after saleClose
    /// @dev must be equivalent to receive()
    function deposit(address beneficiary, string calldata referralCode, bytes32[] calldata merkleProof) public payable isEligibleSender nonReentrant {
        require(beneficiary != address(0), "invalid address");
        require(weiDeposited + msg.value <= maxDepositsTotal, "maximum deposits reached");
        require(saleStart <= block.timestamp, "sale hasn't started yet");
        require(block.timestamp <= saleClose, "sale has closed");

        if (block.timestamp < sale2Start) {
            // Verify the merkle proof.
            uint256 whitelistMaxDeposit = verifyAndGetTierAmount(beneficiary, merkleProof);
            require(msg.value <= depositableLeftWhitelist(beneficiary, whitelistMaxDeposit), "user whitelist allocation used up");
        }

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

    /// @dev Withdraws eth deposited into the contract. Only owner can call this.
    function withdraw() external {
        require(owner == msg.sender, "caller is not the owner");
        uint256 ethBalance = payable(address(this)).balance;
        (bool success, ) = msg.sender.call.value(ethBalance)("");
        require(success, "transfer failed.");

        emit WithdrawEth(ethBalance);
    }

    function getUnsoldPika() public view returns(uint256) {
        require(block.timestamp > saleClose, "sale has not ended");

        // amount of Pika tokens allocated to public sale
        uint256 pikaForPublic = pikaTokensAllocated;

        // total wei deposited during the public sale
        uint256 totalDepoPublic = weiDeposited;

        // the amount of Pika sold in public if it is sold at the whitelist price
        uint256 pikaSoldPublicAtWhitelistPrice = totalDepoPublic.mul(1e18).div(minPrice);

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
        // wei deposited during public sale by beneficiary
        uint256 userDepoPub = deposits[beneficiary];

        if (userDepoPub == 0) {
            return 0;
        }

        // amount of Pika tokens allocated to public sale
        uint256 pikaForPublic = pikaTokensAllocated;

        // total wei deposited during the public sale
        uint256 totalDepoPublic = weiDeposited;

        uint256 userClaimablePikaPublic = Math.min(pikaForPublic.mul(userDepoPub).div(totalDepoPublic),
            userDepoPub.mul(1e18).div(minPrice));

        return userClaimablePikaPublic;
    }

    /// View leftover depositable eth for whitelisted user
    /// @param beneficiary user address
    /// @param whitelistMaxDeposit max deposit amount for user address
    function depositableLeftWhitelist(address beneficiary, uint256 whitelistMaxDeposit) public view returns (uint256) {
        return whitelistMaxDeposit.sub(deposits[beneficiary]);
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
        if (block.timestamp <= saleStart) {
            return minPrice;
        }
        // amount of Pika tokens allocated to public sale
        uint256 pikaForPublic = pikaTokensAllocated;
        uint256 priceForPublic = weiDeposited.mul(1e18).div(pikaForPublic);
        return priceForPublic > minPrice ? priceForPublic : minPrice;
    }


    /// adjust max deposits amount total in case setMaxDepositsWhitelist is called or whitelist phase is not fully filled,
    /// to make sure the max token price does not change for public phase
    /// @param _maxDepositsTotal new max deposits total amount
    function setMaxDepositsTotal(uint256 _maxDepositsTotal) external onlyOwner {
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
