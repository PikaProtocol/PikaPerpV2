pragma solidity ^0.8.0;

interface IPendingPnlManager {
    function updatePendingPnl(uint256 productId) external;
    function getTotalPendingPnl() external returns(int256);
}
