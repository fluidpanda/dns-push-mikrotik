:global remoteDomain
:if ([:len $remoteDomain] = 0) do={
    /system/script/run globals
}

:local fqdn ($user . "." . $remoteDomain)
:local tag ("ppp-" . $user)
:local comment ($tag . ":" . $"caller-id")
:local ip $"remote-address"
:local dnsttl "00:01:00"

:foreach r in=[/ip/dns/static/find where comment~("^" . $tag)] do={
    /ip/dns/static/remove $r
}

/ip/dns/static/add name=$fqdn address=$ip comment=$comment ttl=$dnsttl
