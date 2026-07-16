:local netwatchNames
:local serverIPs

:set netwatchNames ($netwatchNames , "check-yoba-dns")
:set serverIPs ($serverIPs , "10.2.248.1")

:set netwatchNames ($netwatchNames , "check-boba-dns")
:set serverIPs ($serverIPs , "10.2.216.1")

:local chosen ""
:local i 0
:while ($i < [:len $netwatchNames] and $chosen = "") do={
    :local nwName ($netwatchNames->$i)
    :local ip ($serverIPs->$i)
    :if ([/tool/netwatch/get [find name=$nwName] status] = "up") do={
        :set chosen $ip
    }
    :set i ($i + 1)
}

:if ($chosen != "") do={
    /ip/dns/set servers=$chosen use-doh-server=""
} else={
    /ip/dns/set use-doh-server="https://cloudflare-dns.com/dns-query" verify-doh-cert=yes servers=1.1.1.1
}
