:local yobaUp ([/tool/netwatch/get [find name="check-yoba-dns"] status] = "up")
:local bobaUp ([/tool/netwatch/get [find name="check-boba-dns"] status] = "up")

:if ($yobaUp) do={
    /ip/dns/set servers=10.2.248.1
} else={
    :if ($bobaUp) do={
        /ip/dns/set servers=10.2.216.1
    } else={
        /ip/dns/set servers=1.1.1.1
    }
}
