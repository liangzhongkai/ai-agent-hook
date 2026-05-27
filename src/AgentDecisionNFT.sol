// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

interface IAgentDecisionNFT {
    function mintDecision(
        address to,
        uint256 riskScore,
        uint256 swapVolume,
        bytes32 poolId
    ) external returns (uint256 tokenId);
}

/// @title AgentDecisionNFT
/// @notice Mints on-chain SVG NFTs recording AI sentiment at each swap
contract AgentDecisionNFT is ERC721, AccessControl, IAgentDecisionNFT {
    using Strings for uint256;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    uint256 private _nextTokenId;

    struct DecisionMetadata {
        uint256 riskScore;
        uint256 swapVolume;
        bytes32 poolId;
        uint256 timestamp;
    }

    mapping(uint256 => DecisionMetadata) public decisions;

    event DecisionMinted(
        address indexed to,
        uint256 indexed tokenId,
        uint256 riskScore,
        uint256 swapVolume,
        bytes32 poolId
    );

    constructor() ERC721("AI Agent Decision", "AIDEC") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    function setMinter(address minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, minter);
    }

    function mintDecision(
        address to,
        uint256 riskScore,
        uint256 swapVolume,
        bytes32 poolId
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _mint(to, tokenId);

        decisions[tokenId] = DecisionMetadata({
            riskScore: riskScore,
            swapVolume: swapVolume,
            poolId: poolId,
            timestamp: block.timestamp
        });

        emit DecisionMinted(to, tokenId, riskScore, swapVolume, poolId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        DecisionMetadata memory d = decisions[tokenId];
        string memory svg = _generateSVG(d.riskScore, d.swapVolume, tokenId);
        return _buildTokenURI(tokenId, d, svg);
    }

    function _buildTokenURI(
        uint256 tokenId,
        DecisionMetadata memory d,
        string memory svg
    ) internal pure returns (string memory) {
        string memory json = string(
            abi.encodePacked(
                '{"name":"AI Decision #',
                tokenId.toString(),
                '","description":"On-chain record of AI sentiment at swap time",',
                '"attributes":[{"trait_type":"Risk Score","value":',
                d.riskScore.toString(),
                '},{"trait_type":"Sentiment","value":"',
                _sentimentLabel(d.riskScore),
                '"},{"trait_type":"Rarity","value":"',
                _rarityLabel(d.riskScore),
                '"}],"image":"data:image/svg+xml;base64,',
                Base64.encode(bytes(svg)),
                '"}'
            )
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    function _sentimentLabel(uint256 riskScore) internal pure returns (string memory) {
        if (riskScore <= 2000) return "Calm";
        if (riskScore >= 8000) return "Extreme";
        return "Neutral";
    }

    function _rarityLabel(uint256 riskScore) internal pure returns (string memory) {
        if (riskScore >= 8000) return "Legendary";
        if (riskScore <= 2000) return "Common";
        return "Rare";
    }

    function _generateSVG(
        uint256 riskScore,
        uint256 swapVolume,
        uint256 tokenId
    ) internal pure returns (string memory) {
        string memory bg = _colorForRisk(riskScore);
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
                '<rect width="400" height="400" fill="',
                bg,
                '"/>',
                '<circle cx="200" cy="200" r="80" fill="none" stroke="white" stroke-width="3" opacity="0.6"/>',
                '<circle cx="200" cy="200" r="120" fill="none" stroke="white" stroke-width="2" opacity="0.4"/>',
                '<text x="200" y="60" text-anchor="middle" fill="white" font-size="22" font-family="monospace">AI DECISION</text>',
                '<text x="200" y="340" text-anchor="middle" fill="white" font-size="16" font-family="monospace">Risk: ',
                riskScore.toString(),
                '</text>',
                '<text x="200" y="365" text-anchor="middle" fill="white" font-size="14" font-family="monospace">Vol: ',
                swapVolume.toString(),
                " #",
                tokenId.toString(),
                "</text></svg>"
            )
        );
    }

    function _colorForRisk(uint256 riskScore) internal pure returns (string memory) {
        if (riskScore <= 2000) return "#1a5276";
        if (riskScore >= 8000) return "#922b21";
        return "#b7950b";
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
