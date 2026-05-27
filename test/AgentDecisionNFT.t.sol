// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {AgentDecisionNFT} from "../src/AgentDecisionNFT.sol";

contract AgentDecisionNFTTest is Test {
    AgentDecisionNFT internal nft;
    address internal minter;

    function setUp() public {
        nft = new AgentDecisionNFT();
        minter = makeAddr("minter");
        nft.setMinter(minter);
    }

    function test_mintDecision_onlyMinter() public {
        vm.prank(minter);
        uint256 tokenId = nft.mintDecision(address(this), 5000, 10_000, bytes32(uint256(1)));
        assertEq(tokenId, 0);
        assertEq(nft.ownerOf(0), address(this));
    }

    function test_mintDecision_revertsForNonMinter() public {
        vm.prank(makeAddr("notMinter"));
        vm.expectRevert();
        nft.mintDecision(address(this), 5000, 10_000, bytes32(uint256(1)));
    }

    function test_tokenURI_returnsBase64Json() public {
        vm.prank(minter);
        nft.mintDecision(address(this), 9000, 10_000, bytes32(uint256(42)));

        string memory uri = nft.tokenURI(0);
        assertEq(_prefix(uri), "data:application/json;base64,");
    }

    function _prefix(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(29);
        for (uint256 i = 0; i < 29 && i < b.length; i++) {
            out[i] = b[i];
        }
        return string(out);
    }
}
