// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/PoolManager.sol";

contract DeployPoolManager is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address initialOwner = vm.addr(deployerPrivateKey);
        PoolManager poolManager = new PoolManager(initialOwner);

        vm.stopBroadcast();

        console.log("PoolManager deployed at:", address(poolManager));
        console.log("Owner:", initialOwner);


    }
}
