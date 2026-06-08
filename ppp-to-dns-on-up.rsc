:local fqdn ($user . ".CHANGE_ME")
:local tag ("ppp-" . $user)
:local comment ($tag . ":" . $"caller-id")
:local ip $"remote-address"

:foreach r in=[/ip/dns/static/find where comment~$tag] do={
    /ip/dns/static/remove $r
}

/ip/dns/static/add name=$fqdn address=$ip comment=$comment ttl=00:01:00
