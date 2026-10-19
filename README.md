# argo-demo — 一套跑通的 CI/CD + GitOps 最小闭环

这不是教程的复制品，是**你自己机器上真实跑通的系统**。所有结论后面都附了在本仓库
里实际观察到的证据（commit hash、报错原文、命令输出），你可以随时复现。

```
你 git push
   │
   ▼
┌─────────────────────── GitHub Actions (CI) ────────────────────────┐
│  test          npm test + kustomize 渲染两个 overlay                │
│    ▼                                                               │
│  build         多平台镜像，tag = git SHA，APP_VERSION 烧进镜像        │
│    ▼                    ghcr.io/oliveryang/argo-demo-app:713cbd6    │
│  bump-dev      改一行 newTag，bot 提交                              │
└────────────────────────────────┬────────────────────────────────────┘
                                 │  git push（这是 CI 与 CD 之间唯一的接口）
                                 ▼
                            Git 仓库  ← 唯一事实来源
                                 │
                                 ▼
┌──────────────── Argo CD (CD / GitOps) ────────────────────────────┐
│  轮询 repo → kustomize 渲染 → diff → 应用到集群 → 持续对齐           │
│    ├── argo-demo-dev   (overlay dev,  1 副本)                      │
│    └── argo-demo-prod  (overlay prod, 3 副本)                      │
└───────────────────────────────────────────────────────────────────┘
```

---

## 0. 心智模型：CI/CD 的四个阶段

| 阶段 | 职责 | 本项目对应 |
|---|---|---|
| **CI** | 代码变了，自动验证它没坏 | `.github/workflows/ci.yaml` 的 `test` job |
| **制品** | 把验证过的代码变成一个不可变的东西 | `build` job → GHCR 上一个 git SHA 标签 |
| **CD** | 让集群状态变成"部署清单说它应该有的样子" | Argo CD + `argocd/*.yaml` |
| **反馈** | 知道线上跑的是什么、出问题怎么退 | `/version` 端点 + Git 历史 |

一句最容易误解的话：**CI 和 CD 之间不靠网络调用、不靠 webhook，只靠一次 Git 提交。**
这是整个 GitOps 设计的关键，第 4 节会展开。

---

## 1. 目录与文件逐个讲

```
app/                        应用本体（一个 40 行的 Node HTTP 服务）
  server.js                   三个端点：/  /healthz  /version
  test/server.test.js         起真进程测真 HTTP，不是 mock
  Dockerfile                  多阶段；ARG APP_VERSION 在构建期定死版本身份
  .dockerignore               test/ 和 Dockerfile 不进镜像

deploy/                     部署清单（Kustomize）
  base/                       各环境**完全相同**的部分
  overlays/dev/               dev 与 base 的**差异**：1 副本、ENV_NAME=dev、镜像 tag
  overlays/prod/              prod 的差异：3 副本、ENV_NAME=prod、镜像 tag

argocd/                     Argo CD 自己的配置
  dev-app.yaml                Application CR：去哪里读、部署到哪、怎么同步
  prod-app.yaml               同上，指 prod overlay

.github/workflows/ci.yaml   CI 流水线（4 个 job）
scripts/up.sh               重启后一键拉起整套环境（幂等）
scripts/port-forward.sh     开三个端口转发
ENVIRONMENT.md              这台机器的环境坑（DNS / 镜像加速 / 网络）
```

### 值得注意的三个设计决定

**① 版本身份在构建期固定，不在部署期注入**

```dockerfile
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}
```
CI 传 `--build-arg APP_VERSION=${GITHUB_SHA::7}`。

为什么：如果版本靠 Deployment 的环境变量给，那么"运行的应用说我是 X" 和
"镜像 tag 是 Y" 可以各说各话 —— 排查故障时你会被骗。构建期烧死之后，
`/version` 返回的值**永远**等于镜像 tag，这个不变式让线上版本可无条件信任。

实测：部署 `292bcfa` 时 `/version` 返回 `{"version":"292bcfa"}`，
`kubectl get deploy -o jsonpath` 返回镜像 `...:292bcfa`。一致。

**② base 只放共性，环境只表达差异**

prod 和 dev 的差别就是两个 overlay 文件里的 20 行左右：副本数、环境名、镜像 tag。
base 里改一次，两个环境同时生效。这就是不用 Helm 也能做环境分层的方式，
而且 diff 极小 —— 一个 release 只改一行 `newTag`。

**③ 测试起的是真进程**

`test/server.test.js` 用 `child_process.spawn` 真起 server，等 stdout 出现
`listening` 再打 HTTP 请求。所以 CI 绿灯意味着"这个镜像一定能启动并正确响应"，
不是"某个 mock 的行为符合我的想象"。CI 的价值几乎全部来自这种真实性。

---

## 2. 完整走一遍：一次 push 发生了什么

这是本项目的核心链路。以下所有 hash 都是本仓库的真实历史。

### Step 1 — 改代码并 push

```bash
git commit -am "feat: v2 message" && git push   # → 292bcfa
```

### Step 2 — CI 的 test job

```
✓ Install
✓ Unit + integration tests          (4 passed)
✓ Validate kustomize overlays render
```
第二个步骤是关键：**在 CI 里就把 overlay 渲染一遍**。清单语法坏了要在
CI 阶段失败，而不是让 Argo CD 同步时才炸 —— 后者会让你看到
`Sync Status: Unknown`，报错藏在 pod 日志里，排查成本高得多。

### Step 3 — build job 推镜像

```
ghcr.io/oliveryang/argo-demo-app:292bcfa
ghcr.io/oliveryang/argo-demo-app:latest
```
tag 是 **7 位 git SHA**，不是 `latest`。理由：镜像内容会变而 `latest` 这个名字不变，
于是"回滚"无从谈起（你无法回滚到一个一直在漂移的 tag）。SHA 是不可变的：
`292bcfa` 永远是那次构建的产物，回滚 = 把名字换回去。

### Step 4 — bump-dev job：CI 交棒给 CD

bot 提交了一个 commit：

```
5a79128 chore(dev): deploy 292bcfa [skip ci]

-  newTag: e085f82
+  newTag: 292bcfa
```

**这就是"部署"的全部动作** —— 一行 Git 提交。没有 `kubectl`、没有 SSH、
没有调集群 API。CI 甚至不需要集群凭证，这是 GitOps 的安全优势：
构建流水线的权限被攻破也碰不到集群。

`[skip ci]` 是必需的：bot 的提交会再次触发 workflow，不标记就变成
build → bump → build → bump 的死循环。

### Step 5 — Argo CD 把集群对齐到 Git

```
Sync Status: Synced to main (5a79128)
deployment.apps/argo-demo serverside-applied
```
pod 从 `argo-demo-6f4784754d-*` 换成 `argo-demo-84c655c8df-*`，滚动更新。

### Step 6 — 验证线上版本

```bash
curl localhost:18090/
{"message":"Hello from argoDemo v2","version":"292bcfa","env":"dev","pod":"argo-demo-84c655c8df-c7zrp"}
```

**全程你只做了一件事：`git push`。**

---

## 3. GitOps 的三个特性，我都实测过

### ① 漂移检测 + 自愈（selfHeal）

```bash
kubectl -n argo-demo-dev scale deploy/argo-demo --replicas=3   # 手工改集群
# t=5s  replicas=1        ← Argo CD 把它改回去了
```

为什么值得：`kubectl` 命令式部署没有"应该是什么"的概念，谁都能改，改完没人知道，
下次部署时被无声覆盖。开启 selfHeal 后，**集群里手工改的东西是活不过 3 分钟的**，
唯一持久的改法是改 Git。这条纪律一旦建立，"prod 上跑的是什么"就永远有确定答案。

### ② 回滚（并且理解为什么 `argocd app rollback` 被拒绝）

先试直觉做法：

```bash
argocd app rollback argo-demo-dev 1
# rpc error: code = FailedPrecondition
# desc = rollback cannot be initiated when auto-sync is enabled
```

**这不是 bug，是设计。** Argo CD 拒绝执行一个注定会被自己撤销的操作：
如果它帮你回滚了集群，但 Git 里还写着新版本，下一次同步就会把"回滚"覆盖掉。
一个会凭空消失的部署等于没部署。

正确做法 —— 回滚就是一次前向的 Git 提交：

```bash
# 只改 overlay 的这一行，不动任何代码
newTag: 292bcfa  →  newTag: e085f82
git commit -m "chore(dev): rollback to e085f82 [skip ci]"
git push
# → Synced to main (04baed7)，pod 回到 e085f82
```

`[skip ci]` 在这里有第二层含义，很多人会踩：**回滚不应该触发重新构建**。
如果这次 push 触发 CI，CI 会构建一个新 SHA 并把 dev 顶上去 —— 你的回滚被自己抵消。

用 Git 历史当部署历史还有个好处：谁回滚的、什么时候、为什么，都在 code review 的
流程里，不用去 CD 工具的审计日志里刨。

### ③ 环境分层与晋升（promote）

把 dev 验证过的**同一个镜像**推到 prod，靠手动触发 workflow：

```bash
gh workflow run ci.yaml -f promote=true -f promote_tag=713cbd6
```

结果：
```
Test:            success
Promote to prod: success
Build & Push:    skipped      ← 关键
Bump dev:        skipped      ← 关键
```

`prod` overlay 变成 `newTag: 713cbd6`，与 dev 同一个 SHA，prod 3 副本：

```
DEV  = ghcr.io/oliveryang/argo-demo-app:713cbd6
PROD = ghcr.io/oliveryang/argo-demo-app:713cbd6   replicas=3
```

**为什么晋升不能重新构建**：prod 上跑的必须是你在 dev 里亲自验证过的那个字节级
产物。重新构建会得到另一个镜像（依赖可能变了、基础镜像层可能更新了），
那么 dev 的测试结果对 prod 就没有任何保证 —— 这叫 "promotion build" 反模式。

这个 workflow 最初是有缺陷的：`workflow_dispatch` 也会走 build + bump-dev，
于是"晋升 prod"会顺手把 dev 顶到最新版，摧毁你刚做的回滚。修法是给 job 加条件：

```yaml
build:
  if: github.event_name == 'push'          # 手动触发不重新构建
bump-dev:
  if: github.event_name == 'push'          # 手动触发不动 dev
promote-prod:
  needs: [test]                            # 不依赖 build，直接吃 promote_tag
```

---

## 4. 概念表：学完这个项目你应该能解释这些

| 概念 | 一句话 | 本项目在哪 |
|---|---|---|
| **Pipeline as code** | 部署流程本身是 Git 里的代码，可 review、可回滚 | `ci.yaml` |
| **Immutable artifact** | 制品名字和内容永不变 | 镜像用 git SHA 打 tag |
| **Declarative** | 描述目标状态，不描述步骤 | 整个 `deploy/` |
| **Source of truth** | 集群状态由 Git 定义，不由 `kubectl` 历史定义 | GitOps 的核心 |
| **Reconciliation loop** | 控制器持续对比"想要"与"实际"并修正 | Argo CD 同步 |
| **Drift** | 集群和 Git 不一致 | `OutOfSync` / selfHeal 拉回 |
| **Overlay** | 环境 = base + 差异 | `overlays/{dev,prod}` |
| **Least privilege** | 每个 job 只拿必需权限 | `permissions: contents: read` 默认 |
| **Concurrency control** | 新提交取消进行中的旧运行 | `concurrency.cancel-in-progress` |

### Argo CD 术语

- **Application**：一个 CR，说"从这个 Git 路径、渲染成清单、装到这个集群这个 namespace"
- **Project**：权限边界（生产环境应建独立 project 限制 destination）
- **Sync**：让集群等于 Git
- **Health**：资源真的在跑吗（Synced 但 pod CrashLoop 时 Health = Degraded）
- **prune**：Git 里删了的资源，集群也删
- **selfHeal**：集群手工改的，改回 Git 说的样子

### Sync 与 Health 是两件事

这是新手最容易混的点。`Synced` 只代表"清单和 Git 一致"，
不代表"应用在跑"；反过来 `Healthy` 也不保证状态跟 Git 一致。

本项目里真实发生过的例子：网络抖动导致 Argo CD 拉不到仓库时，
prod 是 `Sync Status: Unknown` 但 `Health Status: Healthy` ——
集群里的 pod 活得好好的，只是控制器无法判断它是否符合 Git：

```
Sync Status:        Unknown
Health Status:      Healthy
```

另一个方向同样常见：`Synced` 但 pod 一直 `ImagePullBackOff`，
此时 Health = `Degraded`。两个状态必须一起看：

```bash
argocd app get argo-demo-dev --insecure | grep -E "Sync Status|Health"
```

---

## 5. 本地怎么用

```bash
# 重启机器后一键拉起（幂等，可反复运行）
scripts/up.sh

# 开端口转发（前台运行，Ctrl-C 全关）
scripts/port-forward.sh
```

```
Argo CD UI   https://localhost:8080     用户 admin，密码见 .argocd-password
argocd CLI   argocd login localhost:8080 --insecure --grpc-web \
              --username admin --password "$(cat .argocd-password)"
DEV  app     http://localhost:18090/    /version  /healthz
PROD app     http://localhost:18091/
```

常用命令：
```bash
argocd app list --insecure --grpc-web
argocd app get argo-demo-dev --insecure
argocd app diff argo-demo-dev --insecure          # Git 与集群差在哪
argocd app history argo-demo-dev --insecure        # 部署历史
argocd app wait argo-demo-dev --health --insecure     # 阻塞直到 Healthy
```
（CLI 走 grpc-web；`--insecure` 因为证书是自签的）

---

## 6. 这个项目**故意没有**做的东西

理解边界比堆功能重要。真实生产环境还需要：

| 缺失 | 为什么本项目能省 | 生产上怎么办 |
|---|---|---|
| **密钥管理** | demo 里没有敏感配置 | Sealed Secrets / External Secrets + Vault。**绝不要把 secret 提交进 Git** |
| **prod 门禁** | 单人学习，selfHeal 直连生效 | prod overlay 改动要求 PR + approval，`selfHeal` 关掉，靠人点同步 |
| **渐进发布** | 直接滚动更新 | Argo Rollouts 做金丝雀/蓝绿 + Analysis Template 自动看指标回滚 |
| **镜像漏洞扫描** | 无 | Trivy / Grype 加一个 CI job；prod 关掉 `:latest` 标签 |
| **多集群** | 只有一个 kind 集群 | Argo CD ApplicationSet 按 Git 目录自动为每个集群生成 Application |
| **通知** | 手看终端 | Notifications 配置接 Slack / 钉钉 |
| **`ImagePullPolicy: IfNotPresent`** | 本地 kind，手动加载过镜像 | 生产用 `Always`（配合不可变 tag） |
| **namespace 靠 `CreateNamespace=true`** | 图省事 | 单独管理，配合 ResourceQuota / LimitRange / NetworkPolicy |
| **测试覆盖率 / lint** | 只有 4 个测试 | ESLint、类型检查、覆盖率阈值门禁 |
| **CI 的 paths 过滤** | 只改文档也会构建一个镜像 | `on.push.paths` 排除 `**.md`；或把 docs 拆成单独 workflow。实测：本次文档提交 72528fb 就触发了一次完整构建 + 一次 dev bump，镜像内容跟上一版其实没差别 |
| **GHCR 私有性** | 仓库是 **public** 的 | 注意：`ghcr.io/oliveryang/argo-demo-app` 任何人可拉取。学习够用，别放公司代码 |

### 关于 Argo CD 与 Argo Rollouts

两者都属于 Argo 项目但解决不同问题：
- **Argo CD** = 声明式持续**交付**（Git → 集群）
- **Argo Rollouts** = 渐进式**发布策略**（金丝雀、蓝绿），替代 `Deployment`
本 demo 用原生 Deployment，因为先把 GitOps 主干搞明白。下一轮再加 Rollouts
会很顺 —— `/version` 端点和 label selector 就是为 Analysis 预留的接口。

---

## 7. 本仓库踩过的真实坑（含报错原文）

这些是这次搭建过程中**实际遇到并解决**的。它们比文档里的"注意事项"有用得多。

### CI / 镜像类

**① GHCR 拒绝大写仓库名**
```
buildx failed with: ERROR: failed to build: invalid tag
"ghcr.io/OliverYang/argo-demo-app:5cc89ec": repository name must be lowercase
```
GitHub 用户名是 `OliverYang`（驼峰），但 GHCR 路径必须全小写。修法：
```bash
image="${REGISTRY}/${GITHUB_REPOSITORY_OWNER,,}/argo-demo-app"   # bash 小写展开
```
> 教训：`${{ github.repository_owner }}` 保留原样大小写，registry 的路径规范不一定。

**② `npm install` 无依赖时不建 node_modules，COPY 炸**
```
failed to calculate checksum of ref ...: "/app/node_modules": not found
```
`COPY --from=deps /app/node_modules` 要求源目录存在。修法：`RUN mkdir -p node_modules && npm install`。

**③ Node 22 的 `node --test test/` 报 MODULE_NOT_FOUND**
```
Error: Cannot find module '/home/runner/work/argo-demo/argo-demo/app/test'
code: 'MODULE_NOT_FOUND'
```
CI 用 Node 22，本地是 Node 26 —— 本地传目录能过，CI 不过。
修法：`"test": "node --test"`（自动发现，跨版本稳定）。
> 教训：**永远不要用 `--local-node-version` 之外的方式假设本地和 CI 的 Node 行为一致。**

**④ 机器人自触发循环**
`bump-dev` 提交后如果不加 `[skip ci]`，会重新触发整条流水线，无限构建。
回滚时也必须加，否则回滚被随后的 CI 顶掉（见 3-②）。

### Kubernetes / Kustomize 类

**⑤ `commonLabels` 已废弃**
```
Warning: 'commonLabels' is deprecated. Please use 'labels' instead.
```
改用法：
```yaml
labels:
  - pairs:
      app.kubernetes.io/part-of: argo-demo
    includeSelectors: true     # 不加这行，Service 匹配不到 pod
```

**⑥ Argo CD 默认只 3 分钟轮询一次**
Git 改了但 `Sync Status` 不动，会让人以为同步坏了。手动：
```bash
argocd app get argo-demo-dev --insecure --refresh hard
```
生产上建议配 webhook（push 即触发），比调短轮询间隔更可控。

### 本机环境类（详见 ENVIRONMENT.md）

**⑦ Colima VM 没有 systemd-resolved，DNS 全废**
```
dial tcp: lookup registry-1.docker.io on [::1]:53: read udp ...: connection refused
```
`/etc/resolv.conf` 软链到 stub 文件，但 stub 服务不存在。修：`colima start --dns 114.114.114.114`。

**⑧ Docker Hub 不通**
```
Head "https://registry-1.docker.io/...": dial tcp ...: i/o timeout
```
配 `registry-mirrors`。`ghcr.io` / `quay.io` 直连可达，所以选 GHCR 是对的。

**⑨ `github.com` 解析到不可达 IP，Argo CD 拉不到仓库**
```
git fetch origin ... failed exit status 128:
Failed to connect to github.com port 443 after 75023 ms
# 以及
ComparisonError: failed to load target state: ... context deadline exceeded
```
DNS 给 `20.205.243.166`（不通），可用 IP 是 `140.82.112.3` / `140.82.113.3`。
本地 `git push` 改走 SSH；集群内 Argo CD 用 `hostAliases` 钉住可用 IP（已写进 `scripts/up.sh`）。
> 这类网络问题**不是 CI/CD 的知识**，但会伪装成 CI/CD 故障。先分层定位：
> 宿主机通不通 → VM 通不通 → pod 通不通，三层的结论完全不同。

---

## 8. 下一步学什么（按优先级）

1. **`EXERCISES.md` 里的实验** —— 先把漂移、回滚、晋升亲手再走一遍，
   看懂的 ≠ 会做的。
2. **Argo Rollouts 金丝雀** —— 给 `deploy/base` 换成 `Rollout`，配
   `AnalysisTemplate` 用 `/version` + Prometheus 指标自动决定晋升还是回滚。
   这是把"部署"变成"有判据的部署"的关键一步。
3. **ApplicationSet** —— 现在每个环境手写一个 Application；用
   `git-directory-generator` 让 `deploy/overlays/*` 每个目录自动生成，
   加环境不用改 Argo CD 配置。
4. **密钥管理** —— Bitnami Sealed Secrets，体验"secret 可以安全地提交进 Git"。
5. **换成真实的多集群** —— kind 起第二个集群，把 prod Application 的
   `destination.server` 指过去，理解 Argo CD 的 hub/spoke 模型。
6. **GitLab CI / Jenkins 对照** —— 你已经掌握了 pipeline / artifact /
   environment 这些抽象，换工具只是换语法。**别用工具名理解概念。**

---

## 9. 一页速查

```bash
# —— 这个仓库现在跑着什么 ——
kind cluster:        argo-demo
argocd:              ns=argocd，UI https://localhost:8080 (admin / .argocd-password)
environments:        argo-demo-dev (1 副本) / argo-demo-prod (3 副本)
image:               ghcr.io/oliveryang/argo-demo-app:<git-sha-7>   ← 不可变 tag
github repo:         github.com/OliverYang/argo-demo（public）

# —— 一次发布 ——
改代码 → git push → CI(test/build/bump) → Argo CD 自动 Sync → curl localhost:18090/

# —— 一次回滚 ——
只改 overlays/<env>/kustomization.yaml 的 newTag → commit -m "... [skip ci]" → push

# —— 一次晋升 ——
gh workflow run ci.yaml -f promote=true -f promote_tag=<已在 dev 验证过的 SHA>

# —— 出问题时先看这三个 ——
argocd app get <app> --insecure                       # Synced? Healthy?
argocd app diff <app> --insecure                      # Git 与集群差异
kubectl -n argocd logs deploy/argocd-repo-server --tail=50   # 拉仓库/渲染失败都在这
```

**如果只记三句话：**
1. Git 是唯一事实来源，集群里手工改的东西不算数。
2. 制品必须不可变（用 SHA，别用 `latest`），否则回滚无从谈起。
3. 部署 = 一次可 review 的 commit；回滚 = 一次前向 commit；晋升 = 移动同一个 tag，绝不重新构建。
