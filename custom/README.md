# Custom NSS build for the NEC Aterm WG2600HP

This branch is an OpenWrt 24.10.8 build with NSS offloading for the first
generation NEC Aterm WG2600HP (IPQ8064). It is based on tingalvin/r7800, with a
few fixes and a newer tailscale.

- Base: [tingalvin/r7800](https://github.com/tingalvin/r7800), branch
  `r7800-24.10.8`, commit `9ed69189b8` (OpenWrt 24.10.8 `r29233-443ec4032a`,
  kernel 6.6.144).
- Feeds: pinned to fixed commits (`custom/feeds.conf`). `lang/golang` and
  `net/tailscale` come from a newer openwrt/packages commit
  (`custom/patches/packages/`).
- Images: see the Releases page of this repository.

## Changes from the base

| # | Change | Where |
|---|---|---|
| 1 | qca-nss-ecm: start the standard profile at boot, work with firewall4 | commit on this branch |
| 2 | qca-nss-ecm: `accel_delay_pkts` 1 → 24 | commit on this branch |
| 3 | qca-nss-clients tunipip6: fix the dst leak in the encap exception path | commit on this branch |
| 4 | qca-nss-ecm: enable interface features only for kmods built into the image | commit on this branch |
| 5 | Image: check that the sysupgrade image fits (24192k) | commit on this branch |
| 6 | Go 1.27 and tailscale 1.104.1 from openwrt/packages master | `custom/patches/packages/` (applied to the packages feed) |
| 7 | First-boot defaults for NSS | `custom/files/wg2600hp/etc/uci-defaults/98-wg2600hp-nss-defaults` |
| 8 | Config: WG2600HP only, package selection, `CONFIG_ALL_KMODS=y` | `custom/configs/wg2600hp.config` |

### 1. ECM start-up and firewall4

- `kmod-qca-nss-ecm-standard` now depends on `iptables-nft` and
  `iptables-mod-physdev`, which its firewall script uses.
- Its init script is installed as an `rc.common` script, so ECM starts at boot.
- The firewall include is registered as `fw4_compatible`. It starts ECM, in
  case the firewall comes up first, and flushes the accelerated connections
  after a firewall reload.
- The bridge netfilter sysctls are written to
  `/etc/sysctl.d/99-qca-nss-ecm.conf`, so they are applied after the
  defaults.

### 2. `accel_delay_pkts=24`

ECM handles the first `accel_delay_pkts` packets of each connection on the CPU
and then passes the connection to NSS.

- With the original `1`, ECM does not accelerate non-TCP connections until it
  has seen packets in both directions. DS-Lite, MAP-E and one-way UDP therefore
  stayed on the CPU.
- With `24`, NSS handles all of these.

Notes:

- On other NSS builds, values other than `1` were seen to stall upstream UDP
  on MAP-E when a translated port was reused. This was not seen on the
  WG2600HP. If it happens, set the value back to `1` and check again.
- Any value other than `1` applies the DSCP and mark seen in one direction to
  both directions. This can affect QoS classification and mwan3 or policy
  routing marks.
- To change the value, edit the `echo 24 > .../accel_delay_pkts` line in
  `load_ecm()` of `/etc/init.d/qca-nss-ecm`, then run
  `/etc/init.d/qca-nss-ecm restart`. A sysupgrade restores 24.

### 3. tunipip6 (DS-Lite/MAP-E) dst leak

This is the upstream Qualcomm fix (qca-nss-clients `ec7a57b`). It releases the
route looked up in `nss_tunipip6_encap_exception()`. Without it, every such
packet leaks a dst entry, and `ip_dst_cache` grows without bound.

### 4. ECM features and `CONFIG_ALL_KMODS`

`CONFIG_ALL_KMODS=y` builds every kmod, so that kmods can be added later. It
also turns `kmod-sit`, `kmod-pppol2tp`, `kmod-macvlan` and `kmod-ipsec` into
`=m`. The original Makefile then built ECM with features that the NSS driver
of this tree does not have, and the build failed. ECM now enables those
features only for kmods that are built into the image (`=y`).

### 5. Image size check

The sysupgrade image must fit the firmware partitions (24192k). With this
check, an image that is too large fails the build instead of being produced.

### 6. Go and tailscale

The openwrt-24.10 packages feed has tailscale 1.80.3. tailscale 1.104.1
needs Go 1.27, so `lang/golang` and `net/tailscale` are taken from
openwrt/packages master (commit `70ac3a84`) and applied to the pinned feed. See
[tailscale](#tailscale) below.

### 7. First-boot defaults

On the first boot, `98-wg2600hp-nss-defaults` makes these settings:

- Turns off the firewall's software and hardware flow offloading. These are
  not NSS switches, and with software flow offloading on, IPv4 and PPPoE
  traffic bypasses NSS.
- Turns off packet steering.
- Sets the ECM acceleration engine to `nss`.

### 8. Config

The config contains the following:

| Area | Packages and settings |
|---|---|
| Device | ipq806x / generic / NEC WG2600HP |
| Switch and Ethernet | swconfig, qca-nss-gmac |
| Offloading | qca-nss-drv, qca-nss-ecm-standard, NSS PPPoE and tunipip6 clients |
| WAN | PPPoE, DS-Lite, MAP-E (`map`), odhcp6c |
| VPN | WireGuard (`kmod-wireguard`, `wireguard-tools`, `luci-proto-wireguard`), tailscale |
| Management and monitoring | LuCI, conntrack, `collectd`, `luci-app-statistics`, `collectd-mod-sensors` |
| Wireless | QCA99x0 board data, ath10k-ct |
| Build | `CONFIG_ALL_KMODS=y`; `CONFIG_KERNEL_BUILD_USER="builder"` and `CONFIG_KERNEL_BUILD_DOMAIN="buildhost"` |

`CONFIG_ALL_KMODS=y` alone would also select some NSS-related kmods and change
the NSS driver and ECM that go into the image. The config disables them. This
covers `kmod-bonding` and the kmods that select it (`kmod-qca-mcs` and the
other ECM variant), and the optional NSS feature kmods (crypto, qdisc, L2TP,
6rd, ...). These NSS kmods cannot be added later.

## tailscale

- The image includes tailscale 1.104.1 (`tailscale` and `tailscaled`, about
  28 MB unpacked). tailscale is licensed under the BSD-3-Clause license; see
  its [LICENSE](https://github.com/tailscale/tailscale/blob/v1.104.1/LICENSE).
  This build is not affiliated with Tailscale Inc.
- The image contains no tailscale login or state. `tailscaled` starts at boot
  but is not logged in. Run `tailscale up` on the router and log in with the
  URL it prints.
- The version is fixed when the image is built. It cannot be updated on the
  router: the official 24.10 package is older, and there is no room in the
  overlay. To update tailscale, rebuild the image (see below) and run
  `sysupgrade` without `-n`. This keeps `/etc/config` and the tailscale login
  in `/etc/tailscale`.

### Updating tailscale in a build

1. Take `net/tailscale` (and `lang/golang`, if the new version needs a newer Go)
   from a newer openwrt/packages master commit.
2. Copy them into `feeds/packages`.
3. Run `./scripts/feeds update -i packages`, `./scripts/feeds install -a` and
   `make defconfig`.
4. Build.

```sh
git clone --filter=blob:none --no-checkout https://github.com/openwrt/packages.git packages-master
git -C packages-master sparse-checkout set --no-cone lang/golang net/tailscale
git -C packages-master checkout <commit>
rsync -a --delete packages-master/lang/golang/ feeds/packages/lang/golang/
rsync -a --delete packages-master/net/tailscale/ feeds/packages/net/tailscale/
./scripts/feeds update -i packages && ./scripts/feeds install -a && make defconfig && make
```

### Building without tailscale

1. In `custom/configs/wg2600hp.config`, replace

   ```
   CONFIG_PACKAGE_tailscale=y
   ```

   with

   ```
   # CONFIG_PACKAGE_tailscale is not set
   ```

2. Build as below.

Go is then not built at all, which saves most of the build time, and the image
is much smaller. The packages feed patch can stay applied; it only replaces the
package definitions.

## Building

On a host that can build OpenWrt (see the OpenWrt build system documentation):

```sh
git clone -b custom/r7800-24.10.8 https://github.com/<this repository>.git openwrt
cd openwrt
custom/build.sh wg2600hp -j$(nproc)
```

`custom/build.sh` does the following:

1. Sets `LC_ALL=C`, because the prerequisite checks parse English output.
2. Writes `feeds.conf` from `custom/feeds.conf` and updates the feeds.
3. Applies `custom/patches/packages/` to the packages feed (only once).
4. Installs the feeds.
5. Puts `custom/files/wg2600hp` in place as `files/`.
6. Copies the config to `.config`.
7. Runs `make defconfig`, `make download` and `make`.

The image is in `bin/targets/ipq806x/generic/`. Building Go from source takes a
while.

## Installing

These steps apply to a WG2600HP that already runs OpenWrt. For the first
installation from the NEC stock firmware (serial console and TFTP), see the
[OpenWrt wiki page for the WG2600HP](https://openwrt.org/toh/hwdata/nec/nec_aterm_wg2600hp).

**Install without keeping settings (`sysupgrade -n`).** Official OpenWrt
releases such as 25.12 use DSA, and this image uses swconfig, so their network
configuration is not compatible. Packages added to an older build can also
clash with the image.

```sh
ssh root@192.168.1.1 'sysupgrade -b /tmp/backup.tar.gz && cat /tmp/backup.tar.gz' > backup-before.tar.gz
cat openwrt-ipq806x-generic-nec_wg2600hp-squashfs-sysupgrade.bin | ssh root@192.168.1.1 'cat > /tmp/fw.bin'
ssh root@192.168.1.1 'sha256sum /tmp/fw.bin; sysupgrade -T /tmp/fw.bin && echo OK'
ssh root@192.168.1.1 'sysupgrade -n /tmp/fw.bin'
```

The router then starts in the default state:

- LAN address 192.168.1.1
- no root password
- wireless disabled

Set a root password first. To check that NSS is working:

```sh
dmesg | grep -E "nss core [01] booted"
lsmod | grep -E "^(ecm|qca_nss_drv|qca_nss_gmac|qca_nss_pppoe|qca_nss_tunipip6) "
cat /sys/kernel/debug/ecm/ecm_classifier_default/accel_delay_pkts    # 24
```

## Notes

- Do not turn on software or hardware flow offloading in LuCI. Leave packet
  steering off. SQM (`sqm-scripts`) runs on the CPU and bypasses NSS.
- You can add other packages (`opkg install`) from the official 24.10.8 feeds.
  The exception is kernel modules (`kmod-*`): the official ones do not match
  this kernel, so use the ones from your own build of this branch
  (`bin/targets/ipq806x/generic/packages/`).
- The overlay has about 6.8 MiB free.

This image was tested on one WG2600HP only. Use it at your own risk.

## License

Same as OpenWrt and the respective packages (mostly GPL-2.0). The patches in this
branch are under the license of the files they modify.
