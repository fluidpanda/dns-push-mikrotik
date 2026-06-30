# dns-push-mikrotik

RouterOS scripts that automatically create and remove DNS records for connected clients -- DHCP, L2TP/IPsec, IKEv2, and
WireGuard -- using the client name as the hostname.

## How it works

Each script monitors its respective connection type and manages `/ip/dns/static` entries on the local router. Since
spoke nodes forward DNS queries to the hub, records written locally on any node are automatically resolvable across the
whole network.

### DNS record format

| Connection type | Hostname                    | Comment tag                   |
|-----------------|-----------------------------|-------------------------------|
| DHCP            | `hostname.CHANGE_ME`        | `<lease-server>-<MAC>`        |
| L2TP/IPsec      | `username.remote.CHANGE_ME` | `ppp-<username>:<caller-ip>`  |
| IKEv2           | `username.remote.CHANGE_ME` | `ike-<username>:<remote-ip>`  |
| WireGuard       | `peername.remote.CHANGE_ME` | `wg-<peername>:<endpoint-ip>` |

All records are created with TTL of 1 minute to ensure stale entries expire quickly after a reconnect or address change.

---

## Scripts

### `dhcp-to-dns.rsc` + `dhcp-script.rsc`

**Trigger:** DHCP lease events (`bound` / `release`)

Runs as a DHCP lease script on spoke routers. On lease bound, creates an A record named after the client's hostname. On
release, removes it. Pushes records to the hub router via REST API.

**Setup:** Assign as lease script on the DHCP server.

---

### `ppp-to-dns-on-up.rsc` / `ppp-to-dns-on-down.rsc`

**Trigger:** PPP interface up / down events

Runs inline in PPP profile `on-up` and `on-down` hooks. Uses `$user` (PPP username) as the hostname and
`$"remote-address"` as the IP. The caller IP (`$"caller-id"`) is appended to the comment for reference.

**Setup:** Add to the PPP profile used by L2TP clients:

```routeros
/ppp/profile/set [find name=<profile>] \
    on-up="/system/script/run ppp-to-dns-on-up" \
    on-down="/system/script/run ppp-to-dns-on-down"
```

> Note: PPP environment variables (`$user`, `$"remote-address"`, `$"caller-id"`) are only available when the script is
> called from the profile hook, not when run manually.

---

### `ike-to-dns.rsc`

**Trigger:** Scheduler (polling, every 1 minute)

Reads `/ip/pool/used` filtering by `owner="IPsec"` to find active IKEv2 mode-config leases. Parses the `info` field (
format: `<remote-ip>, <username>`) to extract the client name and assigned IP. Adds records for active peers and removes
records for peers that no longer hold a lease.

**Setup:**

```routeros
/system/scheduler/add \
    name=ike-dns-sync \
    interval=1m \
    on-event="/system/script/run ike-to-dns" \
    start-time=startup
```

---

### `wg-to-dns.rsc`

**Trigger:** Scheduler (polling, every 1 minute)

Iterates over all WireGuard peers and checks `last-handshake`. If the handshake is fresher than 185 seconds, the peer is
considered online and a DNS record is created. If the handshake is stale or absent, any existing record is removed.

The peer IP is extracted from `allowed-address` (strips the `/32` prefix mask).

**Setup:**

```routeros
/system/scheduler/add \
    name=wg-dns-sync \
    interval=1m \
    on-event="/system/script/run wg-to-dns" \
    start-time=startup
```

---

### `remote-dns-sync.rsc`

**Trigger:** Scheduler (polling, every 1 minute)

Keeps a spoke node (e.g. a secondary site running its own L2TP/IKEv2/WireGuard endpoints) in sync with the hub's DNS
table in both directions, over the hub's REST API:

- **Push:** any record on this node tagged `ppp-`, `ike-`, or `wg-` (i.e. created by the scripts above because a client
  connected directly to this node) is pushed to the hub, overwriting whatever the hub currently has for that hostname.
  A local connection always wins over a stale hub-side record.
- **Pull:** anything on the hub that doesn't already exist locally -- DHCP hosts, plain static records, CNAME records,
  and DNS forwarder (`type=FWD`) records -- is mirrored locally, tagged with a `sync-` prefix so it can be told apart
  from local-origin records and cleaned up automatically once it's gone from the hub or superseded by a local
  connection.
- **Forwarder profiles:** before mirroring any FWD record, the script first syncs `/ip/dns/forwarders` profiles from the
  hub, since FWD records reference a profile by name and the profile has to exist locally first.

| Origin                           | Local tag              | Mirrored tag (`sync-` prefix)   |
|----------------------------------|------------------------|---------------------------------|
| DHCP                             | `<lease-server>-<MAC>` | `sync-<lease-server>-<MAC>`     |
| L2TP/IPsec                       | `ppp-<username>:<ip>`  | `sync-ppp-<username>:<ip>`      |
| IKEv2                            | `ike-<username>:<ip>`  | `sync-ike-<username>:<ip>`      |
| WireGuard                        | `wg-<peername>:<ip>`   | `sync-wg-<peername>:<ip>`       |
| Plain static record (no comment) | --                     | `sync-static`                   |
| CNAME record                     | --                     | `sync-cname`                    |
| FWD forwarder record             | --                     | `sync-fwd`                      |

`match-subdomain` is carried over for both plain static and FWD records.

**Setup:** fill in the hub's REST endpoint and credentials at the top of the script, then:

```routeros
/system/scheduler/add \
    name=remote-dns-sync \
    interval=1m \
    on-event="/system/script/run remote-dns-sync" \
    start-time=startup
```

---

## Scaling to other nodes

All scripts are self-contained and write DNS records locally. To enable DNS registration on additional nodes (e.g. a
secondary WireGuard or IKEv2 endpoint), deploy the relevant scripts there and add the corresponding scheduler or PPP
profile hooks. As long as the hub forwards DNS queries to that node, the records will be resolvable network-wide without
any additional configuration. For nodes that also need to resolve hub-originated records locally (instead of relying on
DNS forwarding back to the hub), add `remote-dns-sync.rsc` to mirror the hub's table directly.
