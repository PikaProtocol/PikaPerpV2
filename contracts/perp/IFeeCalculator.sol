// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFeeCalculator {
    function getFee(uint256 margin, uint256 leverage, address token, uint256 productFee, address account, address sender) external view returns (uint256);
    function getFeeRate(address token, uint256 productFee, address account, address sender) external view returns (uint256);
}
