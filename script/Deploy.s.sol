// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";

import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";
import {ITypeface} from "lib/typeface/contracts/interfaces/ITypeface.sol";

import {Defifa1155Hook} from "../src/Defifa1155Hook.sol";
import {DefifaDeployer} from "../src/DefifaDeployer.sol";
import {DefifaGovernor} from "../src/DefifaGovernor.sol";
import {DefifaHook} from "../src/DefifaHook.sol";
import {DefifaTiersHookStore} from "../src/DefifaTiersHookStore.sol";
import {DefifaTokenUriResolver} from "../src/DefifaTokenUriResolver.sol";

contract DeployScript is Script, Sphinx {
    /// @notice The core controller and the address registry, at the same address on every chain. The rest of core
    /// is read from the controller.
    IJBController private constant _CONTROLLER = IJBController(0x3Fcec3572e84b624477BcfF4E2CF1f7dEAb648F1);
    IJBAddressRegistry private constant _REGISTRY = IJBAddressRegistry(0x581bFD1eAD279E0a27B736e49494db3a7d85993C);

    /// @notice The core directory, read from the controller.
    IJBDirectory private directory;

    /// @notice The address that is allowed to forward calls to the terminal and controller on a users behalf.
    address private trustedForwarder;

    /// @notice The Capsules typeface the token URI resolver renders with on this chain.
    ITypeface private typeface;

    /// @notice The fee tokens of the Defifa project and the base protocol project.
    IERC20 private defifaToken;
    IERC20 private baseProtocolToken;

    /// @notice The project that takes the fee from games (the DEFIFA revnet), and the base protocol project (NANA).
    uint256 private constant _DEFIFA_PROJECT_ID = 5;
    uint256 private constant _BASE_PROTOCOL_PROJECT_ID = 1;

    /// @notice the salts that are used to deploy the contracts.
    bytes32 private constant _HOOK_STORE_SALT = "DefifaTiersHookStoreV6_";
    bytes32 private constant _TOKEN_URI_RESOLVER_SALT = "DefifaTokenUriResolverV6_";
    bytes32 private constant _HOOK_SALT = "DefifaHookV6_";
    bytes32 private constant _GOVERNOR_SALT = "DefifaGovernorV6_";
    bytes32 private constant _DEPLOYER_SALT = "DefifaDeployerV6_";
    bytes32 private constant _1155_HOOK_SALT = "Defifa1155HookV6_";
    bytes32 private constant _1155_GOVERNOR_SALT = "Defifa1155GovernorV6_";
    bytes32 private constant _1155_DEPLOYER_SALT = "Defifa1155DeployerV6_";

    function configureSphinx() public override {
        sphinxConfig.projectName = "defifa-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    function run() public {
        // Read core from the controller. We want to do this outside of the `sphinx` modifier.
        require(address(_CONTROLLER).code.length != 0, "Core controller is not deployed on this chain");
        require(address(_REGISTRY).code.length != 0, "Address registry is not deployed on this chain");
        directory = _CONTROLLER.DIRECTORY();

        // We use the same trusted forwarder as the core deployment.
        trustedForwarder = ERC2771Context(address(_CONTROLLER)).trustedForwarder();

        // Both fee projects must have an ERC-20 on this chain.
        defifaToken = IERC20(address(_CONTROLLER.TOKENS().tokenOf(_DEFIFA_PROJECT_ID)));
        baseProtocolToken = IERC20(address(_CONTROLLER.TOKENS().tokenOf(_BASE_PROTOCOL_PROJECT_ID)));
        require(address(defifaToken) != address(0), "Defifa project has no token on this chain");
        require(address(baseProtocolToken) != address(0), "Base protocol project has no token on this chain");

        // The resolver renders with the Capsules typeface deployed on this chain.
        typeface = _typefaceOf(block.chainid);
        require(address(typeface).code.length != 0, "Typeface is not deployed on this chain");

        // Perform the deployment transactions.
        deploy();
    }

    /// @notice each contract here will be deployed it if needs to be (re)deployed.
    /// It will deploy if the contracts bytecode changes or if any constructor arguments change.
    /// Since all the contract dependencies are passed in using the constructor args,
    // this makes it so that if any dependency contract (address) changes the contract will be redeployed.
    function deploy() public sphinx {
        // Both game types share one tiers store and one token URI resolver.
        DefifaTiersHookStore store;
        {
            // Perform the check for the store.
            (address _store, bool _storeIsDeployed) = _isDeployed({
                salt: _HOOK_STORE_SALT, creationCode: type(DefifaTiersHookStore).creationCode, arguments: ""
            });

            // Deploy it if it has not been deployed yet.
            store =
                !_storeIsDeployed ? new DefifaTiersHookStore{salt: _HOOK_STORE_SALT}() : DefifaTiersHookStore(_store);
        }

        DefifaTokenUriResolver tokenUriResolver;
        {
            // Perform the check for the resolver.
            (address _tokenUriResolver, bool _tokenUriResolverIsDeployed) = _isDeployed({
                salt: _TOKEN_URI_RESOLVER_SALT,
                creationCode: type(DefifaTokenUriResolver).creationCode,
                arguments: abi.encode(safeAddress())
            });

            // Deploy it if it has not been deployed yet.
            tokenUriResolver = !_tokenUriResolverIsDeployed
                ? new DefifaTokenUriResolver{salt: _TOKEN_URI_RESOLVER_SALT}({deployer: safeAddress()})
                : DefifaTokenUriResolver(_tokenUriResolver);

            // Set the chain's typeface once. The constructor args stay the same on every chain.
            if (address(tokenUriResolver.typeface()) == address(0)) {
                tokenUriResolver.setChainSpecificConstants(typeface);
            }
            require(tokenUriResolver.typeface() == typeface, "Token URI resolver has a different typeface");
        }

        // ERC-721 games: one token per position.
        DefifaHook hook;
        {
            // Perform the check for the hook.
            (address _hook, bool _hookIsDeployed) = _isDeployed({
                salt: _HOOK_SALT,
                creationCode: type(DefifaHook).creationCode,
                arguments: abi.encode(directory, defifaToken, baseProtocolToken)
            });

            // Deploy it if it has not been deployed yet.
            hook = !_hookIsDeployed
                ? new DefifaHook{salt: _HOOK_SALT}({
                    directory: directory, defifaToken: defifaToken, baseProtocolToken: baseProtocolToken
                })
                : DefifaHook(_hook);
        }

        _deployGame({
            hookCodeOrigin: address(hook),
            tokenUriResolver: tokenUriResolver,
            store: store,
            governorSalt: _GOVERNOR_SALT,
            deployerSalt: _DEPLOYER_SALT
        });

        // ERC-1155 games: positions are balances, one token ID per tier.
        Defifa1155Hook hook1155;
        {
            // Perform the check for the hook.
            (address _hook1155, bool _hook1155IsDeployed) = _isDeployed({
                salt: _1155_HOOK_SALT,
                creationCode: type(Defifa1155Hook).creationCode,
                arguments: abi.encode(directory, defifaToken, baseProtocolToken)
            });

            // Deploy it if it has not been deployed yet.
            hook1155 = !_hook1155IsDeployed
                ? new Defifa1155Hook{salt: _1155_HOOK_SALT}({
                    directory: directory, defifaToken: defifaToken, baseProtocolToken: baseProtocolToken
                })
                : Defifa1155Hook(_hook1155);
        }

        _deployGame({
            hookCodeOrigin: address(hook1155),
            tokenUriResolver: tokenUriResolver,
            store: store,
            governorSalt: _1155_GOVERNOR_SALT,
            deployerSalt: _1155_DEPLOYER_SALT
        });
    }

    /// @notice Deploy a game type's governor and deployer, and hand the governor to the deployer.
    /// @dev Each deployer needs its own governor, since only the governor's owner can initialize games on it.
    /// @param hookCodeOrigin The hook the deployer clones for each game.
    /// @param tokenUriResolver The shared token URI resolver.
    /// @param store The shared tiers store.
    /// @param governorSalt The salt of this game type's governor.
    /// @param deployerSalt The salt of this game type's deployer.
    function _deployGame(
        address hookCodeOrigin,
        DefifaTokenUriResolver tokenUriResolver,
        DefifaTiersHookStore store,
        bytes32 governorSalt,
        bytes32 deployerSalt
    )
        internal
    {
        DefifaGovernor governor;
        {
            // Perform the check for the governor.
            (address _governor, bool _governorIsDeployed) = _isDeployed({
                salt: governorSalt,
                creationCode: type(DefifaGovernor).creationCode,
                arguments: abi.encode(_CONTROLLER, safeAddress())
            });

            // Deploy it if it has not been deployed yet.
            governor = !_governorIsDeployed
                ? new DefifaGovernor{salt: governorSalt}({controller: _CONTROLLER, owner: safeAddress()})
                : DefifaGovernor(_governor);
        }

        DefifaDeployer deployer;
        {
            // Perform the check for the deployer.
            (address _deployer, bool _deployerIsDeployed) = _isDeployed({
                salt: deployerSalt,
                creationCode: type(DefifaDeployer).creationCode,
                arguments: abi.encode(
                    hookCodeOrigin,
                    tokenUriResolver,
                    governor,
                    _CONTROLLER,
                    _REGISTRY,
                    _DEFIFA_PROJECT_ID,
                    _BASE_PROTOCOL_PROJECT_ID,
                    store,
                    trustedForwarder
                )
            });

            // Deploy it if it has not been deployed yet.
            deployer = !_deployerIsDeployed
                ? new DefifaDeployer{salt: deployerSalt}({
                    hookCodeOrigin: hookCodeOrigin,
                    tokenUriResolver: tokenUriResolver,
                    governor: governor,
                    controller: _CONTROLLER,
                    registry: _REGISTRY,
                    defifaProjectId: _DEFIFA_PROJECT_ID,
                    baseProtocolProjectId: _BASE_PROTOCOL_PROJECT_ID,
                    hookStore: store,
                    trustedForwarder: trustedForwarder
                })
                : DefifaDeployer(_deployer);
        }

        // Hand a fresh governor to its deployer.
        if (governor.owner() == safeAddress()) governor.transferOwnership(address(deployer));

        // A reused governor still owned by an older deployer would block this deployer from initializing games.
        require(governor.owner() == address(deployer), "Governor is owned by another deployer, change its salt");
    }

    function _isDeployed(
        bytes32 salt,
        bytes memory creationCode,
        bytes memory arguments
    )
        internal
        view
        returns (address, bool)
    {
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            // Arachnid/deterministic-deployment-proxy address.
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });

        // Return if code is already present at this address.
        return (_deployedTo, address(_deployedTo).code.length != 0);
    }

    /// @notice The Capsules typeface deployed on a chain.
    /// @param chainId The chain ID.
    /// @return The typeface, or the zero address on an unsupported chain.
    function _typefaceOf(uint256 chainId) internal pure returns (ITypeface) {
        // Ethereum.
        if (chainId == 1) return ITypeface(0xA77b7D93E79f1E6B4f77FaB29d9ef85733A3D44A);
        // Ethereum sepolia.
        if (chainId == 11_155_111) return ITypeface(0x8C420d3388C882F40d263714d7A6e2c8DB93905F);
        // Optimism and optimism sepolia.
        if (chainId == 10 || chainId == 11_155_420) return ITypeface(0xe160e47928907894F97a0DC025c61D64E862fEAa);
        // Base.
        if (chainId == 8453) return ITypeface(0x3DE45A14ea0fe24037D6363Ae71Ef18F336D1C27);
        // Base sepolia.
        if (chainId == 84_532) return ITypeface(0xEb269d9F0850CEf5e3aB0F9718fb79c466720784);
        // Arbitrum and arbitrum sepolia.
        if (chainId == 42_161 || chainId == 421_614) return ITypeface(0x431C35e9fA5152A906A38390910d0Cfcba0Fb43b);
        return ITypeface(address(0));
    }
}
