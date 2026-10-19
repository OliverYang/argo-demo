# 实验手册

README 讲的是"为什么"，这里是你**自己动手**的部分。每个实验都写了预期观察点——
如果实际看到的和预期不一样，那才是最有价值的时刻，把报错记下来。

约定：所有 `argocd` 命令都在已 `argocd login localhost:8080 --insecure --grpc-web` 之后运行。
需要两个终端：一个跑 `scripts/port-forward.sh`，一个做实验。

---

## 实验 1：漂移 — 让集群和 Git 打架（15 分钟）

**目的**：理解 GitOps 的"唯一事实来源"到底意味着什么。

```bash
# 1. 先确认现状
kubectl -n argo-demo-dev get deploy argo-demo -o jsonpath='{.spec.replicas}{"\n"}'   # 期望 1

# 2. 手工扩容（模拟"有人紧急 kubectl scale 了一下"）
kubectl -n argo-demo-dev scale deploy/argo-demo --replicas=3

# 3. 立刻确认改成功了
kubectl -n argo-demo-dev get deploy argo-demo -o jsonpath='{.spec.replicas}{"\n"}'   # 期望 3

# 4. 观察 Argo CD 把它拉回
for i in $(seq 1 12); do sleep 5;
  R=$(kubectl -n argo-demo-dev get deploy argo-demo -o jsonpath='{.spec.replicas}');
  echo "t=$((i*5))s replicas=$R"; [ "$R" = "1" ] && break; done

# 5. 现在把 selfHeal 关掉，重跑一次，看区别
kubectl -n argocd patch application argo-demo-dev --type json \
  -p '[{"op":"replace","path":"/spec/syncPolicy/automated/selfHeal","value":false}]'
kubectl -n argo-demo-dev scale deploy/argo-demo --replicas=3
argocd app get argo-demo-dev --insecure | grep -E "Sync Status|Health"
# 期望：OutOfSync —— 漂移被"看见"但不被"修正"
```

**思考题**
- 关掉 selfHeal 后 `OutOfSync` 出现了。如果 selfHeal 开着，你会知道有人手工改过 prod 吗？
  （这就是为什么很多人主张：**prod 开 selfHeal 但必须同时开通知**，
  否则漂移被静默修正，你丢掉了"有人在绕过流程"这个信号。）
- 如果 Git 里写 `replicas: 1`，但 HPA 也在改 replicas，会发生什么？
  （提示：这是 GitOps 的经典冲突，Argo CD 有 `ignoreDifferences` 可以豁免字段。动手试试。）

```bash
# 做完恢复原状
kubectl -n argocd patch application argo-demo-dev --type json \
  -p '[{"op":"replace","path":"/spec/syncPolicy/automated/selfHeal","value":true}]'
```

---

## 实验 2：回滚 — 先撞墙，再理解为什么（20 分钟）

**目的**：亲手验证 `argocd app rollback` 与 auto-sync 的互斥关系。

```bash
# 1. 看部署历史（ID 就是回滚目标）
argocd app history argo-demo-dev --insecure

# 2. 试直觉做法 —— 你会拿到这个报错
argocd app rollback argo-demo-dev <某个ID> --insecure
# rollback cannot be initiated when auto-sync is enabled

# 3. 用正确做法：改 Git
# 先看当前 tag
grep newTag deploy/overlays/dev/kustomization.yaml
# 找出一个之前构建过的 SHA
git log --oneline --all | grep "chore(dev)"

# 只改这一行，不要改代码
$EDITOR deploy/overlays/dev/kustomization.yaml
git commit -am "chore(dev): rollback to <SHA> [skip ci]"
git push

# 4. 验证：CI 没有跑（[skip ci] 生效），Argo CD 同步了
gh run list --limit 1          # 最新一条应该是你回滚之前的
argocd app get argo-demo-dev --insecure | grep "Sync Status"
curl -s localhost:18090/version
```

**思考题**
- 如果你**忘了**写 `[skip ci]` 会怎样？推理一遍：push → 触发 CI → 构建新 SHA →
  bump-dev 把 newTag 改成新 SHA → 你的回滚发生了什么？
- `argocd app rollback` 在什么情况下是可用的？（关掉 automated sync 之后。
  那什么时候该真的关掉 automated sync？—— 见实验 3。）

---

## 实验 3：晋升 — 验证"不重新构建"（20 分钟）

```bash
# 1. 记录 dev 当前 tag（这必须是你验证过的产物）
grep newTag deploy/overlays/dev/kustomization.yaml

# 2. 把这个 tag 晋升到 prod
gh workflow run ci.yaml --ref main -f promote=true -f promote_tag=<dev 的 tag>
RUN=$(gh run list --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch $RUN --exit-status

# 3. 关键验证：Build 和 bump-dev 必须是 skipped
gh run view $RUN --json jobs -q '.jobs[] | "\(.name): \(.conclusion)"'

# 4. 等 Argo CD 同步 prod
argocd app get argo-demo-prod --insecure --refresh hard
argocd app get argo-demo-prod --insecure | grep -E "Sync Status|Health"

# 5. 对比两个环境跑的是同一个字节
kubectl -n argo-demo-dev  get deploy argo-demo -o jsonpath='DEV  {.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n argo-demo-prod get deploy argo-demo -o jsonpath='PROD {.spec.template.spec.containers[0].image}{"\n"}'
# 期望：完全相同的 tag，但 env 变量不同、副本数不同
```

**思考题**
- dev 和 prod 的镜像 tag 相同，`env` 字段不同。这说明环境差异存在于哪一层？
  （答：部署清单，不在制品里。这就是"同一个制品晋级到多环境"能成立的前提。）
- 真实 prod 你会怎么加人工审批？列出至少两种做法。
  （提示：① prod overlay 改动要求 PR + CODEOWNERS，Argo CD 只看 main 分支，
  于是 review 就是门禁；② prod Application 关掉 `automated`，
  改用 UI/CLI 手动点 Sync；③ Argo CD 的 Sync Windows。）

---

## 实验 4：故意制造失败 — 这是最重要的实验（30 分钟）

只跑成功路径学不到东西。逐个制造这些故障，**每次都先猜会看到什么，再去看**：

### 4a. 测试挂掉
```bash
echo "assert.strictEqual(1, 2);" >> app/test/server.test.js
git commit -am "break: bad test" && git push
gh run watch --exit-status
```
观察：`Build & Push` / `Bump dev` 都变成 skipped。
**结论**：CI 的门禁作用在**第一道**，坏代码连镜像都产不出，Git 里的 tag 不会变，集群不会动。

### 4b. 清单语法坏掉
```bash
# 在 base/deployment.yaml 里删掉一个冒号或缩进错一格
$EDITOR deploy/base/deployment.yaml && git commit -am "break: bad yaml" && git push
gh run watch --exit-status
```
观察：`test` job 的 `Validate kustomize overlays render` 步骤失败 —— 在 CI 就挡住了。

现在**绕过 CI 直接改集群**看看后果：
```bash
kubectl -n argocd patch application argo-demo-dev --type json \
  -p '[{"op":"replace","path":"/spec/source/path","value":"deploy/overlays/nonexistent"}]'
argocd app get argo-demo-dev --insecure
```
观察：`ComparisonError`，`Sync Status: Unknown`，但**应用还在正常运行**。
**结论**：CD 失败通常不影响已运行的服务 —— 这是声明式系统的一个重要性质
（不像脚本式部署，中途失败会留下半个状态）。

### 4c. 镜像不存在
```bash
sed -i '' 's/newTag: .*/newTag: deadbeef/' deploy/overlays/dev/kustomization.yaml
git commit -am "chore(dev): deploy deadbeef [skip ci]" && git push
argocd app get argo-demo-dev --insecure --refresh hard
```
观察：`Synced`（清单和 Git 一致！）但 `Health: Degraded`，pod `ImagePullBackOff`。
```bash
kubectl -n argo-demo-dev get pods
kubectl -n argo-demo-dev describe pod <pod> | tail -12
```
**结论**：这就是 Sync ≠ Health 的活教材。然后回滚你刚制造的故障（实验 2 的手法）。

---

## 实验 5：读懂 diff（10 分钟）

GitOps 最实用的一条命令：

```bash
# 先造一个差异
kubectl -n argo-demo-dev annotate deploy/argo-demo manual=true --overwrite
argocd app diff argo-demo-dev --insecure
kubectl -n argo-demo-dev annotate deploy/argo-demo manual-   # 清掉
```

再看一次"将要发生什么"：
```bash
argocd app get argo-demo-dev --insecure -o json | jq '.status.resources'
```

**练习**：把这个 diff 输出解释给同事听 —— "Git 里说应该是 A，集群现在是 B，
同步会把 B 变成 A"。能讲清这句话，GitOps 就入门了。

---

## 实验 6：加第三个环境 staging（30 分钟）

综合检验你是否真的理解了目录结构：

```bash
mkdir -p deploy/overlays/staging
cp deploy/overlays/dev/kustomization.yaml deploy/overlays/staging/
# 改：namespace: argo-demo-staging，ENV_NAME=staging，replicas=2
cp argocd/dev-app.yaml argocd/staging-app.yaml
# 改：name/namespace/path 三处
```

需要改 CI 吗？**想一想再动手**——如果 staging 也应该每次 push 自动跟上最新版，
就要加一个 `bump-staging` job；如果 staging 只接收从 dev 晋升的版本，
就复用 `promote-prod` 的模式加个 `promote=staging` 输入。

这两种选择对应真实世界的两种流派，没有标准答案，只有取舍。

---

## 实验 7（进阶）：换掉一个工具，验证你的概念是否牢固

学 CI/CD 最大的风险是把工具当概念。做个自检：

- [ ] 把这套东西的 CI 换成 **GitLab CI**：`.gitlab-ci.yml` 的
      `stages: [test, build, deploy]` 分别对应哪 4 个 job？
      `GITHUB_TOKEN` 换成什么？`ghcr.io` 登录怎么写？
- [ ] 把 **Kustomize 换成 Helm**：`base/` 变成 `templates/`，
      overlay 变成 `values-dev.yaml` / `values-prod.yaml`。
      CI 里 `kustomize edit set image` 换成什么？
      （提示：Helm 需要 Argo CD 的 `helm.valueFiles` 或 `helm.parameters`）
- [ ] 把 **Argo CD 换成 Flux**：`Application` → `Kustomization` + `GitRepository`
      两个 CR。selfHeal → `spec.sync.strategy` + `driftDetection`。
- [ ] 不用 kind，把集群换到 **EKS/GKE**：哪些东西要变？
      （destination.server、镜像仓库、Ingress、StorageClass、以及 IRSA/IAM）

每一项都能做，说明你掌握的是抽象；某一项做不动，回去补那块的概念。

---

## 附：这次搭建的完整时间线（当作"故障排查思路"参考）

真实记录，包括失败。排错的能力比背命令值钱。

| 动作 | 结果 | 根因 |
|---|---|---|
| `docker run hello-world` | ❌ DNS refused | Colima VM 无 systemd-resolved → `--dns` |
| 加 `--dns` 后重试 | ❌ i/o timeout | Docker Hub 被墙 → registry-mirrors |
| 配 mirrors | ✅ | — |
| `kind create cluster` | ✅ | 镜像从 mirror 拉到了 |
| 装 Argo CD | ✅（需 `--server-side`）| 清单太大，client-side apply 冲突 |
| `argocd login 8080 --plaintext` | ❌ 连接重置 | 默认 443→8443 是 TLS 端口 → 改 svc targetPort |
| `--insecure --plaintext` | ❌ x509 | 端口走 TLS，去掉 `--plaintext` |
| `--insecure --grpc-web` | ✅ | — |
| CI 第 1 次 | ❌ MODULE_NOT_FOUND | Node 22 与 26 的 `--test` 行为差异 |
| CI 第 2 次 | ❌ name must be lowercase | GHCR 路径要小写 |
| CI 第 3 次 | ❌ node_modules not found | `npm i` 无依赖时不建目录 |
| CI 第 4 次 | ✅ 全绿 | — |
| 部署后 `/version` 返回 dev | ⚠️ | 版本靠 env 注入 → 改成 build-arg 烧进镜像 |
| prod 长期 `Unknown` | ❌ | `github.com` 解析到不可达 IP → hostAliases |
| 加 hostAliases `140.82.113.3` | ❌ 仍超时 | 网络在漂，该 IP 失效 |
| 换 `140.82.112.3` + 重试 refresh | ✅ Synced | — |

**三条可复用的排查原则：**

1. **分层定位网络问题**：宿主机 → VM → pod，三层的结论完全不同。
   本项目里宿主机 SSH 通、HTTPS 不通，VM 里 mirrors 能救，
   pod 里只能靠 hostAliases —— 每一层修法都不一样。
2. **报错原文里有答案**：`repository name must be lowercase`、
   `"/app/node_modules": not found` 都是直接可执行的提示。别只盯 exit code。
3. **"能跑"不等于"跑对了"**：CI 全绿、Argo CD Synced、pod Healthy，
   但 `/version` 返回 `dev` 说明制品身份没绑住。
   **要主动验证不变式**，不要只看绿灯。
