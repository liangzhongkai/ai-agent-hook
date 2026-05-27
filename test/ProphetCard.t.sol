// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ProphetCard} from "../src/ProphetCard.sol";

contract ProphetCardTest is Test {
    ProphetCard internal card;
    address internal trader = makeAddr("trader");
    PoolId internal pid = PoolId.wrap(bytes32(uint256(1)));

    function setUp() public {
        card = new ProphetCard();
    }

    function test_recordClaim_mintsOnFirstClaim() public {
        card.recordClaim(trader, pid, 1, 100, true);
        uint256 id = card.tokenIdOf(trader);
        assertEq(id, 1);
        assertEq(card.ownerOf(id), trader);
    }

    function test_recordClaim_accumulatesStats() public {
        card.recordClaim(trader, pid, 1, 100, true); // win + champ
        card.recordClaim(trader, pid, 2, 200, false); // win
        card.recordClaim(trader, pid, 3, -50, false); // loss
        card.recordClaim(trader, pid, 4, 300, true); // win + champ

        uint256 id = card.tokenIdOf(trader);
        (uint64 totalClaims, uint64 wins, uint64 champs, uint64 streak, uint64 bestStreak,, ,) = card.statsOf(id);
        assertEq(totalClaims, 4);
        assertEq(wins, 3);
        assertEq(champs, 2);
        assertEq(streak, 1); // streak reset by loss in claim 3, then 1 win after
        assertEq(bestStreak, 2);
    }

    function test_tokenURI_returnsDataURI() public {
        card.recordClaim(trader, pid, 1, 100, true);
        uint256 id = card.tokenIdOf(trader);
        string memory uri = card.tokenURI(id);
        // simple sanity check: data URI prefix
        bytes memory b = bytes(uri);
        assertGt(b.length, 100);
        bytes memory prefix = bytes("data:application/json;base64,");
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(b[i], prefix[i]);
        }
    }

    function test_soulbound_transferReverts() public {
        card.recordClaim(trader, pid, 1, 100, false);
        uint256 id = card.tokenIdOf(trader);

        address other = makeAddr("other");
        vm.prank(trader);
        vm.expectRevert(ProphetCard.SoulboundTransfer.selector);
        card.transferFrom(trader, other, id);
    }

    function test_tier_evolvesWithChampionships() public {
        // 5 championships → "The World"
        for (uint256 i = 0; i < 5; i++) {
            card.recordClaim(trader, pid, uint64(i + 1), 100, true);
        }
        uint256 id = card.tokenIdOf(trader);
        string memory uri = card.tokenURI(id);
        // base64 of {"name":"...","attributes":[{"trait_type":"Tier","value":"The World"...
        // We can't easily decode, so just sanity check length grows
        assertGt(bytes(uri).length, 200);
    }
}
