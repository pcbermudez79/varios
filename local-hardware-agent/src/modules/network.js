'use strict';

const os = require('os');
const si = require('systeminformation');

async function getNetworkInfo() {
  const [ifaces, defaultIface, wifi] = await Promise.all([
    si.networkInterfaces(),
    si.networkInterfaceDefault(),
    si.wifiConnections().catch(() => [])
  ]);

  const active = ifaces.filter(
    (i) => !i.internal && i.operstate === 'up' && (i.ip4 || i.ip6)
  );

  const primary = active.find((i) => i.iface === defaultIface) || active[0] || null;

  return {
    hostname: os.hostname(),
    platform: process.platform,
    arch: process.arch,
    userInfo: {
      username: os.userInfo().username,
      homedir: os.userInfo().homedir
    },
    defaultInterface: defaultIface,
    primary: primary
      ? {
          iface: primary.iface,
          type: primary.type,
          mac: primary.mac,
          ip4: primary.ip4,
          ip4subnet: primary.ip4subnet,
          ip6: primary.ip6,
          speed: primary.speed,
          dhcp: primary.dhcp
        }
      : null,
    interfaces: active.map((i) => ({
      iface: i.iface,
      ifaceName: i.ifaceName,
      mac: i.mac,
      ip4: i.ip4,
      ip4subnet: i.ip4subnet,
      ip6: i.ip6,
      type: i.type,
      speed: i.speed,
      dhcp: i.dhcp,
      operstate: i.operstate,
      virtual: i.virtual
    })),
    wifi: wifi.map((w) => ({
      ssid: w.ssid,
      bssid: w.bssid,
      channel: w.channel,
      signalLevel: w.signalLevel,
      security: w.security
    })),
    uptimeSec: os.uptime(),
    loadavg: os.loadavg()
  };
}

async function getPublicIp() {
  return null;
}

module.exports = { getNetworkInfo, getPublicIp };
