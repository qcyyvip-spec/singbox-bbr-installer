# Sing-box / BBR Navigator

这是一个简化版的导航式安装器，目标很直接：

1. 安装 `sing-box` 节点
2. 安装 / 启用 `BBR`
3. 查看当前状态

## 用法

推荐先克隆仓库再运行：

```bash
git clone https://github.com/qcyyvip-spec/singbox-bbr-installer.git
cd singbox-bbr-installer
bash install.sh -l
```

也可以直接运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/qcyyvip-spec/singbox-bbr-installer/main/install.sh) -l
```

启动后按数字选择：

- `1`：安装 `VLESS + Reality` sing-box 节点
- `2`：安装 / 启用 BBR
- `3`：查看 sing-box 和 BBR 状态
- `0`：退出

## 说明

- `sing-box` 节点采用 `VLESS + Reality`
- 配置和状态会放在 `/etc/sing-box-nav/`
- 服务名是 `sing-box-nav`
- `BBR` 会写入独立的 `sysctl` 文件，不会去改系统里别的配置
- 安装节点需要系统提供 `systemd` 或 `OpenRC`
- 如果 VPS 是 LXD/LXC 容器，BBR 是否能真正启用取决于宿主机是否开放对应内核能力

## 参考

这个项目是对 `qcmusic/sing-box` 的功能思路做了精简和重组，不再保留原来那套全家桶菜单。
