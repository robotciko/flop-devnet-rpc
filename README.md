# FLOP Devnet — keyless RPC replica

Runbook and evidence for running a **keyless FLOP devnet RPC replica** on self-hosted
hardware. Archive pruning, no Tailscale, no enrollment token.

Everything in this repository is public information. No keys, enrollment material or
private configuration is included.

---

## Hardware

| | |
|---|---|
| Host | `veriznode-kii` |
| Provider | Netcup (Vienna, AT), KVM |
| CPU / RAM | 12 vCPU (AMD EPYC 9645) / 31 GiB |
| Disk | 1 TB SSD |
| OS | Ubuntu 24.04.4 LTS |
| Bandwidth | 792 Mbps down / 456 Mbps up (measured) |
| Public IPv4 | `152.53.179.211` |

---

## Pinned inputs

| Input | Value |
|---|---|
| Node image | `ghcr.io/flop-labs/flop-core/node-devnet@sha256:84498fd73db2464eb13088ab34d369ddf7cddd22a45c810d140c9ff8ec16c91d` |
| Chain spec sha256 | `3b213c38e7678285bc38fbdfded5dbe3d6acbd16e836b14aaaeef2f6ae1cd16e` |
| Genesis | `0x99c172c095340ace980631f9123544c6bebd4839f3437e463533422d8be2d631` |
| Peer ID | `12D3KooWBQBAT7xvgRMyhebnjotbtnd9w25sseFTbtcBpewwJZdL` |
| P2P multiaddr | `/ip4/152.53.179.211/tcp/30333` |
| Pruning | `STATE_PRUNING=archive` |

---

## Restore procedure

The official procedure is followed exactly: manifest genesis check, part checksums, verify,
unpack, swap, ownership alignment.

```bash
# 1. manifest + genesis check
BASE=https://snapshots.flop.network/devnet-ts/archive
curl --fail --silent --show-error --output latest.json "$BASE/latest.json"
test "$(jq -er .genesis_hash latest.json)" = "$GENESIS"   # must pass

# 2. checksums and download (resumable)
jq -er '.parts[] | "\(.sha256)  \(.file)"' latest.json > SHA256SUMS
name=$(jq -er .name latest.json)
jq -er '.parts[] | "\(.file) \(.bytes)"' latest.json | while read -r f b; do
  [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" = "$b" ] || \
    curl --fail --location --continue-at - --output "$f" "$BASE/$name/$f"
done
sha256sum --check SHA256SUMS

# 3. unpack
rm -rf unpack && mkdir unpack
jq -er '.parts[].file' latest.json | xargs cat | zstd -d | tar -x -C unpack

# 4. swap, preserving node key
docker compose --env-file rpc-pool.env -f docker-compose.rpc.yml stop
db=<volume>/chains/flop_devnet_ts/db
mv "$db/full" "$db/full.from-genesis"
mv unpack/full "$db/full"
chown -R --reference="$db" "$db/full"
docker compose --env-file rpc-pool.env -f docker-compose.rpc.yml up -d
```

> Restore from snapshot reaches the head in minutes. Syncing from genesis takes hours and
> leaves the node far behind; the snapshot path is the documented one for archive replicas.

---

## Proof of sync and restart recovery

Reference endpoint: `https://rpc.devnet.flop.network/`. Local finalized block hash was
compared against the reference at a common height. Method: fetch finalized head, read its
header number, compare `chain_getBlockHash` at that height on both endpoints.

| # | UTC | local finalized | reference | common height | hash |
|---|---|---|---|---|---|
| 1 | 2026-11-24T12:22:48Z | 4527459 | 4527459 | 4527459 | `0x1be26f972f8458f8628b1b167c906c3846c593804cd72e91f0ad1de96ba7ba67` |
| 2 | 2026-11-24T12:23:49Z | 4527521 | 4527521 | 4527521 | `0xb9aa2dbbd50bb232cff76759772d0db0c7028c3cad5e4446edaa9dfa000f6778` |
| 3 (after restart) | 2026-11-24T12:24:58Z | 4527588 | 4527588 | 4527588 | `0x56bdb0f4c5bf295d9c1577f9da2cc55a60bb5847d95a7c01830316a2bf239cf4` |

- Readiness returned `200` within **20 seconds** of restart.
- **Peer ID unchanged** after restart — `12D3KooWBQBAT7xvgRMyhebnjotbtnd9w25sseFTbtcBpewwJZdL`.
- Same Compose project and data volume retained; `node_key.dat` untouched.

`rpc_proof.sh` reproduces the sequence: it refuses to report success unless genesis matches
on both endpoints, readiness is `200`, and the local hash equals the reference hash.

---

## Validator package preflight

The public validator package was fetched and verified, then the preflight was run:

```
validator-cs-be91fe83-0.4.1-devnet.1.tar.gz
sha256 715abad72f3a8c658de5f929c6fe01b03d4204b5954925331766053610f3c967
```

- All **34 files** in the package pass `sha256sum -c SHA256SUMS`.
- `pnpm install --frozen-lockfile` completes against the committed lockfile.
- `pnpm onboard preflight --profile public-testnet` **fails closed** with:

```
Public testnet identity is unpublished; #3113 remains open
+ actual - expected
+ 'unpublished'
- 'reviewed'
```

That failure is the documented behaviour: the `public-testnet` block in
`network-inputs.v1.json` deliberately has `status: unpublished` with `chainId`, `genesisHash`,
`chainSpec`, `images` and `bootnodes` all null, and `launch.operatorAuthorization` unset.
Nothing on the operator side is missing — the gate is the network identity publication.

---

## Notes

- The devnet image is pinned by digest, not tag, so a repull cannot silently change code.
- `system_name` reports `zkVerify / 1.1.0`, which is expected for this node build.
- Disk footprint after restore: archive DB ~64 GiB.
- Port `30333/tcp` must be reachable inbound for P2P; the RPC endpoint stays bound to
  loopback and is not exposed publicly.

## Licence

MIT
