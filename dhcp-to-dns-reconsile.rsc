:global faceHost
:global faceSshUser
:global needDhcpToDnsPush
:global dhcpDnsTtl
:global dhcpDnsPushed

:if ([:len $faceHost] = 0) do={
    /system/script/run globals
}
:if ([:typeof $dhcpDnsPushed] = "nothing") do={
    :set dhcpDnsPushed [:toarray ""]
}

:if ($needDhcpToDnsPush) do={

    # same normalization as the lease-script - keep in sync if that one changes
    :local ip2Host do={
        :local outStr
        :for i from=0 to=([:len $inStr] - 1) do={
            :local tmp [:pick $inStr $i]
            :if ($tmp = ".") do={ :set tmp "-" }
            :set outStr ($outStr . $tmp)
        }
        :return $outStr
    }
    :local mapHostName do={
        :local allowedChars "abcdefghijklmnopqrstuvwxyz0123456789-"
        :local numChars [:len $name]
        :if ($numChars > 63) do={ :set numChars 63 }
        :local result ""
        :for i from=0 to=($numChars - 1) do={
            :local char [:pick $name $i]
            :if ([:find $allowedChars $char] < 0) do={ :set char "-" }
            :set result ($result . $char)
        }
        :return $result
    }
    :local lowerCase do={
        :local lower "abcdefghijklmnopqrstuvwxyz"
        :local upper "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        :local result ""
        :for i from=0 to=([:len $entry] - 1) do={
            :local char [:pick $entry $i]
            :local pos [:find $upper $char]
            :if ($pos > -1) do={ :set char [:pick $lower $pos] }
            :set result ($result . $char)
        }
        :return $result
    }

    :local pendingCmd ""
    :local pendingIps [:toarray ""]
    :local pendingCount 0

    :foreach lease in=[/ip dhcp-server lease find status="bound"] do={
        :local ip [/ip dhcp-server lease get $lease address]
        :local mac [/ip dhcp-server lease get $lease mac-address]
        :local server [/ip dhcp-server lease get $lease server]
        :local token ($server . "-" . $mac)

        :local domain [/ip dhcp-server network get [find $ip in address] domain]
        :if ([:len $domain] > 0) do={
            :local hostname [/ip dhcp-server lease get $lease host-name]
            :if ([:len $hostname] = 0) do={
                :set hostname [$ip2Host inStr=$ip]
            }
            :set hostname [$mapHostName name=[$lowerCase entry=$hostname]]
            :local fqdn ($hostname . "." . $domain)

            :if (($dhcpDnsPushed->$token) != $ip) do={
                :set ($pendingIps->$token) $ip
                :set pendingCount ($pendingCount + 1)
                :set pendingCmd ($pendingCmd . "/ip/dns/static/remove [find comment=" . $token . "]; " . \
                    "/ip/dns/static/add name=" . $fqdn . " address=" . $ip . \
                    " ttl=\"" . $dhcpDnsTtl . "\" comment=" . $token . "; ")
            }
        }
    }

    :if ($pendingCount > 0) do={
        :do {
            /system/ssh-exec address=$faceHost user=$faceSshUser command=$pendingCmd
            :foreach token,ip in=$pendingIps do={
                :set ($dhcpDnsPushed->$token) $ip
            }
            :log info ("dhcp-to-dns-reconcile: pushed " . $pendingCount . " record(s) to face")
        } on-error={
            :log warning "dhcp-to-dns-reconcile: batch push to face failed, will retry next run"
        }
    }
}
