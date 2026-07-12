# dns-push-mikrotik

RouterOS scripts that automatically create and remove DNS records for connected clients -- DHCP, L2TP/IPsec, IKEv2, and
WireGuard -- using the client name as the hostname.

## How it works

Each script monitors its respective connection type and manages `/ip/dns/static` entries on the local router. Since
spoke nodes forward DNS queries to the hub, records written locally on any node are automatically resolvable across the
whole network.

Scripts that need to reach the hub (`dhcp-to-dns.rsc`, `remote-dns-sync.rsc`) do so via `/system/ssh-exec`,
authenticated with an SSH key -- not the REST API. RouterOS never closes REST API sessions opened via `/tool/fetch`, so
a script polling every 1-1.5 minutes accumulates hundreds of stale entries in `/user/active/print` within a day. SSH
sessions close normally, so this doesn't happen.

### DNS record format

| Connection type | Hostname                    | Comment tag                   |
|-----------------|-----------------------------|-------------------------------|
| DHCP            | `hostname.CHANGE_ME`        | `<lease-server>-<MAC>`        |
| L2TP/IPsec      | `username.remote.CHANGE_ME` | `ppp-<username>:<caller-ip>`  |
| IKEv2           | `username.remote.CHANGE_ME` | `ike-<username>:<remote-ip>`  |
| WireGuard       | `peername.remote.CHANGE_ME` | `wg-<peername>:<endpoint-ip>` |

All records are created with TTL of 1 minute to ensure stale entries expire quickly after a reconnect or address change.

---

## `globals.rsc`

Shared configuration used by every other script in this repo. Declares a set of `:global` variables once so credentials
and endpoints don't need to be duplicated (and separately kept in sync) across every script:

```routeros
:global dhcpDnsTtl "1d 00:00:00"
:global domain ".localdomain"
:global faceHost "10.2.240.1"
:global faceSshUser "dnssync"
:global remoteDomain "remote.localdomain"
```

Every script that references a global variable checks it first and re-runs `globals.rsc` if it's empty, so it self-heals
after a reboot even though `:global` values don't persist across restarts on their own:

```routeros
:global faceHost
:if ([:len $faceHost] = 0) do={
    /system/script/run globals
}
```

**Setup:** add `globals.rsc` as a script on every node (hub and spokes), and schedule it to run at startup so the
variables are populated before anything else needs them:

```routeros
/system/scheduler/add \
    name=globals-init \
    interval=0s \
    on-event="/system/script/run globals" \
    start-time=startup
```

### SSH key setup (hub + spokes)

`faceHost`/`faceSshUser` are used by `ssh-exec` to reach the hub. RouterOS can't generate SSH keys itself, so generate a
key pair externally:

```bash
ssh-keygen -m PKCS8 -t ed25519 -f dnssync_key -C "dnssync-sync"
```

On every spoke that runs `ssh-exec` against the hub, import the private key under the local user the scheduler runs as:

```routeros
/user/ssh-keys/private/import user=<local-user> private-key-file=dnssync_key
```

On the hub, import and trust the public key for the `dnssync` user, and make sure that user's group has `ssh` (plus
`read`/`write` on `/ip/dns`) rights:

```routeros
/user/ssh-keys/import public-key-file=dnssync_key.pub user=dnssync
```

Verify before relying on it:

```routeros
/system/ssh-exec address=$faceHost user=$faceSshUser command=":put 1"
```

---

## Scripts

### `dhcp-to-dns.rsc` + `dhcp-script.rsc`

**Trigger:** DHCP lease events (`bound` / `release`)

Runs as a DHCP lease script on spoke routers. On lease bound, creates an A record named after the client's hostname. On
release, removes it. Pushes the same change to the hub via `ssh-exec` (`remove [find comment=<token>]; add ...` as a
single remote command).

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
table in both directions, over `ssh-exec`:

- **Fetch:** the full `/ip/dns/static` and `/ip/dns/forwarders` tables are pulled from the hub in two `ssh-exec` calls,
  each running a remote `print ... as-value` serialized to JSON with `:serialize ... to=json` and parsed locally with
  `:deserialize ... from=json`.
- **Push:** any record on this node tagged `ppp-`, `ike-`, or `wg-` (i.e. created by the scripts above because a client
  connected directly to this node) is pushed to the hub as a single `remove [find name=...]; add ...` remote command,
  overwriting whatever the hub currently has for that hostname. A local connection always wins over a stale hub-side
  record.
- **Pull:** anything on the hub that doesn't already exist locally -- DHCP hosts, plain static records, CNAME records,
  and DNS forwarder (`type=FWD`) records -- is mirrored locally, tagged with a `sync-` prefix so it can be told apart
  from local-origin records and cleaned up automatically once it's gone from the hub or superseded by a local
  connection.
- **Forwarder profiles:** before mirroring any FWD record, the script first syncs `/ip/dns/forwarders` profiles from the
  hub, since FWD records reference a profile by name and the profile has to exist locally first.

| Origin                           | Local tag              | Mirrored tag (`sync-` prefix) |
|----------------------------------|------------------------|-------------------------------|
| DHCP                             | `<lease-server>-<MAC>` | `sync-<lease-server>-<MAC>`   |
| L2TP/IPsec                       | `ppp-<username>:<ip>`  | `sync-ppp-<username>:<ip>`    |
| IKEv2                            | `ike-<username>:<ip>`  | `sync-ike-<username>:<ip>`    |
| WireGuard                        | `wg-<peername>:<ip>`   | `sync-wg-<peername>:<ip>`     |
| Plain static record (no comment) | --                     | `sync-static`                 |
| CNAME record                     | --                     | `sync-cname`                  |
| FWD forwarder record             | --                     | `sync-fwd`                    |

`match-subdomain` is carried over for both plain static and FWD records.

**Setup:** requires the SSH key setup above to be done first, then:

```routeros
/system/scheduler/add \
    name=remote-dns-sync \
    interval=1m \
    on-event="/system/script/run remote-dns-sync" \
    start-time=startup
```

---

## `static-updates/`

Scripts for maintaining static DNS records that reflect the current state of the network infrastructure. Intended to be
called from netwatch `on-event` hooks rather than on a fixed schedule.

---

### `static-updates/update-dns.rsc`

**Trigger:** Netwatch events for `check-yoba-dns` and `check-boba-dns`

Updates the upstream DNS server used by the hub. Switches to yoba as primary, falls back to boba if yoba is unreachable,
and falls back to `1.1.1.1` if both are down.

```
yoba (10.2.248.1) -> boba (10.2.216.1) -> 1.1.1.1
```

**Setup:** Assign to the `on-event` field of both netwatch entries:

```routeros
/tool/netwatch/set [find name="check-yoba-dns"] on-event="/system/script/run update-dns"
/tool/netwatch/set [find name="check-boba-dns"] on-event="/system/script/run update-dns"
```

---

### `static-updates/update-proxy-cnames.rsc`

**Trigger:** Netwatch events for proxy failover entries

Updates CNAME records for the two regional SOCKS5 proxy endpoints based on node availability:

- `spb.proxy.idlehive` -> `peka.idlehive` (primary) or `pepe.idlehive` (fallback)
- `ams.proxy.idlehive` -> `yoba.idlehive` (primary) or `boba.idlehive` (fallback)

**Setup:** Assign to the `on-event` field of the relevant netwatch entries:

```routeros
/tool/netwatch/set [find name="proxy-failover-peka"] on-event="/system/script/run update-proxy-cnames"
/tool/netwatch/set [find name="proxy-failover-pepe"] on-event="/system/script/run update-proxy-cnames"
/tool/netwatch/set [find name="proxy-failover-yoba"] on-event="/system/script/run update-proxy-cnames"
/tool/netwatch/set [find name="proxy-failover-boba"] on-event="/system/script/run update-proxy-cnames"
```

---

## Scaling to other nodes

All scripts are self-contained and write DNS records locally. To enable DNS registration on additional nodes (e.g. a
secondary WireGuard or IKEv2 endpoint), deploy the relevant scripts there and add the corresponding scheduler or PPP
profile hooks. As long as the hub forwards DNS queries to that node, the records will be resolvable network-wide without
any additional configuration. For nodes that also need to resolve hub-originated records locally (instead of relying on
DNS forwarding back to the hub), add `remote-dns-sync.rsc` to mirror the hub's table directly -- after completing the
SSH key setup for that node.
