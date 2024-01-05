pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./IPikaPerp.sol";

contract UserProxy {

    using SafeERC20 for IERC20;

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

    function withdraw(address _token) external {
        IERC20(_token).safeTransfer(user, IERC20(_token).balanceOf(address(this)));}
}
