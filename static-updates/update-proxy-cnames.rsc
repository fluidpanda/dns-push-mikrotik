:local pekaUp ([/tool/netwatch/get [find name="proxy-failover-peka"] status] = "up")
:local pepeUp ([/tool/netwatch/get [find name="proxy-failover-pepe"] status] = "up")
:local yobaUp ([/tool/netwatch/get [find name="proxy-failover-yoba"] status] = "up")
:local bobaUp ([/tool/netwatch/get [find name="proxy-failover-boba"] status] = "up")

:if ($pekaUp) do={
    /ip/dns/static/set [find name="spb.proxy.idlehive"] cname=peka.idlehive
} else={
    :if ($pepeUp) do={
        /ip/dns/static/set [find name="spb.proxy.idlehive"] cname=pepe.idlehive
    }
}

:if ($yobaUp) do={
    /ip/dns/static/set [find name="ams.proxy.idlehive"] cname=yoba.idlehive
} else={
    :if ($bobaUp) do={
        /ip/dns/static/set [find name="ams.proxy.idlehive"] cname=boba.idlehive
    }
}
