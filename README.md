# VPSGo
(⚠️脚本为自用设计，基本只覆盖我个人需求，项目的组成较为混乱，包括安装其他开源项目，至此先向每一位开源工作者和相关工作人员表达感激，项目基本为自己使用 AI 整理而成，如有错误请谅解）

一站式 VPS 管理脚本，集成网络优化、系统工具、代理部署等常用功能。

（项目永久保持开源，不会添加任何后门及广告）

## 快速开始
脚本已覆盖 Ubuntu/Debian 与 Alpine(OpenRC) 常用场景，Alpine 需先安装 `bash`。

```bash
# 一键安装并运行
sudo curl -fsSL https://raw.githubusercontent.com/imNebula/vpsgo/refs/heads/main/vpsgo.sh -o /usr/local/bin/vpsgo
sudo chmod 0755 /usr/local/bin/vpsgo
hash -r
```

```bash
# 国内网络可选：通过 gh-proxy 安装
sudo curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/imNebula/vpsgo/refs/heads/main/vpsgo.sh -o /usr/local/bin/vpsgo
sudo chmod 0755 /usr/local/bin/vpsgo
hash -r
```
```bash
# 安装后直接使用
vpsgo
```

```bash
# Alpine 额外准备（仅首次）
sudo apk add --no-cache bash curl
```

首次运行会自动安装到 `/usr/local/bin/vpsgo`，之后输入 `vpsgo` 即可启动。

首页支持 `g` 键一键切换 GitHub 代理，默认使用 `https://gh-proxy.com/`，会自动作用到脚本自更新、Mihomo、Shadowsocks-Rust、Akile DNS 等 GitHub 相关下载/API 请求。

如果出现 `-ash: vpsgo: Permission denied`，可执行：

```bash
command -v vpsgo
ls -l "$(command -v vpsgo)"
sudo chmod 0755 "$(command -v vpsgo)"
```

若挂载参数包含 `noexec`，请改用其他路径（示例）：

```bash
sudo env VPSGO_INSTALL_PATH=/usr/bin/vpsgo bash /usr/local/bin/vpsgo
hash -r
```

## 功能列表

### 网络优化

| # | 功能 | 说明 |
|---|------|------|
| 1 | 开启内核自带 BBR | 安装/启用 TCP BBR 拥塞控制 |
| 2 | 设置队列调度算法 | 支持 fq / cake / fq_pie |
| 3 | 设置 IPv4/IPv6 优先级 | 修改出口协议栈偏好 |
| 4 | TCP 缓冲区调优 | 基于 BDP 自适应优化连接参数；CAKE 持久化支持 systemd/OpenRC |

### 工具

| # | 功能 | 说明 |
|---|------|------|
| 5 | iPerf3 测速服务端 | 一键启动，自动安装，显示客户端连接命令 |
| 6 | NodeQuality 测试 | 运行 NodeQuality 线路质量评分脚本 |
| 7 | Docker 日志轮转 | 配置 json-file 日志驱动，限制容器日志大小；支持 systemd/OpenRC 重启 Docker |
| 8 | Mihomo 管理 | 安装/更新、生成配置 (SS/AnyTLS/HY2/WireGuard 入站)、读取配置导出节点、自启动、重启、查看日志 |
| 9 | sing-box 安装 | Debian/Ubuntu 使用官方 APT 源，其他发行版使用安装脚本；自启动支持 systemd/OpenRC |
| 10 | Snell V5 管理 | 官方工具安装/更新、配置与启动、日志/状态、卸载，含与 Mihomo 端口冲突检查；支持 systemd/OpenRC |
| 11 | WireGuard 原生节点 | 原生内核方案，一键部署/重建、支持新增多个客户端（不重建服务端）、客户端配置导出、服务状态/重启/卸载，含与 Mihomo 端口冲突检查；支持 systemd/OpenRC 持久化 |
| 12 | Shadowsocks-Rust 管理 | 官方 releases 安装/更新、配置并启动、自启动、日志/状态、卸载；支持 systemd/OpenRC，适合 LXC/容器环境 |

### 系统

| # | 功能 | 说明 |
|---|------|------|
| 10 | Swap 管理 | 智能推荐大小，创建/删除 Swap 文件 |

### 其他

| 快捷键 | 功能 |
|--------|------|
| g | GitHub 代理开关（gh-proxy.com） |
| u | 从 GitHub 更新到最新版 |
| x | 卸载 VPSGo |
| 0 | 退出脚本 |

## 系统要求

- **操作系统**: Linux (Debian / Ubuntu / Alpine / CentOS / RHEL / Arch 等)
- **权限**: 需要 root 权限 (`sudo vpsgo`)
- **依赖**: `bash`, `curl`

## 更新

在脚本菜单中输入 `u` 即可自动从 GitHub 拉取最新版本并重启。

如果在国内网络下访问较慢，可先在首页按 `g` 开启 GitHub 代理后再更新或安装相关组件。

## License

MIT
