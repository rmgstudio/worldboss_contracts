// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract GameFactory {
    event DeployGame(address game);

    function deployGame(
        address logic_,
        address owner_,
        address admin_,
        address system_wallet_,
        address proxyAdmin_,
        address fee_wallet_,
        address token_,
        uint256 fee_
    ) public {
        bytes memory _data = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,uint256)",
            owner_,
            admin_,
            system_wallet_,
            fee_wallet_,
            token_,
            fee_
        );

        TransparentUpgradeableProxy game = new TransparentUpgradeableProxy(
            logic_,
            proxyAdmin_,
            _data
        );
        emit DeployGame(address(game));
    }
}
