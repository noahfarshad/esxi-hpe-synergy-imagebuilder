#!/bin/sh
# post-install-validation.sh
#
# Run this ON THE ESXI HOST (via SSH) after installing from the custom ISO to
# confirm the HPE Synergy drivers actually loaded. If the FC/storage drivers
# are present, the host will see its SAN boot LUN and HPE management tooling.
#
# Usage (on the ESXi host shell):
#   sh post-install-validation.sh
# or just run the esxcli line directly.

echo "=== HPE Synergy driver / management VIBs present on this host ==="
esxcli software vib list | grep -i -E "qcnic|bnxt|storcli|amsd|ilo|ssacli|qlnativefc|smartpqi"

echo ""
echo "=== Storage adapters seen by ESXi ==="
esxcli storage core adapter list

echo ""
echo "=== FC/SAN HBA links (if booting from SAN, you want these UP) ==="
esxcli storage san fc list 2>/dev/null || echo "  (no FC HBAs reported - check driver load if this is a SAN-boot host)"

echo ""
echo "If the grep above returned the expected driver VIBs and your boot LUN is"
echo "visible under 'storage core adapter list', the custom ISO did its job."
