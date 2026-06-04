// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Parameters for creating a tier (outcome) in a Defifa game.
/// @custom:member name The name of the tier.
/// @custom:member reservedRate The number of tokens that must be minted in the tier before another reserved token can
/// be minted for the tier's reserved token beneficiary.
/// @custom:member reservedTokenBeneficiary The beneficiary that receives the reserved tokens minted for this tier.
/// @custom:member encodedIpfsUri The URI to use for each token within the tier.
/// @custom:member shouldUseReservedTokenBeneficiaryAsDefault A flag indicating if the `reservedTokenBeneficiary` should
/// be stored as the default beneficiary for all tiers, saving storage.
struct DefifaTierParams {
    string name;
    uint16 reservedRate;
    address reservedTokenBeneficiary;
    bytes32 encodedIpfsUri;
    bool shouldUseReservedTokenBeneficiaryAsDefault;
}
