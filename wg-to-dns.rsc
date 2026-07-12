:global remoteDomain
:if ([:len $remoteDomain] = 0) do={
    /system/script/run globals
}

:local prefix "wg-"
:local threshold 185
:local dnsttl "00:01:00"

:foreach peer in=[/interface/wireguard/peers/find] do={
    :local peerName [/interface/wireguard/peers/get $peer name]
    :local lastHS [/interface/wireguard/peers/get $peer last-handshake]
    :local allowedAddr [/interface/wireguard/peers/get $peer allowed-address]
    :local peerExt [/interface/wireguard/peers/get $peer current-endpoint-address]
    :local allowedStr [:tostr $allowedAddr]
    :local peerIP [:pick $allowedStr 0 [:find $allowedStr "/"]]
    :local fqdn ($peerName . "." . $remoteDomain)
    :local tag ($prefix . $peerName)
    :local comment ($tag . ":" . $peerExt)

    :local existing [/ip/dns/static/find where comment~("^" . $tag)]

    :if ($lastHS > 0 and $lastHS < $threshold) do={
        :if ([:len $existing] = 0) do={
            /ip/dns/static/add name=$fqdn address=$peerIP comment=$comment ttl=$dnsttl
        }
    } else={
        :if ([:len $existing] > 0) do={
            /ip/dns/static/remove $existing
            :log info ("removed: " . $fqdn)
        }
    }
}
