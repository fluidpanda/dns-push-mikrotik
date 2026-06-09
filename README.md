# dns-push-mikrotik

RouterOS scripts that automatically create and remove DNS records for connected clients — DHCP, L2TP/IPsec, IKEv2, and
WireGuard — using the client name as the hostname.

## How it works

Each script monitors its respective connection type and manages `/ip/dns/static` entries on the local router. Since
spoke nodes forward DNS queries to the hub, records written locally on any node are automatically resolvable across the
whole network.

### DNS record format

| Connection type | Hostname                    | Comment tag                   |
|-----------------|-----------------------------|-------------------------------|
| DHCP            | `hostname.CHANGE_ME`        | `dhcp-<MAC>`                  |
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

## Scaling to other nodes

All scripts are self-contained and write DNS records locally. To enable DNS registration on additional nodes (e.g. a
secondary WireGuard or IKEv2 endpoint), deploy the relevant scripts there and add the corresponding scheduler or PPP
profile hooks. As long as the hub forwards DNS queries to that node, the records will be resolvable network-wide without
any additional configuration.
