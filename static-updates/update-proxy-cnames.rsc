:local applyFailover do={
    :local n [:len $checks]
    :local i 0
    :local chosen ""
    :while ($i < $n and $chosen = "") do={
        :local nwName ($checks->$i)
        :local node ($nodes->$i)
        :if ([/tool/netwatch/get [find name=$nwName] status] = "up") do={
            :set chosen $node
        }
        :set i ($i + 1)
    }
    :if ($chosen != "") do={
        /ip/dns/static/set [find name=$record] cname=($chosen . ".idlehive")
        :log info ("update-proxy-cnames: " . $record . " -> " . $chosen . ".idlehive")
    }
}

:local spbChecks
:local amsChecks
:set spbChecks ($spbChecks , "proxy-failover-peka")
:set spbChecks ($spbChecks , "proxy-failover-pepe")
:set amsChecks ($amsChecks , "proxy-failover-yoba")
:set amsChecks ($amsChecks , "proxy-failover-boba")

:local spbNodes
:set spbNodes ($spbNodes , "peka")
:set spbNodes ($spbNodes , "pepe")
$applyFailover record="spb.proxy.idlehive" checks=$spbChecks nodes=$spbNodes

:local amsNodes
:set amsNodes ($amsNodes , "yoba")
:set amsNodes ($amsNodes , "boba")
$applyFailover record="ams.proxy.idlehive" checks=$amsChecks nodes=$amsNodes
