// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

interface IProphetCard {
    /// @notice Called by ProphetHook when a trader claims an epoch.
    function recordClaim(address trader, PoolId pid, uint64 epoch, int256 score, bool isEpochChampion) external;
}

/// @title Prophet Card — soulbound on-chain SVG NFT
/// @notice One lifetime card per address. Stats accumulate every successful claim.
///         The token URI is fully on-chain (SVG + JSON in data URI), à la uPEG.
contract ProphetCard is ERC721, AccessControl, IProphetCard {
    using Strings for uint256;
    using Strings for int256;

    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    struct Stats {
        uint64 totalClaims; // total claim() calls regardless of result
        uint64 wins; // claims with positive score
        uint64 championships; // epochs where trader was the top prophet
        uint64 currentStreak; // consecutive positive-score epochs
        uint64 bestStreak;
        int256 lifetimeScore;
        uint64 lastEpochClaimed;
        PoolId lastPool;
    }

    error SoulboundTransfer();

    mapping(address => uint256) public tokenIdOf;
    mapping(uint256 => Stats) public statsOf;
    uint256 public nextTokenId = 1;

    constructor() ERC721("Prophet Card", "PROPHET") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RECORDER_ROLE, msg.sender);
    }

    function setRecorder(address recorder) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(RECORDER_ROLE, recorder);
    }

    function recordClaim(address trader, PoolId pid, uint64 epoch, int256 score, bool isEpochChampion)
        external
        onlyRole(RECORDER_ROLE)
    {
        uint256 id = tokenIdOf[trader];
        if (id == 0) {
            id = nextTokenId++;
            tokenIdOf[trader] = id;
            _safeMint(trader, id);
        }
        Stats storage s = statsOf[id];
        s.totalClaims += 1;
        s.lastEpochClaimed = epoch;
        s.lastPool = pid;
        s.lifetimeScore += score;
        if (score > 0) {
            s.wins += 1;
            s.currentStreak += 1;
            if (s.currentStreak > s.bestStreak) s.bestStreak = s.currentStreak;
        } else {
            s.currentStreak = 0;
        }
        if (isEpochChampion) s.championships += 1;
    }

    // ----- soulbound: block transfers -----
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        // allow mints (from == 0) and burns (to == 0); block real transfers
        if (from != address(0) && to != address(0)) revert SoulboundTransfer();
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 id) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(id);
    }

    // ----- on-chain metadata -----
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        Stats memory s = statsOf[id];
        string memory svg = _renderSVG(s);
        string memory json = string.concat(
            '{"name":"Prophet Card #',
            id.toString(),
            '","description":"A soulbound record of on-chain prophecies. Earned through Prophet Hook.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","attributes":[',
            _attributes(s),
            "]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _attributes(Stats memory s) internal pure returns (string memory) {
        uint256 hitRate = s.totalClaims == 0 ? 0 : (uint256(s.wins) * 10000) / uint256(s.totalClaims);
        return string.concat(
            '{"trait_type":"Tier","value":"',
            _tierName(s),
            '"},',
            '{"trait_type":"Total Claims","value":',
            uint256(s.totalClaims).toString(),
            "},",
            '{"trait_type":"Wins","value":',
            uint256(s.wins).toString(),
            "},",
            '{"trait_type":"Championships","value":',
            uint256(s.championships).toString(),
            "},",
            '{"trait_type":"Hit Rate (bps)","value":',
            hitRate.toString(),
            "},",
            '{"trait_type":"Best Streak","value":',
            uint256(s.bestStreak).toString(),
            "}"
        );
    }

    function _tierName(Stats memory s) internal pure returns (string memory) {
        if (s.championships >= 5) return "The World";
        if (s.championships >= 1) return "The Star";
        if (s.wins >= 10) return "The Hierophant";
        if (s.wins >= 3) return "The Magician";
        return "The Fool";
    }

    function _renderSVG(Stats memory s) internal pure returns (string memory) {
        string memory tier = _tierName(s);
        uint256 hitRate = s.totalClaims == 0 ? 0 : (uint256(s.wins) * 10000) / uint256(s.totalClaims);
        string memory hitPct = string.concat(
            (hitRate / 100).toString(), ".", _pad2(hitRate % 100), "%"
        );
        (string memory bg1, string memory bg2, string memory accent) = _palette(s);
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 540" font-family="ui-monospace,monospace">',
            '<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="',
            bg1,
            '"/><stop offset="100%" stop-color="',
            bg2,
            '"/></linearGradient></defs>',
            '<rect width="360" height="540" rx="24" fill="url(#g)"/>',
            '<rect x="14" y="14" width="332" height="512" rx="18" fill="none" stroke="',
            accent,
            '" stroke-width="3"/>',
            '<text x="180" y="64" fill="',
            accent,
            '" font-size="14" text-anchor="middle" letter-spacing="6">PROPHET CARD</text>',
            '<text x="180" y="120" fill="#fff" font-size="34" text-anchor="middle" font-weight="700">',
            tier,
            "</text>",
            _renderStatsBlock(s, hitPct),
            "</svg>"
        );
    }

    function _renderStatsBlock(Stats memory s, string memory hitPct) internal pure returns (string memory) {
        return string.concat(
            '<g fill="#e8e8f0" font-size="16">',
            _kv(180, 220, "HIT RATE", hitPct),
            _kv(180, 260, "WINS", string.concat(uint256(s.wins).toString(), " / ", uint256(s.totalClaims).toString())),
            _kv(180, 300, "CHAMPIONSHIPS", uint256(s.championships).toString()),
            _kv(180, 340, "BEST STREAK", uint256(s.bestStreak).toString()),
            _kv(180, 380, "CURRENT STREAK", uint256(s.currentStreak).toString()),
            _kv(180, 420, "LIFETIME SCORE", _i2s(s.lifetimeScore)),
            "</g>",
            '<text x="180" y="500" fill="#9aa" font-size="11" text-anchor="middle">',
            "EVERY SWAP IS A PROPHECY",
            "</text>"
        );
    }

    function _kv(uint256 cx, uint256 cy, string memory k, string memory v) internal pure returns (string memory) {
        return string.concat(
            '<text x="',
            cx.toString(),
            '" y="',
            cy.toString(),
            '" text-anchor="middle" fill="#9aa" font-size="11" letter-spacing="2">',
            k,
            "</text>",
            '<text x="',
            cx.toString(),
            '" y="',
            (cy + 18).toString(),
            '" text-anchor="middle" fill="#fff" font-size="18" font-weight="600">',
            v,
            "</text>"
        );
    }

    function _palette(Stats memory s) internal pure returns (string memory bg1, string memory bg2, string memory accent) {
        if (s.championships >= 5) return ("#1a0033", "#000", "#ffe066"); // The World — gold
        if (s.championships >= 1) return ("#0a1a3a", "#000", "#7fd1ff"); // The Star — cyan
        if (s.wins >= 10) return ("#1a0a2e", "#000", "#c084fc"); // Hierophant — purple
        if (s.wins >= 3) return ("#0a1f1a", "#000", "#7ce29e"); // Magician — green
        return ("#1a1a22", "#0a0a10", "#9aa"); // Fool — neutral
    }

    function _pad2(uint256 n) internal pure returns (string memory) {
        if (n < 10) return string.concat("0", n.toString());
        return n.toString();
    }

    function _i2s(int256 v) internal pure returns (string memory) {
        if (v >= 0) return uint256(v).toString();
        return string.concat("-", uint256(-v).toString());
    }
}
