// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "lib/safe-contracts/contracts/Safe.sol";
import "lib/safe-contracts/contracts/EIP712DomainSeparator.sol";
import "lib/safe-contracts/contracts/CheckSignaturesEIP1271.sol";
import "lib/safe-contracts/contracts/common/Enum.sol";

import "lib/openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";

/// @title WaymontSafeExternalSigner
/// @notice Smart contract signer (via ERC-1271) for Safe contracts v1.4.0 (https://github.com/safe-global/safe-contracts).
contract WaymontSafeExternalSigner is EIP712DomainSeparator, CheckSignaturesEIP1271 {
    // @dev Equivalent of `Safe.SAFE_TX_TYPEHASH` but for transactions verified by this contract specifically.
    // Computed as: `keccak256("WaymontSafeExternalSignerTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 uniqueId)");`
    bytes32 private constant EXTERNAL_SIGNER_SAFE_TX_TYPEHASH = 0xec4b32503cab7179a0e04742ad56fa15cbb52ef3b7f2648773edf851b4ac43c1;

    /// @notice Blacklist for function calls that have already been dispatched or that have been revoked.
    mapping(uint256 => bool) public functionCallUniqueIdBlacklist;

    /// @dev Initializes the contract by setting the `Safe`, signers, and threshold.
    /// @param _safe The `Safe` of which this signer contract will be an owner.
    /// @param signers The signers underlying this signer contract.
    /// @param threshold The threshold required of signers underlying this signer contract.
    /// Can only be called once (because `setupOwners` can only be called once).
    function initialize(Safe _safe, address[] calldata signers, uint256 threshold) external {
        // Input validation
        require(_safe.isOwner(address(this)), "The Safe is not owned by this Waymont signer contract.");

        // Call `setupOwners` (can only be called once)
        setupOwners(signers, threshold);

        // Set the `Safe`
        safe = _safe;
    }

    /// @notice Blacklists a function call unique ID.
    /// @param uniqueId The function call unique ID to be blacklisted.
    function blacklistFunctionCall(uint256 uniqueId) external {
        require(msg.sender == address(safe), "Sender is not the safe.");
        functionCallUniqueIdBlacklist[uniqueId] = true;
    }

    /// @notice Signature validation function used by the `Safe` overlying this contract to validate underlying signers attached to this contract.
    /// @param _data Data signed in `_signature`.
    /// @param _signature Signature byte array associated with `_data`.
    /// @dev MUST return the bytes4 magic value 0x20c13b0b when function passes.
    /// MUST NOT modify state (using STATICCALL for solc < 0.5, view modifier for solc > 0.5).
    /// MUST allow external calls.
    /// TODO: Pretty sure `_signature` is better kept as `memory` rather than `calldata` because it would waste gas to perform a large number of `calldatacopy` operations, right?
    function isValidSignature(bytes calldata _data, bytes memory _signature) external view returns (bytes4) {
        // Check signatures
        checkSignatures(keccak256(_data), _signature);

        // Return success by default
        return bytes4(0x20c13b0b);
    }

    /// @notice Additional parameters used by `WaymontSafeExternalSigner.execTransaction` (that are not part of `Safe.execTransaction`).
    struct AdditionalExecTransactionParams {
        bytes externalSignatures;
        uint256 uniqueId;
        bytes32[] merkleProof;
    }

    /// @notice Proxy for `Safe.execTransaction` allowing execution of transactions signed through merkle trees and without incremental nonces.
    /// @dev TODO: Use `calldata` or `memory` to save gas?
    /// @param additionalParams See struct type for more info. WARNING: If using a merkle tree, sure to hash each merkle tree leaf with a unique salt (adding another layer to the tree) to prevent the unauthorized submission of sibling hashes once the root signature has been revealed.
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory safeSignatures,
        AdditionalExecTransactionParams memory additionalParams
    ) external returns (bool success) {
        // Validate unique ID
        // TODO: Save gas by caching `additionalParams` in memory?
        // TODO: Save gas by putting `safeSignatures` in `additionalParams` instead of `uniqueId`?
        require(!functionCallUniqueIdBlacklist[additionalParams.uniqueId], "Function call unique ID has already been used or has been blacklisted.");

        // Scope to avoid "stack too deep"
        {
            // Compute newTxHash
            bytes32 newSafeTxHash = keccak256(abi.encode(EXTERNAL_SIGNER_SAFE_TX_TYPEHASH, to, value, keccak256(data), operation, safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, additionalParams.uniqueId));
            bytes memory newTxHashData = abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator(), newSafeTxHash);
            bytes32 newTxHash = keccak256(newTxHashData);

            // Process merkle proof
            newTxHash = MerkleProof.processProof(additionalParams.merkleProof, newTxHash);

            // Check signatures
            checkSignatures(newTxHash, additionalParams.externalSignatures);
        }

        // Blacklist unique ID's future use
        functionCallUniqueIdBlacklist[additionalParams.uniqueId] = true;

        // Execute the transaction
        return safe.execTransaction(to, value, data, operation, safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, safeSignatures);
    }
}
