# Deployment

Constructor args: `usdt = 0x55d398326f99059fF775485246999027B3197955` (BSC USDT), `agentId = 0x60b9262456de011f7d15a54cdd8c48baaa8b022f`.

Compiler: solc 0.8.24, optimizer on (200 runs), EVM `paris`, no metadata tricks (see `foundry.toml`).

Deployed via the canonical deterministic deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`
(call data = `salt ‖ initcode`, salt = `0x00…01`) from an Agentic Wallet that can only call existing contracts
(no raw contract creation). Expected address: `0x50aF5b7d3a70f2F038b4E3baB20B3B9e7C899f17`.

Reproduce the init code and address:

```bash
forge build
BC=$(jq -r .bytecode.object out/Pactboard.sol/Pactboard.json)
ARGS=$(cast abi-encode "constructor(address,address)" 0x55d398326f99059fF775485246999027B3197955 0x60b9262456de011f7d15a54cdd8c48baaa8b022f)
INIT=${BC}${ARGS:2}
cast create2 --deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C \
  --salt 0x0000000000000000000000000000000000000000000000000000000000000001 \
  --init-code-hash $(cast keccak $INIT)
```

Verify on BscScan / Sourcify with the standard-json input from `forge verify-contract --show-standard-json-input`
and the ABI-encoded constructor arguments above.
