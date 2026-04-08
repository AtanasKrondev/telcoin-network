# Network Partition Analysis: Why Consensus Fails

## Topology

```
[network_A]──────────────[network_B]──────────────[network_C]
    │                         │                         │
Validator1              Validator2              Validator3              Validator4
10.10.1.21          10.10.1.22                10.10.2.23              10.10.3.24
                    10.10.2.22                10.10.3.23
```

Direct reachability:
- V1 can reach: V2 only
- V2 can reach: V1, V3
- V3 can reach: V2, V4
- V4 can reach: V3 only

This forms a linear chain: `V1 -- V2 -- V3 -- V4`

---

## Consensus Mechanism: Narwhal + Bullshark

Telcoin Network uses **Narwhal** (DAG mempool) + **Bullshark** (DAG-based BFT consensus).

Each round of Narwhal works as follows:
1. Every validator broadcasts a **header** (list of transaction batches)
2. Other validators send back a **vote** for that header
3. Once the proposer collects `2f + 1` votes, it forms a **certificate**
4. To advance to the next round, a validator must include `2f + 1` certificates from the previous round as parents

With 4 validators (`n=4`, `f=1`), the quorum is `2f + 1 = 3`.

---

## Why Votes Cannot Be Collected

### Votes Use Direct RPC — Not Gossip

Certificates (once formed) are broadcast via **gossipsub** — a flood-publish protocol that can route through intermediate peers. Votes, however, are collected differently.

In `crates/consensus/primary/src/certifier.rs:359`, when a validator proposes a header it iterates over all other committee members and sends a direct `request_response` RPC to each one:

```rust
// certifier.rs:359-363
let peers = self.committee.others_primaries_by_id(Some(&self.authority_id)).into_iter();
for (name, target) in peers {
    self.network.request_vote(peer_id, header.clone(), parents)
}
```

`request_vote` (defined in `crates/consensus/primary/src/network/mod.rs:158`) calls `self.handle.send_request(request, peer)` on line 166, which uses libp2p's `RequestResponse` behaviour — a **point-to-point protocol that requires a direct connection**. It does not route through intermediate peers.

### Quorum Analysis Per Validator

| Proposer | Direct peers | Votes collectable | Quorum (3) reached? |
|----------|-------------|-------------------|---------------------|
| V1       | V2          | V1 + V2 = 2       | NO                  |
| V2       | V1, V3      | V2 + V1 + V3 = 3  | YES                 |
| V3       | V2, V4      | V3 + V2 + V4 = 3  | YES                 |
| V4       | V3          | V4 + V3 = 2       | NO                  |

V1 and V4 can never form a certificate.

### DAG Stalls at Round 1

Even though V2 and V3 individually reach quorum, the DAG still cannot progress:

- **Round 1**: V2 and V3 form certificates. V1 and V4 do not.
- **Round 2 requires**: `2f+1 = 3` parent certificates from round 1 as a precondition to propose.
- **Available**: only 2 certificates (V2, V3).
- **Result**: no validator can advance beyond round 1. The DAG is permanently stuck.

---

## Proposed Fixes

Three options are described below. Each has a mock implementation in the codebase marked
with `// === MOCK: Option N ===` comments. None of them are wired end-to-end yet —
the TODOs in the mock code mark the remaining gaps.

---

### Option 1: Full-Mesh Network Topology

**What changes**: only `etc/compose.yaml`. No Rust code changes.

**Why it works**: every validator gets a direct connection to every other validator, so the existing `request_vote` RPC reaches all committee members and quorum is always achievable.

**Steps**:

1. Add V1 to `network_B` and `network_C` (or equivalently add V4 to `network_A` and `network_B`).
   Any topology where each validator has at least 2 direct peers that together cover the full committee works.

   ```yaml
   # etc/compose.yaml — validator1 service
   networks:
     network_A:
       ipv4_address: 10.10.1.21
     network_B:               # ADD: gives V1 a direct path to V3
       ipv4_address: 10.10.2.21
     network_C:               # ADD: gives V1 a direct path to V4
       ipv4_address: 10.10.3.21
   ```

2. Update `setup1`'s `PRIMARY_LISTENER_MULTIADDR` / `WORKER_LISTENER_MULTIADDR` to the
   address V1 should advertise in the committee (its primary network IP, `10.10.1.21`).

3. Run `make down && make up`.

**File**: `etc/compose.yaml`

---

### Option 2: Gossip-Based Vote Collection

**What changes**: consensus and network crates. Docker compose is unchanged.

**Why it works**: gossipsub routes messages transitively through intermediate peers.
Publishing a vote request once on `"tn-vote-request"` delivers it to all validators in the
chain (V1→V2→V3→V4). Each validator publishes its vote on `"tn-vote"`, which gossipsub
delivers back to the proposer the same way.

**Steps** (in dependency order):

1. **Add gossip topic constants** — `crates/config/src/network.rs:144`

   Two new methods added (mock at line 144):
   - `LibP2pConfig::primary_vote_request_topic()` → `"tn-vote-request"`
   - `LibP2pConfig::primary_vote_topic()` → `"tn-vote"`

2. **Add gossip message variants** — `crates/consensus/primary/src/network/message.rs:74`

   Two new variants added to `PrimaryGossip` (mock at line 74):
   - `VoteRequest(Box<Header>)` — proposer flood-publishes its header
   - `VoteGossip(Box<Vote>)` — voter flood-publishes its signed vote in response

3. **Subscribe to the new topics** — `crates/network-libp2p/src/consensus.rs` (or wherever
   topics are subscribed at startup)

   The primary network must subscribe to `"tn-vote-request"` and `"tn-vote"` so gossipsub
   delivers messages to the `process_gossip` handler.

4. **Handle incoming vote requests and votes** — `crates/consensus/primary/src/network/handler.rs:317`

   Two match arms added to `RequestHandler::process_gossip` (mock at line 317):
   - `VoteRequest`: validate the header, call the existing `self.vote(...)` logic, then
     publish the result via `network_handle.publish_vote(vote)` instead of an RPC response.
   - `VoteGossip`: verify the vote signature, then forward it to the certifier via
     `consensus_bus.gossip_votes().send(*vote)` (channel not yet added — see step 5).

5. **Add a `gossip_votes` channel to `ConsensusBus`** — `crates/consensus/primary/src/lib.rs`
   (or wherever `ConsensusBus` is defined)

   A new broadcast/mpsc channel so `process_gossip` (step 4) can deliver incoming
   `VoteGossip` messages to the certifier task that is waiting for quorum.

6. **Add publish methods to `PrimaryNetworkHandle`** — `crates/consensus/primary/src/network/mod.rs:106`

   Two methods added (mock at line 106):
   - `publish_vote_request(header)` — encodes `PrimaryGossip::VoteRequest` and publishes
     on `"tn-vote-request"`. Replaces the per-peer RPC loop in `propose_header`.
   - `publish_vote(vote)` — encodes `PrimaryGossip::VoteGossip` and publishes on `"tn-vote"`.
     Called by the `VoteRequest` handler instead of returning `PrimaryResponse::Vote`.

7. **Replace `propose_header` with `propose_header_via_gossip`** — `crates/consensus/primary/src/certifier.rs:243`

   The mock method is already present at line 243. To complete it:
   - Uncomment `self.network.publish_vote_request(header.clone()).await?`
   - Uncomment `let mut rx_gossip_votes = self.consensus_bus.subscribe_gossip_votes()`
   - Uncomment the vote aggregation loop
   - Replace all call-sites of `propose_header` with `propose_header_via_gossip` in `spawn_header_proposal`

**Files touched**:
- `crates/config/src/network.rs:144` — step 1 (mock done)
- `crates/consensus/primary/src/network/message.rs:74` — step 2 (mock done)
- `crates/consensus/primary/src/network/handler.rs:317` — step 4 (mock done)
- `crates/consensus/primary/src/network/mod.rs:106` — step 6 (mock done)
- `crates/consensus/primary/src/certifier.rs:243` — step 7 (mock done)
- `crates/consensus/primary/src/lib.rs` — step 5 (not yet started)

---

### Option 3: libp2p Circuit Relay

**What changes**: network crate and config. No consensus or certifier logic changes.

**Why it works**: a circuit relay lets two peers that cannot reach each other directly
establish a virtual connection through an intermediate relay node. V2 and V3 act as relay
servers; V1 and V4 act as relay clients. Once the circuit is established, the existing
`request_vote` RPC travels over it transparently — no changes to vote collection logic.

**Steps** (in dependency order):

1. **Add the `relay` feature to libp2p** — `crates/network-libp2p/Cargo.toml`

   ```toml
   libp2p = { features = ["relay", ...existing features...] }
   ```

2. **Add relay fields to `TNBehavior`** — `crates/network-libp2p/src/consensus.rs:111`

   Two commented-out fields are already documented in the mock at line 111:
   ```rust
   pub(crate) relay_server: libp2p::relay::Behaviour,       // for V2, V3
   pub(crate) relay_client: libp2p::relay::client::Behaviour, // for V1, V4
   ```
   Uncomment them and construct them in `TNBehavior::new`.

3. **Wire relay into `SwarmBuilder`** — `crates/network-libp2p/src/consensus.rs`
   (`ConsensusNetwork::new`)

   Add `.with_relay_client(...)` to the `SwarmBuilder` chain. The relay client behaviour
   must be built from the swarm's keypair, which `SwarmBuilder` provides at build time.

4. **Add relay configuration to `LibP2pConfig`** — `crates/config/src/network.rs`

   Add a flag (`is_relay_server: bool`) and a list of relay node multiaddrs
   (`relay_nodes: Vec<Multiaddr>`) so each validator knows its role.

5. **Listen on the circuit address** — `crates/network-libp2p/src/consensus.rs`
   (startup/connection logic)

   After dialling and connecting to a relay server, call:
   ```rust
   swarm.listen_on("/p2p/<RelayPeerId>/p2p-circuit".parse()?)
   ```
   This makes the relay server accept inbound circuits on behalf of this client.

6. **Dial unreachable peers via relay multiaddr** — `crates/network-libp2p/src/consensus.rs`
   (or the Kademlia/peer-manager layer)

   When dialling a peer that is not directly reachable, use a relay address:
   ```
   /ip4/10.10.2.22/udp/49590/quic-v1/p2p/<V2-PeerId>/p2p-circuit/p2p/<V4-PeerId>
   ```
   The existing `RequestResponse` vote protocol then works over the circuit unchanged.

**Files touched**:
- `crates/network-libp2p/Cargo.toml` — step 1 (not yet started)
- `crates/network-libp2p/src/consensus.rs:65,111` — steps 2, 3, 5, 6 (strategy documented at line 65, fields at line 111)
- `crates/config/src/network.rs` — step 4 (not yet started)

---

## Summary

The root cause is a mismatch between the **connectivity requirements of the vote-collection
protocol** (direct RPC to all committee members) and the **actual network reachability**
(linear chain). The gossip layer could propagate certificates transitively, but votes never
get a chance to travel through intermediaries, so V1 and V4 are permanently unable to
produce certificates, and the entire DAG stalls because no validator can assemble the 3
parent certificates needed to start round 2.

| Option | Scope | Consensus code changes | Complexity |
|--------|-------|----------------------|------------|
| 1 — Full-mesh topology | `compose.yaml` only | None | Low |
| 2 — Gossip-based votes | 5 Rust files + 1 new channel | High (vote flow refactor) | High |
| 3 — libp2p circuit relay | 2 Rust files + config | None | Medium |

---

## Appendix: Real-World Production Scenario

The analysis above uses a synthetic Docker Compose setup with a **deliberately hostile topology** to
illustrate consensus failure. In production, validators are geographically distributed and face
much more complex constraints.

### Production Reality

**Geographic distribution**:
- Validator-A: Tokyo (AWS ap-northeast-1)
- Validator-B: Frankfurt (AWS eu-central-1)
- Validator-C: São Paulo (AWS sa-east-1)
- Validator-D: Singapore (AWS ap-southeast-1)

**Connectivity challenges**:
1. **Transient partitions**: BGP hijacks, ISP outages, or DDoS attacks could isolate a validator for seconds to minutes.
2. **Asymmetric paths**: A→B might work while B→A times out (TCP retransmit asymmetry).
3. **Packet loss and jitter**: Intercontinental links often have 100-300ms latency + loss.
4. **NAT/firewall**: Enterprise networks block inbound connections; relay nodes become critical.

### Why Option 1 (Full-Mesh Topology) Fails in Production

Full-mesh requires N(N-1)/2 direct connections for N validators. With 100 validators:

- **Connections needed**: ~5,000 TCP/QUIC sessions open simultaneously
- **Resource overhead**: Each connection consumes kernel buffers, file descriptors, memory
- **Latency variability**: A validator waiting for a vote from a distant peer may timeout if:
  - The peer is temporarily unreachable (ISP issue, DDoS scrubbing)
  - The peer's network card is saturated
  - The path has unusual loss patterns (affects QUIC congestion control)
- **Consensus stalls**: Even one peer timing out on vote response delays the proposer

**In practice**: production blockchains like Solana (~200 validators) use gossip because full-mesh
doesn't scale beyond ~20 validators.

### Why Option 2 (Gossip-Based Votes) Works in Production

Gossip uses a **small fanout** (typically 6-12 peers) instead of all-to-all:

```
Proposer publishes once to 12 random peers
Each peer gossips to 12 random peers
Quorum is reached within ~2-3 hops (log N)
```

**Benefits**:
- Redundancy: if one connection fails, the message reaches quorum via other paths
- Bandwidth: O(N log N) instead of O(N²)
- Latency: bounded by the slowest of 3 gossip hops, not the slowest of N direct calls
- Graceful degradation: partial partitions don't stall consensus; votes just take longer

**Real-world example**: Cosmos (Tendermint) uses gossip for all consensus messages. Validators
in regions with poor interconnect still reach quorum because messages route around failures.

### Why Option 3 (Circuit Relay) Works in Production

Relay nodes are **strategically placed** in well-connected regions:

```
Relay-1: Ashburn, VA (US East Coast) — connected to 30+ ISPs
Relay-2: Amsterdam — connected to Europe's internet exchange
Relay-3: Singapore — connected to Asia's internet exchange
```

Validators connect to the nearest relay(s):
- Validator-A (Tokyo) → Relay-3 (Singapore) [100ms]
- Validator-D (Singapore) → Relay-3 (Singapore) [5ms]
- Validator-D (Singapore) → Validator-A (Tokyo) via Relay-3 circuit [105ms]

**Benefits**:
- Bypasses direct interconnect issues (e.g., Tokyo-São Paulo path might be congested, but
  both can reach Singapore efficiently)
- Reduces validator infrastructure burden (no need for BGP, DDoS mitigation)
- Operators control relay placement (can upgrade/move relays without validator updates)

**Real-world analogy**: Akamai CDN. Instead of every website talking directly to every user,
requests route through Akamai's relay infrastructure.

### Which Option for Production?

| Scenario | Option 1 | Option 2 | Option 3 |
|----------|----------|----------|----------|
| <20 validators, single datacenter | ✅ OK | ⚠️ Overkill | ❌ Overkill |
| 20-100 validators, multi-region | ❌ Fails | ✅ **Recommended** | ✅ Good alternative |
| 100+ validators, global | ❌ Fails | ✅ **Essential** | ⚠️ Complexity |
| Adversarial partitions (wartime) | ❌ Fails | ✅ Best | ✅ Good |
| High-latency network | ❌ Sensitive | ✅ Resilient | ✅ Resilient |

**Consensus**: Option 2 (gossip-based votes) is the **production-grade solution**. It scales to
hundreds of validators, survives partial partitions, and is battle-tested in Cosmos, Polkadot,
and Ethereum 2 (via libp2p gossipsub for attestations).

### Testing Production Scenarios

The current Docker Compose setup with the linear-chain topology is a good **smoke test** for
Option 2 implementation. To test production readiness, add:

1. **Latency injection**: use `tc (traffic control)` to add 100-300ms delays between validators
2. **Packet loss**: add 1-5% loss on the gossip topics
3. **Temporary disconnects**: kill random validator containers and restart them after 10-30 seconds
4. **Asymmetric failures**: block A→B but allow B→A

If consensus converges within reasonable time under these conditions, Option 2 is production-ready.
