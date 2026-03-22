# Wiretify - Modern WireGuard VPN Management

Wiretify is a high-performance, minimalist WireGuard management tool written in Go with a sleek, modern web UI. It simplifies the setup, deployment, and administration of VPN peers, dynamic network configuration (NAT, Firewall), and IP allocation without the hassle of manual configuration files.

## 🚀 Quick Install on VPS (Recommended)

To automatically install and deploy Wiretify on your fresh VPS (Ubuntu, Debian, CentOS) in under a minute, run the following command:

```bash
wget -qO- https://raw.githubusercontent.com/accnet/Public/refs/heads/main/wiretify/install.sh | sudo bash
```

### What the installer does:
1. Installs prerequisites (`wireguard`, `iptables`, `unzip`...).
2. Enables IPv4 IP forwarding in your Linux kernel for VPN routing.
3. Detects your current Public IP automatically.
4. Downloads the newest pre-compiled release (`wiretify.zip`) directly from this repository.
5. Installs everything cleanly to `/opt/wiretify`.
6. Creates and starts a Systemd background service (`wiretify.service`) ensuring it boots up with your server.

### Post-Installation
- **Web UI Dashboard:** Access your manager at `http://<YOUR_VPS_PUBLIC_IP>:8080`
- **Firewall:** Don't forget to **open UDP port 51820** and **TCP port 8080** in your VPS's Cloud Firewall (e.g., AWS Security Group, DigitalOcean Firewall) if they are blocked.
- **Service Logs:** View realtime logs via `journalctl -fu wiretify`.

---
