rec {
  # Dual 2.5GbE PCIe NIC predictable names
  wanInterface = "enp1s0"; # 2.5GbE Port 1 -> Modem / ONT
  lanInterface = "enp2s0"; # 2.5GbE Port 2 -> KeepLINK Switch Port 1 (802.1Q Trunk)

  # Motherboard onboard 1GbE NIC (Emergency Out-of-Band Rescue)
  oob = {
    interface = "eno1";
    subnet = "192.168.99";
    routerIp = "192.168.99.1";
    prefix = 24;
    description = "Emergency out-of-band rescue port on motherboard 1GbE NIC";
  };

  mgmt = {
    id = 1;
    name = "mgmt";
    subnet = "192.168.1";
    routerIp = "192.168.1.1";
    prefix = 24;
    description = "Management network for switch, AP, and network infrastructure";
  };

  vlans = {
    skylab = {
      id = 77;
      name = "skylab";
      subnet = "192.168.77";
      routerIp = "192.168.77.1";
      prefix = 24;
      interface = "${lanInterface}.77";
      description = "Family and trusted devices; full network and internet access";
      trusted = true;
    };

    skynet = {
      id = 62;
      name = "skynet";
      subnet = "192.168.62";
      routerIp = "192.168.62.1";
      prefix = 24;
      interface = "${lanInterface}.62";
      description = "Friends and guest network; internet and IoT casting access only";
      trusted = false;
    };

    iot = {
      id = 69;
      name = "iot";
      subnet = "192.168.69";
      routerIp = "192.168.69.1";
      prefix = 24;
      interface = "${lanInterface}.69";
      description = "Untrusted smart home and IoT devices; outbound internet only";
      trusted = false;
    };
  };

  switch = {
    model = "KeepLINK KP-9000-9XHPML-X";
    ip = "192.168.1.2";
    subnet = "255.255.255.0";
    gateway = "192.168.1.1";
    ports = {
      "1" = {
        desc = "Uplink to Michael (Firewall LAN)";
        mode = "trunk";
        nativeVlan = 1;
        taggedVlans = [62 69 77];
        poe = false;
      };
      "2" = {
        desc = "PoE+ Uplink to Zyxel WBE530 AP";
        mode = "trunk";
        nativeVlan = 1;
        taggedVlans = [62 69 77];
        poe = true;
      };
      "3" = {
        desc = "Zita (HP z620 Server - Samba/Storage)";
        mode = "access";
        nativeVlan = 77;
        taggedVlans = [];
        poe = false;
      };
      "4" = {
        desc = "Francis (Workstation)";
        mode = "access";
        nativeVlan = 77;
        taggedVlans = [];
        poe = false;
      };
      "5" = {
        desc = "Spare 2.5G PoE+";
        mode = "access";
        nativeVlan = 77;
        taggedVlans = [];
        poe = true;
      };
      "6" = {
        desc = "Spare 2.5G PoE+";
        mode = "access";
        nativeVlan = 77;
        taggedVlans = [];
        poe = true;
      };
      "7" = {
        desc = "Spare 2.5G PoE+";
        mode = "access";
        nativeVlan = 77;
        taggedVlans = [];
        poe = true;
      };
      "8" = {
        desc = "Spare 2.5G PoE+";
        mode = "access";
        nativeVlan = 77;
        taggedVlans = [];
        poe = true;
      };
      "9" = {
        desc = "10G SFP+ Uplink / High-speed Storage";
        mode = "trunk";
        nativeVlan = 77;
        taggedVlans = [];
        poe = false;
      };
    };
  };

  ap = {
    model = "Zyxel WBE530";
    ip = "192.168.1.3";
    subnet = "255.255.255.0";
    gateway = "192.168.1.1";
    ssids = {
      skylab = {
        vlanId = 77;
        security = "wpa3-sae-wpa2-psk";
        band = "all";
        clientIsolation = false;
        desc = "Family trusted WiFi";
      };
      skynet = {
        vlanId = 62;
        security = "wpa2-psk";
        band = "all";
        clientIsolation = true;
        desc = "Guest and friend WiFi";
      };
      iot = {
        vlanId = 69;
        security = "wpa2-psk";
        band = "2.4ghz";
        clientIsolation = true;
        desc = "Smart home IoT WiFi";
      };
    };
  };
}
