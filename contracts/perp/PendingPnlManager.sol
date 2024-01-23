pragma solidity ^0.8.0;

import "./IPikaPerp.sol";
import '../lib/PerpLib.sol';
import "hardhat/console.sol";

contract PendingPnlManager {
    uint256 private constant FUNDING_BASE = 10**12;

    address public admin;
    address public pikaPerp;
    address public oracle;
    address public fundingManager;
    uint256 maxProductId;

    mapping (uint256 => int256) public pendingPnls;
    mapping (uint256 => uint256) public lastPrices;
    mapping (uint256 => int256) public lastFundings;
    mapping (uint256 => int256) public cumulativeFundingPayment;

    event PendingPnlUpdated(
        uint256 productId,
        int256 fundingPayment,
        int256 pnlChange,
        uint256 price,
        int256 funding
    );
    event RealizedPnlAndFundingSubtracted(
        uint256 productId,
        int256 realizedPnl,
        int256 fundingPayment
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
        IFundingManager(fundingManager).updateFunding(productId);
        int256 fundingPayment = 0;
        (address productToken,,,,uint256 openInterestLong,uint256 openInterestShort,,) = IPikaPerp(pikaPerp).getProduct(productId);
        uint256 oiDelta = openInterestLong > openInterestShort ? openInterestLong - openInterestShort : openInterestShort - openInterestLong;
        if (productToken != address(0)) {
            fundingPayment = PerpLib._getFundingPayment(fundingManager, openInterestLong > openInterestShort, productId, 1e8, oiDelta, lastFundings[productId]);
        }
        cumulativeFundingPayment[productId] += fundingPayment;

        (int256 pnlChange,,uint256 price) = getPnlFundingChangeAndPrice(productId);
//        console.log(uint256(pendingPnls[productId] > 0 ? pendingPnls[productId] : -1*pendingPnls[productId]), uint256(pnlChange > 0 ? pnlChange : -1*pnlChange));
        console.log("pending pnl before adding", pendingPnls[productId] > 0 ? uint256(pendingPnls[productId]) : uint256(-1 * pendingPnls[productId]));
        pendingPnls[productId] = pendingPnls[productId] + pnlChange;
        console.log("adding pnl change", pnlChange > 0 ? uint256(pnlChange) : uint256(-1 * pnlChange));
        console.log("new pending pnl after adding", pendingPnls[productId] > 0 ? uint256(pendingPnls[productId]) : uint256(-1 * pendingPnls[productId]));
        lastPrices[productId] = price;
        int256 funding = IFundingManager(fundingManager).getFunding(productId);
        lastFundings[productId] = funding;

        emit PendingPnlUpdated(productId, fundingPayment, pnlChange, price, funding);
    }

    function subtractRealizedPnlAndFunding(uint256 productId, int256 realizedPnl, int256 fundingPayment) external {
        require(msg.sender == pikaPerp, "!pikaPerp");
        console.log("productId", productId);
        console.log("pending pnl before subtracting", pendingPnls[productId] > 0 ? uint256(pendingPnls[productId]) : uint256(-1 * pendingPnls[productId]));
        pendingPnls[productId] = pendingPnls[productId] - realizedPnl;
        cumulativeFundingPayment[productId] -= fundingPayment;
        console.log("subgracting", realizedPnl > 0 ? uint256(realizedPnl) : uint256(-1 * realizedPnl));
        console.log("new pending pnl after subtracting", pendingPnls[productId] > 0 ? uint256(pendingPnls[productId]) : uint256(-1 * pendingPnls[productId]));
        emit RealizedPnlAndFundingSubtracted(productId, realizedPnl, fundingPayment);
    }

    function getPnlFundingChangeAndPrice(uint256 productId) public view returns(int256,int256,uint256) {
        (address productToken,,,,uint256 openInterestLong,uint256 openInterestShort,,) = IPikaPerp(pikaPerp).getProduct(productId);
        if (productToken == address(0)) {
            return (0, 0, 0);
        }
        uint256 oiDelta = openInterestLong > openInterestShort ? openInterestLong - openInterestShort : openInterestShort - openInterestLong;

        // calculate the change of pnl for the oiDelta as position size
        // funding payment = cumulative fundiPeng payment + current funding payment since the lastUpdateTime in FundingManager + pending funding payment
        return (PerpLib._getPnl(openInterestLong > openInterestShort, lastPrices[productId], 1e8, oiDelta, IOracle(oracle).getPrice(productToken)),
            getPendingFundingPayment(productId, oiDelta), IOracle(oracle).getPrice(productToken));
    }

    function getPendingFundingPayment(
        uint256 productId,
        uint256 positionSize
    ) public view returns(int256) {
        int256 fundingChange = IFundingManager(fundingManager).getFundingChange(productId);
        return fundingChange > 0 ? int256(positionSize) * fundingChange / int256(FUNDING_BASE) :
            int256(positionSize) * (-1 * fundingChange) / int256(FUNDING_BASE);
    }

    function getPendingPnl(uint256 productId) external view returns(int256) {
      return pendingPnls[productId];
    }

    function getTotalPendingPnl() external view returns(int256) {
        int256 totalPendingPnl;
        for (uint256 i = 1; i <= maxProductId; i++) {
            (int256 pnlChange,int256 fundingChange,) = getPnlFundingChangeAndPrice(i);
            totalPendingPnl += (pendingPnls[i] + pnlChange - fundingChange);
            console.log(uint256(pendingPnls[i] > 0 ? pendingPnls[i] : pendingPnls[i] * -1), uint256(pnlChange - fundingChange));
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
