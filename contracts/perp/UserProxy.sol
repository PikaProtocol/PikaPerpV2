pragma solidity ^0.8.0;

import "./IPikaPerp.sol";

contract UserProxy {

    address public immutable pikaPerp;
    address public immutable user;

    constructor(address _pikaPerp, address _user, address _manager) public {
        pikaPerp = _pikaPerp;
        user = _user;
        IPikaPerp(_pikaPerp).setAccountManager(_manager, true);
    }

    function setAccountManager(address _manager, bool _isActive) external {
        require(msg.sender == user, "!user");
        IPikaPerp(pikaPerp).setAccountManager(_manager, _isActive);
    }
}
