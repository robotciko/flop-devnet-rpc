#!/usr/bin/env bash
# FLOP devnet RPC replica — official proof procedure (verbatim from operator guide)
# Produces 3 observations: 2 before restart, 1 after restart. Peer ID must be unchanged.
set -euo pipefail
cd "$HOME/flop-devnet-rpc"
OUT="$HOME/flop-rpc-proof.txt"
: > "$OUT"

rpc() {
  curl --fail --silent --show-error --max-time 15 "$1" \
    -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg method "$2" --argjson params "$3" \
      '{jsonrpc:"2.0",id:1,method:$method,params:$params}')" | jq -er '.result'
}
LOCAL=http://127.0.0.1:9944/
FLOP=https://rpc.devnet.flop.network/
GENESIS=0x99c172c095340ace980631f9123544c6bebd4839f3437e463533422d8be2d631

finalized_height() {
  local head params hex
  head=$(rpc "$1" chain_getFinalizedHead '[]')
  params=$(jq -cn --arg head "$head" '[$head]')
  hex=$(rpc "$1" chain_getHeader "$params" | jq -er .number)
  printf '%d\n' "$hex"
}
observe() {
  local local_height reference_height common_height local_hash reference_hash
  test "$(rpc "$LOCAL" chain_getBlockHash '[0]')" = "$GENESIS"
  test "$(rpc "$FLOP" chain_getBlockHash '[0]')" = "$GENESIS"
  curl --fail --silent --show-error --max-time 5 http://127.0.0.1:9619/ready
  local_height=$(finalized_height "$LOCAL")
  reference_height=$(finalized_height "$FLOP")
  common_height=$local_height
  if (( reference_height < common_height )); then common_height=$reference_height; fi
  local_hash=$(rpc "$LOCAL" chain_getBlockHash "[$common_height]")
  reference_hash=$(rpc "$FLOP" chain_getBlockHash "[$common_height]")
  test "$local_hash" = "$reference_hash"
  printf '\nUTC=%s local_finalized=%s reference_finalized=%s common_height=%s hash=%s peer=%s\n' \
    "$(date -u +%FT%TZ)" "$local_height" "$reference_height" "$common_height" \
    "$local_hash" "$(rpc "$LOCAL" system_localPeerId '[]')" | tee -a "$OUT"
}

{
  echo "==================== FLOP DEVNET RPC REPLICA — PROOF RECEIPT ===================="
  echo "operator   : veriznode-kii"
  echo "public ip  : 152.53.179.211"
  echo "hostname   : $(hostname)"
  echo "spec       : $(nproc) vCPU / $(free -g | awk '/^Mem:/{print $2}') GiB RAM / $(df -h / | tail -1 | awk '{print $2}') disk"
  echo "ubuntu     : $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
  echo "node image : $(grep FLOP_NODE_IMAGE rpc-pool.env | cut -d= -f2-)"
  echo "chain spec : $(jq -r .name seed/latest.json)"
  echo "snapshot   : $(jq -r .name seed/latest.json)"
  echo "rpc node   : $(curl -sS --max-time 8 $LOCAL -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"system_version","params":[]}' | jq -r .result)"
  echo "genesis    : $GENESIS"
  echo "==============================================================================="
} | tee -a "$OUT"

peer_before=$(rpc "$LOCAL" system_localPeerId '[]')

echo "" | tee -a "$OUT"
echo "--- OBSERVATION 1 (pre-restart) ---" | tee -a "$OUT"
observe
echo "sleep 60..." | tee -a "$OUT"
sleep 60
echo "--- OBSERVATION 2 (pre-restart) ---" | tee -a "$OUT"
observe

echo "" | tee -a "$OUT"
echo "--- RESTARTING rpc + ready ---" | tee -a "$OUT"
docker compose --env-file rpc-pool.env -f docker-compose.rpc.yml restart rpc ready >>"$OUT" 2>&1

echo "waiting for readiness + catch-up..." | tee -a "$OUT"
for i in $(seq 1 90); do
  if curl --fail --silent --show-error --max-time 5 http://127.0.0.1:9619/ready >/dev/null 2>&1; then
    echo "  ready after ${i}0s" | tee -a "$OUT"; break
  fi
  sleep 10
done
sleep 45

echo "--- OBSERVATION 3 (post-restart) ---" | tee -a "$OUT"
observe

echo "" | tee -a "$OUT"
if [ "$(rpc "$LOCAL" system_localPeerId '[]')" = "$peer_before" ]; then
  echo "PEER ID UNCHANGED AFTER RESTART: $peer_before  ✅" | tee -a "$OUT"
else
  echo "PEER ID CHANGED ❌ ($peer_before -> $(rpc "$LOCAL" system_localPeerId '[]'))" | tee -a "$OUT"
fi
echo "" | tee -a "$OUT"
echo "=================== END OF RECEIPT ===================" | tee -a "$OUT"
echo "saved to: $OUT"
