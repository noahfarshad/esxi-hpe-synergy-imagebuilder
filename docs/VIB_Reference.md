# HPE Synergy AddOn VIB Reference

The HPE Synergy AddOn depot contains VIBs from multiple vendors — not all are labeled "HPE." When validating a merged image, expect to see VIBs tagged with vendor codes like QLC (QLogic), BCM (Broadcom), MIS (Microsemi), MVL (Marvell), and INT (Intel), in addition to HPE's own management VIBs.

This table documents the VIBs in the `HPE-Custom-Syn-AddOn` (version `900.0.0.12.3.5-5`) at the time of writing. Your specific AddOn version may differ slightly — always run `Validate-IsoVibs.ps1` against your actual depots to get the authoritative list.

| VIB Name | Vendor | Purpose |
|---|---|---|
| `qcnic` | QLC | QLogic Converged Network Adapter (FC/FCoE) |
| `qlnativefc` | MVL | Marvell/QLogic native Fibre Channel driver |
| `qedf` | QLC | QLogic FCoE driver |
| `qedi` | QLC | QLogic iSCSI driver |
| `qfle3` / `qfle3f` / `qfle3i` | QLC | QLogic FastLinQ Ethernet drivers |
| `qedentv` / `qedrntv` | QLC | QLogic Enhanced Ethernet / RoCE drivers |
| `bnxtnet` | BCM | Broadcom NetXtreme Ethernet |
| `bnxtroce` | BCM | Broadcom RoCE driver |
| `storcli` | BCM | Broadcom StorCLI management utility |
| `lsi-mr3` | BCM | Broadcom MegaRAID SAS driver |
| `smartpqi` | MIS | Microsemi Smart Storage PQI driver |
| `ssacli2` | MIS | HPE Smart Storage Administrator CLI |
| `icen` / `igbn` / `ixgben` / `i40en` | INT | Intel network drivers |
| `amsd` / `amsdv` | HPE | HPE Agentless Management Service |
| `ilo` / `ilorest` | HPE | HPE iLO driver and RESTful interface |
| `sut` | HPE | HPE Smart Update Tools |
| `hpe-upgrade-syn` | HPE | HPE Synergy upgrade utility |

## Why the FC drivers matter for SAN boot

HPE Synergy compute modules in a boot-from-SAN configuration depend on the Fibre Channel drivers (`qlnativefc`, `qcnic`, `qedf`) being present in the installer. The generic VMware base ISO does not include these. Without them, the ESXi installer enumerates zero storage devices and you cannot select an install target — the boot LUN is invisible.

This is the entire reason a custom ISO is needed for SAN-boot Synergy blades: the base image plus the HPE AddOn's FC drivers makes the boot LUN visible at install time.

## The driver that bit people on 7.0 U3 (a cautionary note)

HPE's own release notes flag a real-world gotcha worth knowing about: on ESXi 7.0 U3, a custom image revision (`703.0.0.11.7.5.6`) shipped an updated `lpfc` driver that **dropped support** for the HPE Synergy 3530C 16G FC HBA. In a boot-from-SAN configuration, upgrading to that image resulted in loss of FC LUN access — the system would stop booting.

The lesson generalizes: a custom image's FC driver version is load-bearing for SAN-boot hosts. Always validate that the FC driver in your built image actually supports the HBAs in your specific blades before rolling it out fleet-wide. Test on one host, confirm the boot LUN survives a reboot, then proceed.
