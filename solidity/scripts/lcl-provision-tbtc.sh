#!/bin/bash
set -e

# Fetch the address of tbtc contract migrated from keep-network/tbtc project.
# The `tbtc` contracts have to be migrated before running this script.
# It requires `TBTC_SOL_ARTIFACTS_PATH` variable to pointing to a directory where
# contracts artifacts after migrations are located. It also expects NETWORK_ID
# variable to be set to the ID of the network where contract were deployed.
# 
# Sample command:
# TBTC_SOL_ARTIFACTS_PATH=~/go/src/github.com/keep-network/tbtc/solidity/build/contracts \
# NETWORK_ID=1801 \
#   ./lcl-provision-tbtc.sh

TBTC_CONTRACT_DATA="TBTCSystem.json"
TBTC_PROPERTY="TBTCSystemAddress"

DESTINATION_FILE=$(realpath $(dirname $0)/../migrations/external-contracts.js)

ADDRESS_REGEXP=^0[xX][0-9a-fA-F]{40}$

# Query to get address of the deployed contract for the first network on the list.
JSON_QUERY=".networks.\"${NETWORKID}\".address"

SED_SUBSTITUTION_REGEXP="['\"][a-zA-Z0-9]*['\"]"

FAILED=false

function fetch_tbtc_contract_address() {
  echo "Fetching value for ${TBTC_PROPERTY}..."
  local contractDataPath=$(realpath $TBTC_SOL_ARTIFACTS_PATH/$TBTC_CONTRACT_DATA)
  echo $contractDataPath
  local ADDRESS=$(cat ${contractDataPath} | jq "${JSON_QUERY}" | tr -d '"')

  if [[ !($ADDRESS =~ $ADDRESS_REGEXP) ]]; then
    echo "Invalid address: ${ADDRESS}"
    FAILED=true
  else
    echo "Found value for ${TBTC_PROPERTY} = ${ADDRESS}"
    sed -i -e "/${TBTC_PROPERTY}/s/${SED_SUBSTITUTION_REGEXP}/\"${ADDRESS}\"/" $DESTINATION_FILE
  fi
}

fetch_tbtc_contract_address

if $FAILED; then
echo "Failed to fetch tbtc external contract address!"
  exit 1
fi
