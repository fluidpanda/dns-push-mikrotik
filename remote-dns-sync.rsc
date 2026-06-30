:local faceUrl "https://CHANGE_ME/rest/ip/dns/static"
:local faceFwdUrl "https://CHANGE_ME/rest/ip/dns/forwarders"
:local faceUser "CHANGE_ME"
:local facePass "CHANGE_ME"
:local dnsttl "00:01:00"
:local pushPrefixes {"ppp-";"ike-";"wg-"}

# Fetch the full list of DNS records from face (single round trip)
:local faceData
:do {
    :local res [/tool/fetch url=$faceUrl http-method=get user=$faceUser password=$facePass \
        check-certificate=no output=user as-value]
    :set faceData [:deserialize ($res->"data") from=json]
} on-error={
    :log warning "remote-dns-sync: failed to fetch face dns list, aborting"
    :error "face fetch failed"
}

:local localNames

# Phase 0: sync forwarder profiles from face (FWD static records reference these by name)
:do {
    :local res [/tool/fetch url=$faceFwdUrl http-method=get user=$faceUser password=$facePass \
        check-certificate=no output=user as-value]
    :local faceFwdData [:deserialize ($res->"data") from=json]

    :foreach frow in=$faceFwdData do={
        :local fname ($frow->"name")
        :local fservers ($frow->"dns-servers")
        :local existing [/ip/dns/forwarders/find where name=$fname]

        :if ([:len $existing] > 0) do={
            :local curServers [/ip/dns/forwarders/get ($existing->0) dns-servers]
            :if ($curServers != $fservers) do={
                /ip/dns/forwarders/set ($existing->0) dns-servers=$fservers
                :log info ("remote-dns-sync: updated forwarder profile " . $fname . " -> " . $fservers)
            }
        } else={
            /ip/dns/forwarders/add name=$fname dns-servers=$fservers
            :log info ("remote-dns-sync: added forwarder profile " . $fname)
        }
    }
} on-error={
    :log warning "remote-dns-sync: failed to sync forwarder profiles from face"
}

# Phase 1: collect every local-origin record name (regardless of type), and push
# remote-client records (ppp-/ike-/wg-) to face since a local connection wins
:foreach rec in=[/ip/dns/static/find] do={
    :local c [/ip/dns/static/get $rec comment]
    :local n [/ip/dns/static/get $rec name]
    :local a [/ip/dns/static/get $rec address]

    :if ([:len $c] < 5 or [:pick $c 0 5] != "sync-") do={
        :set localNames ($localNames , $n)

        :foreach p in=$pushPrefixes do={
            :if ([:pick $c 0 [:len $p]] = $p) do={
                :do {
                    :foreach frow in=$faceData do={
                        :if (($frow->"name") = $n) do={
                            :local id ($frow->".id")
                            /tool/fetch url="$faceUrl/$id" http-method=delete \
                                user=$faceUser password=$facePass check-certificate=no output=none
                        }
                    }
                    /tool/fetch url=$faceUrl http-method=put check-certificate=no \
                        http-header-field="Content-Type:application/json" \
                        http-data="{\"name\":\"$n\",\"address\":\"$a\",\"ttl\":\"$dnsttl\",\"comment\":\"$c\"}" \
                        user=$faceUser password=$facePass output=none
                    :log info ("remote-dns-sync: pushed " . $n . " -> " . $a . " to face")
                } on-error={
                    :log warning ("remote-dns-sync: push to face failed for " . $n)
                }
            }
        }
    }
}

# Phase 2a: pull regular records (A) we don't already have locally
:foreach frow in=$faceData do={
    :local fn ($frow->"name")
    :local ftype ($frow->"type")
    :local fa ($frow->"address")
    :local fc ($frow->"comment")
    :local fms ($frow->"match-subdomain")

    :if ($ftype != "FWD") do={
        :local isLocal false
        :foreach ln in=$localNames do={
            :if ($ln = $fn) do={ :set isLocal true }
        }

        :if (!$isLocal and [:len $fa] > 0) do={
            :local syncComment "sync-static"
            :if ([:len $fc] > 0) do={ :set syncComment ("sync-" . $fc) }
            :local existing [/ip/dns/static/find where name=$fn and comment~"^sync-"]

            :if ([:len $existing] > 0) do={
                :local curAddr [/ip/dns/static/get ($existing->0) address]
                :local curMs [/ip/dns/static/get ($existing->0) match-subdomain]
                :if ($curAddr != $fa or $curMs != $fms) do={
                    /ip/dns/static/remove $existing
                    /ip/dns/static/add name=$fn address=$fa ttl=$dnsttl match-subdomain=$fms comment=$syncComment
                    :log info ("remote-dns-sync: updated " . $fn . " -> " . $fa)
                }
            } else={
                /ip/dns/static/add name=$fn address=$fa ttl=$dnsttl match-subdomain=$fms comment=$syncComment
                :log info ("remote-dns-sync: added " . $fn . " -> " . $fa)
            }
        }
    }
}

# Phase 2b: pull forwarder records (FWD) we don't already have locally.
# Runs after 2a so any plain records the forwarders might depend on already exist.
:foreach frow in=$faceData do={
    :local fn ($frow->"name")
    :local ftype ($frow->"type")
    :local fc ($frow->"comment")
    :local ffwd ($frow->"forward-to")
    :local fms ($frow->"match-subdomain")

    :if ($ftype = "FWD") do={
        :local isLocal false
        :foreach ln in=$localNames do={
            :if ($ln = $fn) do={ :set isLocal true }
        }

        :if (!$isLocal) do={
            :local syncComment "sync-fwd"
            :local existing [/ip/dns/static/find where name=$fn and comment~"^sync-"]

            :if ([:len $existing] > 0) do={
                :local curFwd [/ip/dns/static/get ($existing->0) forward-to]
                :if ($curFwd != $ffwd) do={
                    /ip/dns/static/remove $existing
                    /ip/dns/static/add name=$fn type=FWD forward-to=$ffwd match-subdomain=$fms comment=$syncComment
                    :log info ("remote-dns-sync: updated forwarder " . $fn . " -> " . $ffwd)
                }
            } else={
                /ip/dns/static/add name=$fn type=FWD forward-to=$ffwd match-subdomain=$fms comment=$syncComment
                :log info ("remote-dns-sync: added forwarder " . $fn . " -> " . $ffwd)
            }
        }
    }
}

# Phase 3: clean up stale sync mirrors (gone from face, or superseded by a local record)
:foreach rec in=[/ip/dns/static/find where comment~"^sync-"] do={
    :local n [/ip/dns/static/get $rec name]

    :local stillOnFace false
    :foreach frow in=$faceData do={
        :if (($frow->"name") = $n) do={ :set stillOnFace true }
    }

    :local nowLocal false
    :foreach ln in=$localNames do={
        :if ($ln = $n) do={ :set nowLocal true }
    }

    :if (!$stillOnFace or $nowLocal) do={
        /ip/dns/static/remove $rec
        :log info ("remote-dns-sync: removed stale sync entry " . $n)
    }
}
