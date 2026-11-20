#!/usr/bin/env bash
# Deploys Pactboard through the CREATE2 deployer using the Binance Agentic Wallet CLI.
# Requires: Developer mode enabled in the Binance app (baw: "Developer mode is not enabled").
set -euo pipefail
export PATH=/home/box/.local/bin:$HOME/.foundry/bin:$PATH
W=0xcadC3922EdE76Ff40D42df3a54E5732742A891b4
F=0x4e59b44847b379578588920cA78FbF26c0B4956C
EXPECTED=0x8185b53546a902AEAcd44C70248a23FBFB0C821d
R=https://bsc-rpc.publicnode.com
cd "$(dirname "$0")"
baw --json contract-call preview --binanceChainId 56 --from $W --to $F --value 0 --inputData "$(cat create2-calldata.hex)" | tee /tmp/pb_preview.json
ID=$(jq -r '.data.requestId // .data.id' /tmp/pb_preview.json)
baw --json contract-call execute --requestId "$ID" | tee /tmp/pb_exec.json
sleep 6
cast code $EXPECTED --rpc-url $R | wc -c
