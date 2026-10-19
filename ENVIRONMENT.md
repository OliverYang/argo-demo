# 本机环境记录（argoDemo）

学习环境踩坑记录。换机器或 VM 重建后需要重新处理下面两项。

## 已安装

| 工具 | 版本 | 路径 |
|---|---|---|
| colima | 0.10.3 | /opt/homebrew/bin/colima |
| docker (CLI) | 29.9.1 | /opt/homebrew/bin/docker |
| kubectl | 1.37.1 | /opt/homebrew/bin/kubectl |
| kind | 0.33.0 | /opt/homebrew/bin/kind |
| helm | 3.15.2 | 已有 |

注意：`/usr/local/bin/brew` 是 Rosetta 的 x86 版本，**一律用 `/opt/homebrew/bin/brew`**（arm64 原生）。

## 坑 1：Colima VM 内 DNS 不工作

现象：`docker run hello-world` 报
`dial tcp: lookup registry-1.docker.io on [::1]:53: read udp ...: connection refused`

原因：VM 里 `/etc/resolv.conf` 是软链到 `systemd-resolved` 的 stub 文件，
但镜像里 `systemd-resolved` 服务**不存在**（`Unit file ... does not exist`），
导致没有本地 DNS 监听，解析器连 `[::1]:53` 失败。

修复（持久化到 colima 配置）：

```bash
colima stop
colima start --dns 114.114.114.114 --dns 223.5.5.5 \
  --cpu 4 --memory 6 --disk 60 --vm-type vz --mount-type virtiofs
```

VM 内手工验证：

```bash
colima ssh -- getent hosts registry-1.docker.io
```

## 坑 2：Docker Hub 直连被墙

现象：DNS 能解析，但 `registry-1.docker.io:443` 连接 i/o timeout。

修复：在 VM 的 `/etc/docker/daemon.json` 加镜像加速器后重启 docker：

```bash
colima ssh -- sh -c 'sudo python3 - <<EOF
import json
p="/etc/docker/daemon.json"
d=json.load(open(p))
d["registry-mirrors"]=["https://docker.m.daocloud.io","https://docker.1ms.run","https://dockerproxy.net"]
json.dump(d,open(p,"w"),indent=2)
EOF
sudo systemctl restart docker'
```

可达性实测（VM 内）：
- `ghcr.io:443` OK — 所以我们用 GHCR 存镜像，不走 Docker Hub
- `quay.io:443` OK
- `registry-1.docker.io:443` FAIL
- 加速器 `docker.m.daocloud.io` / `docker.1ms.run` / `dockerproxy.net` 均 OK

> 注意：`colima start` 会重写 daemon.json 吗？不会覆盖已存在文件，但
> `colima delete` 重建 VM 后会丢失，需要重做坑 1 + 坑 2。

## 坑 3：docker-credential-osxkeychain 缺失

`~/.docker/config.json` 里 `credsStore: osxkeychain`，但 helper 不在 PATH。
修复：`brew install docker-credential-helper`
