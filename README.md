# VPSGo
(⚠️脚本为自用设计，基本只覆盖我个人需求，项目的组成较为混乱，包括安装其他开源项目，至此先向每一位开源工作者和相关工作人员表达感激，项目基本为自己使用 AI 整理而成，如有错误请谅解）

一站式 VPS 管理脚本，集成网络优化、系统工具、代理部署等常用功能。

（项目永久保持开源，不会添加任何后门及广告）

## 快速开始

```bash
# 一键安装并运行
bash <(curl -sL https://raw.githubusercontent.com/imNebula/vpsgo/refs/heads/main/vpsgo.sh)
```
```bash
# 安装后直接使用
vpsgo
```

首次运行会自动安装到 `/usr/local/bin/vpsgo`，之后输入 `vpsgo` 即可启动。

## 功能列表

### 网络优化

| # | 功能 | 说明 |
|---|------|------|
| 1 | 开启内核自带 BBR | 安装/启用 TCP BBR 拥塞控制 |
| 2 | 设置队列调度算法 | 支持 fq / cake / fq_pie |
| 3 | 设置 IPv4/IPv6 优先级 | 修改出口协议栈偏好 |
| 4 | TCP 缓冲区调优 | 基于 BDP 自适应优化连接参数 |

### 工具

| # | 功能 | 说明 |
|---|------|------|
| 5 | iPerf3 测速服务端 | 一键启动，自动安装，显示客户端连接命令 |
| 6 | NodeQuality 测试 | 运行 NodeQuality 线路质量评分脚本 |
| 7 | Docker 日志轮转 | 配置 json-file 日志驱动，限制容器日志大小 |
| 8 | Mihomo 安装 | 自动检测架构，支持 amd64-v3/v2 自动降级 |
| 9 | 生成 Mihomo 配置 | 交互式生成 SS / AnyTLS 服务端配置及分享链接 |
| 10 | sing-box 安装 | Debian/Ubuntu 使用官方 APT 源，其他发行版使用安装脚本 |

### 其他

| 快捷键 | 功能 |
|--------|------|
| u | 从 GitHub 更新到最新版 |
| 0 | 退出脚本 |

## 系统要求

- **操作系统**: Linux (Debian / Ubuntu / CentOS / RHEL / Arch 等)
- **权限**: 需要 root 权限 (`sudo vpsgo`)
- **依赖**: `bash`, `curl`

## 更新

在脚本菜单中输入 `u` 即可自动从 GitHub 拉取最新版本并重启。

## License

MIT
