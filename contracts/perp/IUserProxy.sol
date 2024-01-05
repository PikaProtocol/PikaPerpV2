// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IUserProxy {
    function setAccountManager(address _manager, bool _isActive) external;
    function withdraw(address _token) external;
}
