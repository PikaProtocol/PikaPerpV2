pragma solidity ^0.8.0;

import "./IPikaPerp.sol";
import '../lib/PerpLib.sol';

contract PendingPnlManager {

    address public admin;
    address public pikaPerp;
    address public oracle;
    address public fundingManager;
    uint256 maxProductId;

    mapping (uint256 => int256) public pendingPnls;
    mapping (uint256 => uint256) public lastPrices;
    mapping (uint256 => int256) public lastFundings;

    event PendingPnlUpdated(
        uint256 productId,
        int256 pendingPnl,
        int256 pnlChange,
        uint256 price,
        int256 funding
    );
    event MaxProductIdSet(
        uint256 maxProductId
    );
    event FundingManagerSet(
        address fundingManager
    );
    event OracleSet(
        address oracle
    );
    event AdminSet(
        address admin
    );

    modifier onlyAdmin() {
        require(msg.sender == admin, "PendingPnlManager: !admin");
        _;
    }

    constructor(address _pikaPerp, address _oracle, address _fundingManager) public {
        pikaPerp = _pikaPerp;
        oracle = _oracle;
        fundingManager = _fundingManager;
        admin = msg.sender;
    }

    function updatePendingPnl(uint256 productId) external {
        require(msg.sender == pikaPerp, "!pikaPerp");
        (int256 pnlChange, uint256 price) = getPnlChangeAndPrice(productId);
        pendingPnls[productId] += pnlChange;
        lastPrices[productId] = price;
        int256 funding = IFundingManager(fundingManager).getFunding(productId);
        lastFundings[productId] = funding;
        emit PendingPnlUpdated(productId, pendingPnls[productId], pnlChange, price, funding);
    }

    function getPnlChangeAndPrice(uint256 productId) public view returns(int256,uint256) {
        (address productToken,,,,uint256 openInterestLong,uint256 openInterestShort,,) = IPikaPerp(pikaPerp).getProduct(productId);
        if (productToken == address(0)) {
            return (0, 0);
        }
        uint256 price = IOracle(oracle).getPrice(productToken);
        uint256 oiDelta = openInterestLong > openInterestShort ? openInterestLong - openInterestShort : openInterestShort - openInterestLong;
        // calculate the change of pnl for the oiDelta as position size
        return (PerpLib._getPnl(openInterestLong > openInterestShort, lastPrices[productId], 1e8, oiDelta, price) -
            PerpLib._getFundingPayment(fundingManager, openInterestLong > openInterestShort, productId, 1e8, oiDelta, lastFundings[productId]), price);
    }

    function getTotalPendingPnl() external view returns(int256) {
        int256 totalPendingPnl;
        for (uint256 i = 1; i <= maxProductId; i++) {
            (int256 pnlChange,) = getPnlChangeAndPrice(i);
            totalPendingPnl += (pendingPnls[i] + pnlChange);
        }
        return totalPendingPnl;
    }

    function setMaxProductId(uint256 _maxProductId) external onlyAdmin {
        maxProductId = _maxProductId;
        emit MaxProductIdSet(_maxProductId);
    }

    function setOracle(address _oracle) external onlyAdmin {
        oracle = _oracle;
        emit OracleSet(_oracle);
    }

    function setFundingManager(address _fundingManager) external onlyAdmin {
        fundingManager = _fundingManager;
        emit FundingManagerSet(_fundingManager);
    }

    function setAdmin(address _admin) external onlyAdmin {
        admin = _admin;
        emit AdminSet(_admin);
    }

}
