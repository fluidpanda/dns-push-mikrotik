:local dnsttl "1d 00:00:00";
:local faceUrl "https://CHANGE_ME/rest/ip/dns/static";
:local faceUser "CHANGE_ME";
:local facePass "CHANGE_ME";

# "a.b.c.d" -> "a-b-c-d"
:local ip2Host do={
    :local outStr
    :for i from=0 to=([:len $inStr] - 1) do={
        :local tmp [:pick $inStr $i];
        :if ($tmp =".") do={
            :set tmp "-"
        }
        :set outStr ($outStr . $tmp)
    }
    :return $outStr
}

# param: name
# max length = 63
# allowed chars a-z,0-9,-
:local mapHostName do={
    :local allowedChars "abcdefghijklmnopqrstuvwxyz0123456789-";
    :local numChars [:len $name];
    :if ($numChars > 63) do={:set numChars 63};
    :local result "";

    :for i from=0 to=($numChars - 1) do={
        :local char [:pick $name $i];
        :if ([:find $allowedChars $char] < 0) do={:set char "-"};
        :set result ($result . $char);
    }
    :return $result;
}

# param: entry
:local lowerCase do={
    :local lower "abcdefghijklmnopqrstuvwxyz";
    :local upper "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    :local result "";
    :for i from=0 to=([:len $entry] - 1) do={
        :local char [:pick $entry $i];
        :local pos [:find $upper $char];
        :if ($pos > -1) do={:set char [:pick $lower $pos]};
        :set result ($result . $char);
    }
    :return $result;
}

:local faceAdd do={
    # params: url, user, pass, fqdn, ip, ttl, token
    :do {
        /tool/fetch url=$url http-method=put check-certificate=no \
            http-header-field="Content-Type:application/json" \
            http-data="{\"name\":\"$fqdn\",\"address\":\"$ip\",\"ttl\":\"$ttl\",\"comment\":\"$token\"}" \
            user=$user password=$pass output=none;
    } on-error={ :log warning "face DNS add failed: $fqdn" }
}

:local faceRemove do={
    # params: url, user, pass, token
    :do {
        :local res [/tool/fetch url="$url?comment=$token" http-method=get \
            user=$user password=$pass check-certificate=no output=user as-value];
        :foreach row in=[:deserialize ($res->"data") from=json] do={
            :local id ($row->".id");
            /tool/fetch url="$url/$id" http-method=delete \
                user=$user password=$pass check-certificate=no output=none;
        }
    } on-error={ :log warning "face DNS remove failed: $token" }
}

:local token "$leaseServerName-$leaseActMAC";
:local LogPrefix "script ($leaseServerName)"

:if ( [ :len $leaseActIP ] <= 0 ) do={
    :log error "$LogPrefix: empty lease address"
    :error "empty lease address"
}

:if ( $leaseBound = 1 ) do={
    # new DHCP lease added
    /ip dhcp-server network
    #:local dnsttl [ get [ find name=$leaseServerName ] lease-time ]
    :local domain [ get [ find $leaseActIP in address ] domain ]
    #:log info "$LogPrefix: DNS domain is $domain"

    :local hostname [/ip dhcp-server lease get [:pick [find mac-address=$leaseActMAC and server=$leaseServerName] 0] value-name=host-name]
    #:log info "$LogPrefix: DHCP hostname is $hostname"

    #Hostname cleanup
    :if ( [ :len $hostname ] <= 0 ) do={
        :set hostname [ $ip2Host inStr=$leaseActIP ]
        :log info "$LogPrefix: Empty hostname for '$leaseActIP', using generated host name '$hostname'"
    }

    :set hostname [$lowerCase entry=$hostname]
    :set hostname [$mapHostName name=$hostname]
    #:log info "$LogPrefix: Clean hostname for FQDN is $hostname";

    :if ( [ :len $domain ] <= 0 ) do={
        :log warning "$LogPrefix: Empty domainname for '$leaseActIP', cannot create static DNS name"
        :error "Empty domainname for '$leaseActIP'"
    }

    :local fqdn ($hostname . "." .  $domain)
    #:log info "$LogPrefix: FQDN for DNS is $fqdn"

    :if ([/ip dhcp-server lease get [:pick [find mac-address=$leaseActMAC and server=$leaseServerName] 0] ]) do={
        # :log info message="$LogPrefix: $leaseActMAC -> $hostname"
        /ip dns static remove [find comment=$token];
        :do {
            /ip dns static add address=$leaseActIP name=$fqdn ttl=$dnsttl comment=$token;
            $faceRemove url=$faceUrl user=$faceUser pass=$facePass token=$token;
            $faceAdd url=$faceUrl user=$faceUser pass=$facePass fqdn=$fqdn ip=$leaseActIP ttl=$dnsttl token=$token;
        } on-error={
            :log error message="$LogPrefix: Failure during dns registration of $fqdn with $leaseActIP"
        }
    }
} else={
    :local stillBound [/ip dhcp-server lease find mac-address=$leaseActMAC status=bound server=$leaseServerName]
    :if ([:len $stillBound] = 0) do={
        /ip dns static remove [find comment=$token];
        $faceRemove url=$faceUrl user=$faceUser pass=$facePass token=$token;
    } else={
        :log info "$LogPrefix: skipping DNS removal, $leaseActMAC still has active lease"
    }
}
