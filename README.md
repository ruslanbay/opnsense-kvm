```
+------------------------------+
|      Host Machine            |
|                              |
|  +---------------------+     |
|  |   OPNsense VM       |     |
|  |                     |     |
|  |  +-----+   +-----+  |     |
|  |  | LAN |   | WAN |  |     |
|  |  +--+--+   +--+--+  |     |
|  |     |         |     |     |
|  +-----|---------|-----+     |
|        |         |           |
|        |         |           |
| +------v-+   +---v--------+  |
| | br-lan |   | macvtap0   |  |
| | bridge |   | (passthru) |  |
| +----+---+   +-----+------+  |
|      |             |         |
|      |             |         |
| +----v-----+       |         |
| | tap0     |       |         |
| | (LAN)    |       |         |
| +----------+       |         |
|                    |         |
|                    |         |
|              +-----v----+    |
|              | wlp0s20f3|    |
|              | (WLAN)   |    |
|              +----------+    |
|                    |         |
|                    |         |
+--------------------|-------- +
                     |
                     v
                [Internet]
```

1. **OPNsense VM**:
   - LAN interface (virtio-net) connected to `br-lan` bridge via `tap0`
   - WAN interface (virtio-net) connected to physical WLAN via `macvtap0`

2. **Host Network**:
   - `br-lan` bridge with IP `192.168.100.1/24`
   - `tap0` as member of `br-lan`
   - `macvtap0` in passthrough mode connected to `wlp0s20f3`

3. **Traffic Flow**:
   - LAN traffic ↔ `br-lan` ↔ `tap0` ↔ VM LAN interface
   - WAN traffic ↔ `wlp0s20f3` ↔ `macvtap0` ↔ VM WAN interface

4. **NAT Configuration**:
   - Host does NAT between `br-lan` and `wlp0s20f3`
   - VM becomes gateway for LAN subnet
