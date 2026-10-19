# 本机环境记录（argoDemo）

学习环境踩坑记录。换机器或 VM 重建后需要重新处理下面两项。

## 已安装

| 工具 | 版本 | 路径 |
|---|---|---|
| colima | 0.10.3 | /opt/homebrew/bin/colima |
| docker (CLI) | 29.9.1 | /opt/homebrew/bin/docker |
| kubectl | 1.37.1 | /opt/homebrew/bin/kubectl |
| kind | 0.33.0 | /opt/homebrew/bin/kind |
| argocd (CLI) | v3.5.5 | /opt/homebrew/bin/argocd |
| docker-credential-helper | 已有 | /opt/homebrew/bin/docker-credential-osxkeychain |
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

## 坑 4：github.com 解析到不可达 IP（会漂移）

现象：宿主机 `git push` 卡住；集群里 `argocd-repo-server` 报
```
git fetch origin --tags --force --prune failed exit status 128:
Failed to connect to github.com port 443 after 75023 ms
```
Application 上表现为
```
ComparisonError: Failed to load target state: failed to generate manifest
for source 1 of 1: ... context deadline exceeded
```

根因：本地 DNS 把 `github.com` 解析到 `20.205.243.166`，该 IP 从这里不可达。
实测可达的是 `140.82.112.3` / `140.82.113.3` / `140.82.114.3`，
**而且会漂**：`140.82.113.3` 一度从 OK 变成 FAIL。

两处修法（不一样，因为不在同一层）：

```bash
# A. 宿主机 git —— 改走 SSH（已验证：ssh -T 返回 'Hi OliverYang!'）
git remote set-url origin git@github.com:OliverYang/argo-demo.git

# B. 集群内 Argo CD —— 用 hostAliases 把 github.com 钉到可达 IP
kubectl -n argocd patch deploy argocd-repo-server --type merge -p '{
  "spec":{"template":{"spec":{"hostAliases":[
    {"ip":"140.82.112.3","hostnames":["github.com"]}
  ]}}}}'
# 然后强制刷新
argocd app get argo-demo-dev --insecure --refresh hard
```

验证 IP 是否可用（在 repo-server pod 里测最准）：
```bash
curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 --resolve github.com:443:140.82.112.3 \
  https://github.com/OliverYang/argo-demo
```

> 这是**临时止血**，不是配置的一部分：IP 会变，pod 重建也会丢（但 `scripts/up.sh`
> 会重新打）。真正的解法是把仓库镜像到内网可达的 Git 服务，或走代理。
> 排查口诀：宿主机通不通 → VM 通不通 → pod 通不通，三层结论不同，修法也不同。

## 坑 5：Argo CD 官方清单要 `--server-side`

```bash
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

直接 `kubectl apply` 会失败：CRD `applications.argoproj.io` 本身就有 **406613 字节**
（整份 install.yaml 约 480KB），client-side apply 要把整对象塞进
`kubectl.kubernetes.io/last-applied-configuration` annotation，超了 etcd 单对象
annotation 上限。报错形态是 `metadata.annotations: Too long` 一类。

复现这个机制（本机可直接跑）：
```bash
kubectl get crd applications.argoproj.io -o yaml > /tmp/c.yaml
kubectl apply -f /tmp/c.yaml --dry-run=client   # error: error when applying patch
```

顺带：`syncOptions: [ServerSideApply=true]` 在 `argocd/*-app.yaml` 里也是同一回事 ——
Argo CD 渲染大清单时同样要用 server-side。

## 坑 6：argocd CLI 登录参数

```bash
# ✅ 可用
argocd login localhost:8080 --username admin \
  --password "$(cat .argocd-password)" --insecure --grpc-web

# ❌ x509 证书错误：端口是 TLS，但 --plaintext 强制明文
argocd login localhost:8080 --insecure --plaintext ...
# ❌ connection reset：svc 原本 443→8443（TLS 端口）而 --plaintext 打到明文 8080
```

前置条件：`argocd-server` Service 已改成 `{port: 443, targetPort: 8080}`，
所以 `kubectl port-forward svc/argocd-server 8080:443` 拿到的是明文 HTTP 端口，
CLI 只需 `--insecure` 跳过自签证书校验。密码存在 `.argocd-password`（已 gitignore）。

## 重启之后

```bash
scripts/up.sh          # 幂等：colima → mirrors → kind → argocd → hostAliases
scripts/port-forward.sh # 前台，Ctrl-C 全关
```

`colima delete` 重建 VM 会丢坑 1 + 坑 2 的修复；`kind delete cluster` 会丢 Argo CD
（`up.sh` 会自动重装）。port-forward 在 pod 滚动后会断开，重跑脚本即可。
