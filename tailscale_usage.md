# Tailscale 

---

## 介绍
基于 WireGuard 的虚拟局域网工具，让不同地区、不同网络下的设备像处于同一个局域网中，不需要公网 IP，也不用在路由器上做端口映射，这个局域网称为 Tailnet，设备加入同一个 Tailnet 之后，会获得一个通常以 `100.x.x.x` 开头的 Tailscale IP。其他获得授权设备可以直接通过 IP 访问

--- 

## 运行模式
Tailscale 在 Linux 平台上主要有两种运行方式
1. 标准 TUN 模式 
2. Userspace Networking 用户态网络模式

选择哪一种主要取决于内核是否开启 TUN/TAP 驱动 `CONFIG_TUN`

### 标准 TUN 模式
如果内核有配置并且存在 `/dev/net/tun` 则可以使用标准 Tailscale 模式
1. 标准模式下，Tailscale 会创建虚拟网卡 `tailscale0` 
2. 检查虚拟网卡 `ip addr show tailscale0`
3. 可以直接通过 IP 访问相关的服务
4. 标准 TUN 模式不需要为 SSH 单独配置 `Tailscale Serve` 转发，在配置文件 `/etc/default/tailscaled` 设置 `FLAGS=""`
5. 启动并登录，`tailscale up` 之后会有一个链接，需要去登录授权 
    ```bash
    sudo systemctl daemon-reload 
    sudo systemctl enable --now tailscaled 
    sudo tailscale up
    ```
6. 检查
    ```bash 
    systemctl is-active tailscaled 
    tailscale status 
    tailscale ip -4 
    ip addr show tailscale0
    ```
### Userspace Networking 模式
如果内核没有配置并且不存在 `/dev/net/tun` 则可以使用 Userspace Networking 模式
1. 编辑配置文件 `/etc/default/tailscaled` 设置 `FLAGS="--tun=userspace-networking"`
2. 启动，登录，认证 
    ```bash 
    sudo systemctl daemon-reload 
    sudo systemctl enable --now tailscaled 
    sudo systemctl restart tailscaled
    sudo tailscale up
    ```
3. 确认IP `tailscale ip -4`
4. 建立转发 `sudo tailscale serve --bg --tcp=2222 tcp://127.0.0.1:22`
