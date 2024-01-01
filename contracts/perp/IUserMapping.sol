pragma solidity ^0.8.0;

interface IUserMapping {
    function getOrCreateProxy(address user, address manager) external returns(address);
    function getProxyFromUser(address user) external view returns(address);
    function getUserFromProxy(address proxy) external view returns(address);
}
