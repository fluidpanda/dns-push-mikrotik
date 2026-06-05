:local scriptName "dhcp-to-dns";

:do {
    :local scriptObj [:parse [/system script get $scriptName source]]
    $scriptObj leaseBound=$leaseBound leaseServerName=$leaseServerName leaseActIP=$leaseActIP leaseActMAC=$leaseActMAC
} on-error={ :log warning "DHCP server '$leaseServerName' lease script error" };
