:global remoteDomain
:if ([:len $remoteDomain] = 0) do={
    /system/script/run globals
}

:local fqdn ($user . "." . $remoteDomain)
:local tag ("ppp-" . $user)

:foreach r in=[/ip/dns/static/find where comment~("^" . $tag)] do={
    /ip/dns/static/remove $r
}
:log info ("removed " . $fqdn)
