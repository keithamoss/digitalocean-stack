# Troubleshooting slow performance when launching a world

Your NVMe link is downgraded to PCIe Gen2 x1 (5 GT/s, x1). That caps real throughput to ~400–450 MB/s and hurts small-file IOPS. On Pi 5 you should get Gen3 x1 (8 GT/s) if the adapter and cabling cooperate; on Pi 4 you’re stuck at Gen2 x1.

What to do:

Reseat/move the NVMe adapter; try a different slot/hat/ribbon; use the shortest ribbon you can.
If this is a Pi 5, enable Gen3 and retest: add dtparam=pciex1_gen=3 (or the vendor’s overlay) in config.txt, reboot, and re-check LnkSta (look for 8GT/s x1). If unstable, drop back to Gen2.
Test with a known-good USB3 SSD (ext4,noatime) as a comparison; if it’s faster on metadata, keep Foundry data there or fix the NVMe link.
Keep noatime; avoid sync. Optionally add nodiratime when remounting.
After adjusting hardware/overlay, rerun a quick metadata check in an empty dir on that filesystem:

```
mkdir -p /home/keith/digitalocean-stack/foundry/data/_meta_test
sudo fio --name=meta --directory=/home/keith/digitalocean-stack/foundry/data/_meta_test \
  --numjobs=4 --size=8M --filesize=4k --nrfiles=2000 --rw=randread --bs=4k \
  --iodepth=16 --direct=1 --runtime=30 --time_based --group_reporting --eta=always --status-interval=5
rm -rf /home/keith/digitalocean-stack/foundry/data/_meta_test
```

If Gen3 x1 or a USB3 SSD yields much better metadata throughput, migrating Foundry’s Data there should speed up “Launch game.”