:local domain ".CHANGE_ME"
:local prefix "ike-"

:foreach lease in=[/ip/pool/used/find where owner="IPsec"] do={
    :local peerIP [/ip/pool/used/get $lease address]
    :local info [/ip/pool/used/get $lease info]
    :local commaPos [:find $info ", "]
    :local peerExt [:pick $info 0 $commaPos]
    :local peerName [:pick $info ($commaPos + 2) [:len $info]]
    :local fqdn ($peerName . $domain)
    :local tag ($prefix . $peerName)
    :local comment ($tag . ":" . $peerExt)

    :local existing [/ip/dns/static/find where comment~$tag]
    :if ([:len $existing] > 0) do={
        :local currentIP [/ip/dns/static/get ($existing->0) address]
        :if ($currentIP != $peerIP) do={
            /ip/dns/static/remove $existing
            /ip/dns/static/add name=$fqdn address=$peerIP comment=$comment ttl=00:01:00
        }
    } else={
        /ip/dns/static/add name=$fqdn address=$peerIP comment=$comment ttl=00:01:00
    }
}

:foreach rec in=[/ip/dns/static/find where comment~$prefix] do={
    :local recComment [/ip/dns/static/get $rec comment]
    :local recName [:pick $recComment [:len $prefix] [:find $recComment ":"]]
    :local active [/ip/pool/used/find where owner="IPsec" info~$recName]
    :if ([:len $active] = 0) do={
        :local recFqdn [/ip/dns/static/get $rec name]
        /ip/dns/static/remove $rec
    }
}
