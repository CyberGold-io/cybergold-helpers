// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";

/// @notice Selector tables for the helpers diamond to keep deployment helpers/test harnesses in sync.
library LegacyFacetSelectors {
    /// @notice Return selectors exposed by the admin facet.
    /// @return selectors admin facet selectors in deterministic order.
    function adminSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = 0x0ac68a1e; // approvedAdapters()
        selectors[1] = 0x5feb7524; // coreDiamond()
        selectors[2] = 0x15204fc0; // helperFeePpm()
        selectors[3] = 0x76cba77d; // isAdapterApproved(address)
        selectors[4] = 0x12261ee7; // permit2()
        selectors[5] = 0xc0f8611f; // recoverAdapter(address,address)
        selectors[6] = 0xcaa3f542; // setAdapterApproval(address,bool,bool)
        selectors[7] = 0x27e14128; // setHelperFeePpm(uint256,uint256)
        selectors[8] = 0xb8dc491b; // sweep(address,address)
        selectors[9] = 0xeb6d3a11; // wrappedNative()
    }

    /// @notice Return selectors exposed by the issuePreview facet.
    /// @return selectors issuePreview facet selectors in deterministic order.
    function issuePreviewSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = 0xdb129a1c; // previewIssueFromBasketExactIn(uint256[])
        selectors[1] = 0xf1f487d5; // previewIssueFromBasketExactOut(uint256)
        selectors[2] = 0xa9863541; // previewIssueFromNativeExactIn(uint256,(address,uint256,uint256,bytes)[])
        selectors[3] = 0x76dd3e97; // previewIssueFromNativeExactOut((uint256,uint256),(address,uint256,uint256,bytes)[])
        selectors[4] = 0xde318080; // previewIssueFromTokenExactIn((address,uint256),(address,uint256,uint256,bytes)[])
        selectors[5] = 0x95a287e6; // previewIssueFromTokenExactOut((address,uint256,uint256),(address,uint256,uint256,bytes)[])
    }

    /// @notice Return selectors exposed by the issue facet.
    /// @return selectors issue facet selectors in deterministic order.
    function issueSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = 0xe4fdc64a; // issueFromNativeExactOut((uint256,uint256),(address,address[]),(address,uint256,uint256,bytes)[])
        selectors[1] = 0x00a7f551; // issueFromTokenExactOut((address,uint256,uint256),(address,address[]),(address,uint256,uint256,bytes)[])
        selectors[2] = 0x462835d6; // issueFromTokenExactOutWithPermit((address,uint256,uint256),(address,address[]),(uint256,uint256,uint8,bytes32,bytes32),(address,uint256,uint256,bytes)[])
        selectors[3] = 0xd85eb636; // issueFromTokenExactOutWithPermit2((address,uint256,uint256),(address,address[]),(((address,uint256),uint256,uint256),bytes),(address,uint256,uint256,bytes)[])
    }

    /// @notice Return selectors exposed by the issueBasket facet.
    /// @return selectors issueBasket facet selectors in deterministic order.
    function issueBasketSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = 0x705b2d0b; // issueFromBasketExactInWithMixedPermits((address,uint256),(address,uint256,uint8,(uint256,uint256,uint8,bytes32,bytes32))[],(((address,uint256)[],uint256,uint256),bytes))
        selectors[1] = 0xe813952e; // issueFromBasketExactInWithPermit2((address,uint256),(((address,uint256)[],uint256,uint256),bytes))
        selectors[2] = 0xac7fbf2f; // issueFromBasketExactOutWithMixedPermits((uint256,address),(address,uint256,uint8,(uint256,uint256,uint8,bytes32,bytes32))[],(((address,uint256)[],uint256,uint256),bytes))
        selectors[3] = 0xabf4c20e; // issueFromBasketExactOutWithPermit2((uint256,address),(((address,uint256)[],uint256,uint256),bytes))
    }

    /// @notice Return selectors exposed by the redeem facet.
    /// @return selectors redeem facet selectors in deterministic order.
    function redeemSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](8);
        selectors[0] = 0xdb78bdb5; // previewRedeemToNativeExactIn(uint256,(address,uint256,bytes)[])
        selectors[1] = 0x7b67ed8b; // previewRedeemToTokenExactIn((uint256,address),(address,uint256,bytes)[])
        selectors[2] = 0xf2c4c397; // redeemToNativeExactIn((uint256,address,uint256,(uint8,address,uint256,uint256)[]),(address,uint256,bytes)[])
        selectors[3] = 0x065600b2; // redeemToNativeExactInWithPermit((uint256,address,uint256,(uint8,address,uint256,uint256)[]),(uint256,uint256,uint8,bytes32,bytes32),(address,uint256,bytes)[])
        selectors[4] = 0x300b4423; // redeemToNativeExactInWithPermit2((uint256,address,uint256,(uint8,address,uint256,uint256)[]),(((address,uint256),uint256,uint256),bytes),(address,uint256,bytes)[])
        selectors[5] = 0x3b25a19c; // redeemToTokenExactIn((uint256,address,address,uint256,(uint8,address,uint256,uint256)[]),(address,uint256,bytes)[])
        selectors[6] = 0x6fa6d883; // redeemToTokenExactInWithPermit((uint256,address,address,uint256,(uint8,address,uint256,uint256)[]),(uint256,uint256,uint8,bytes32,bytes32),(address,uint256,bytes)[])
        selectors[7] = 0x1c0b4907; // redeemToTokenExactInWithPermit2((uint256,address,address,uint256,(uint8,address,uint256,uint256)[]),(((address,uint256),uint256,uint256),bytes),(address,uint256,bytes)[])
    }

    /// @notice Return selectors exposed by the redeemBasket facet.
    /// @return selectors redeemBasket facet selectors in deterministic order.
    function redeemBasketSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = 0xde1e8b45; // previewRedeemToBasketExactIn(uint256)
        selectors[1] = 0xac49c069; // previewRedeemToBasketExactOut((uint8,address,uint256,uint256)[])
        selectors[2] = 0xc2f2261c; // redeemToBasketExactIn((uint256,address,(uint8,address,uint256,uint256)[]))
        selectors[3] = 0xddf6a573; // redeemToBasketExactInWithPermit((uint256,address,(uint8,address,uint256,uint256)[]),(uint256,uint256,uint8,bytes32,bytes32))
        selectors[4] = 0x233f8db8; // redeemToBasketExactInWithPermit2((uint256,address,(uint8,address,uint256,uint256)[]),(((address,uint256),uint256,uint256),bytes))
    }

    /// @notice Return selectors exposed by the recoveryShareReceiver facet.
    /// @return selectors recoveryShareReceiver facet selectors in deterministic order.
    function recoveryShareReceiverSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = 0xbc197c81; // onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)
        selectors[1] = 0xf23a6e61; // onERC1155Received(address,address,uint256,uint256,bytes)
    }

    /// @notice Build facet specifications for this diamond cut.
    /// @param admin admin facet address.
    /// @param issuePreview issuePreview facet address.
    /// @param issue issue facet address.
    /// @param issueBasket issueBasket facet address.
    /// @param redeem redeem facet address.
    /// @param redeemBasket redeemBasket facet address.
    /// @param recoveryShareReceiver recoveryShareReceiver facet address.
    /// @return entries Named facet specifications with their expected selectors.
    function specs(
        address admin,
        address issuePreview,
        address issue,
        address issueBasket,
        address redeem,
        address redeemBasket,
        address recoveryShareReceiver
    ) internal pure returns (FacetSpec.Entry[] memory entries) {
        entries = new FacetSpec.Entry[](7);
        entries[0] = FacetSpec.Entry({name: "admin", facet: admin, selectors: adminSelectors()});
        entries[1] = FacetSpec.Entry({name: "issuePreview", facet: issuePreview, selectors: issuePreviewSelectors()});
        entries[2] = FacetSpec.Entry({name: "issue", facet: issue, selectors: issueSelectors()});
        entries[3] = FacetSpec.Entry({name: "issueBasket", facet: issueBasket, selectors: issueBasketSelectors()});
        entries[4] = FacetSpec.Entry({name: "redeem", facet: redeem, selectors: redeemSelectors()});
        entries[5] = FacetSpec.Entry({name: "redeemBasket", facet: redeemBasket, selectors: redeemBasketSelectors()});
        entries[6] = FacetSpec.Entry({
            name: "recoveryShareReceiver", facet: recoveryShareReceiver, selectors: recoveryShareReceiverSelectors()
        });
    }
}
