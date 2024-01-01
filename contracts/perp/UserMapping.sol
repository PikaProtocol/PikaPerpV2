pragma solidity ^0.8.0;

import "./UserProxy.sol";

contract UserMapping {

    mapping(address => address) public userToProxyMapping;
    mapping(address => address) public proxyToUserMapping;
    mapping(address => bool) public isManager;
    address public admin;
    address public pikaPerp;

    event ProxySet(address proxyAddress, address userAddress);
    event ManagerSet(address manager, bool isActive);
    event AdminSet(address admin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "PositionManager: !admin");
        _;
    }

    constructor(address _pikaPerp) public {
        pikaPerp = _pikaPerp;
        admin = msg.sender;
    }

    function getUserFromProxy(address proxyAddress) external view returns(address) {
        return proxyToUserMapping[proxyAddress];
    }

    function getProxyFromUser(address userAddress) external view returns(address) {
        return userToProxyMapping[userAddress];
    }

    function getUsersFromProxies(address[] memory proxyAddresses) external view returns(address[] memory) {
        uint256 length = proxyAddresses.length;
        address[] memory userAddresses = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            userAddresses[i] = proxyToUserMapping[proxyAddresses[i]];
        }
        return userAddresses;
    }

    function getProxiesFromUsers(address[] memory userAddresses) external view returns(address[] memory) {
        uint256 length = userAddresses.length;
        address[] memory proxyAddresses = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            proxyAddresses[i] = userToProxyMapping[userAddresses[i]];
        }
        return proxyAddresses;
    }

    function _setProxyForUser(address proxyAddress, address userAddress) private {
        require(isManager[msg.sender], "!manager");
        userToProxyMapping[userAddress] = proxyAddress;
        proxyToUserMapping[proxyAddress] = userAddress;
        emit ProxySet(proxyAddress, userAddress);
    }

    function getOrCreateProxy(address user, address manager) external returns(address) {
        if (userToProxyMapping[user] == address(0)) {
            address proxyAddress = address(new UserProxy(pikaPerp, user, manager));
            _setProxyForUser(proxyAddress, user);
            return proxyAddress;
        }
        return userToProxyMapping[user];
    }

    function setManager(address _account, bool _isActive) external onlyAdmin {
        isManager[_account] = _isActive;
        emit ManagerSet(_account, _isActive);
    }

    function setAdmin(address _admin) external onlyAdmin {
        admin = _admin;
        emit AdminSet(admin);
    }
}
