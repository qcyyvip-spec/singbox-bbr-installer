# 启辰音乐工具箱

![qcyy logo](assets/qcyy-logo.svg)

这是一个带导航菜单的轻量工具箱，界面已改为「启辰音乐工具箱」。
当前保留的功能仍然是：

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
- 终端标题和 README 已替换为「启辰音乐工具箱」
- `qcyy` logo 位于 `assets/qcyy-logo.svg`
- `BBR` 会写入独立的 `sysctl` 文件，不会去改系统里别的配置
- 安装节点需要系统提供 `systemd` 或 `OpenRC`
- 如果 VPS 是 LXD/LXC 容器，BBR 是否能真正启用取决于宿主机是否开放对应内核能力

## 参考

这个项目保留了原有的功能骨架，只是把外层品牌和菜单做了重命名与精简。
