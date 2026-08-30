# 技能整合进权威源 + 提交 PR —— 交接文档

日期：2026-08-30
交接人：前一线 agent（多轮对话结束，文件已丢失，需重建）
接收人：接手此任务的新 agent

---

## 一、任务目标（一句话）

把 superpowers（至少 `brainstorming`、`writing-plans`）和 mattpocock（`grill-with-docs`、`grilling`、`domain-modeling`、`tdd`、`implement`、`to-tickets`、`implement-spec`、`code-review` 等）的技能，重新获取并放入 `/workspace/.agents/skills/` 这个**权威源**（持久化、git 跟踪），用现有同步脚本分发到各 agent 目录，最后在 `feat/skill-sync-script` 分支上提交并提 PR 到 `tmoonlight/acecode`。

---

## 二、当前已知事实（必须如实核对，勿依赖本对话上下文）

1. **工作分支**：`feat/skill-sync-script`（基于 master，干净重做）。
2. **最近一次提交 `41253a0`** 只包含两样，不含任何 skill：
   - `A  .agents/scripts/sync-skills.sh`（技能同步脚本，copy 复制式）
   - `R  .acecode/skills/acecode-release/* -> .agents/skills/acecode-release/*`（迁移进权威源）
3. **权威源 `.agents/skills/` 目前 10 个技能**：
   `acecode-frontend-style`, `acecode-release`, `openspec-apply-change`, `openspec-archive-change`, `openspec-explore`, `openspec-propose`, `source-command-opsx-apply`, `source-command-opsx-archive`, `source-command-opsx-explore`, `source-command-opsx-propose`
   → **没有 brain/matt 系技能**。
4. **关键问题**：brainstorming / Matt 系技能（含整合版 `design-gate`、`brainstorming`）在磁盘上**已全部丢失**，且**不在任何 git 分支/对象里**（`git log --all`、`git rev-list --objects` 全盘搜索无匹配）。之前那些 `feat: Install...` 提交是空提交，未真正写入技能文件。
5. **远程**：`origin` = `https://github.com/LIUXIN557/acecode`（你的 fork）。目标上游 PR = `tmoonlight/acecode` 的 `master`。
6. **token**：已给出 fine-grained PAT，现存在于 `/tmp/ght`（权限 600，一次会话有效，容器重启即丢）。`gh` 已登录为账户 `LIUXIN557`。
   - **已验证**：token 对 `LIUXIN557/acecode` 的 `Pull requests` **只有只读**（`GET pulls` 200，`createPullRequest` 被拒 403/GraphQL）。
   - 分支推送：已成功（远程 `feat/skill-sync-script` = `41253a0`）。

---

## 三、任务步骤

### 步骤 0：核对现状
先自己跑一遍确认，不要信本文档结论：
```bash
cd /workspace
git branch --show-current
git log --oneline -3
ls .agents/skills/
grep -riE 'brainstorming|grilling|grill-with-docs' . --include=SKILL.md   # 应无匹配
```

### 步骤 1：重新获取技能源码
从上游拉取（网络经 egress，用 git clone；若失败看 `HTTP_PROXY`）：
- Superpowers：`obra/superpowers`（`skills/brainstorming/SKILL.md`、`skills/writing-plans/SKILL.md`，注意其依赖 `elements-of-style`）。
- Matt Pocock：`mattpocock/<skill 仓库>`（含 `grill-with-docs`、`grilling`、`domain-modeling`、`tdd`、`implement`、`to-tickets`、`implement-spec`、`code-review`、`diagnosing-bugs`、`improve-codebase-architecture`、`setup-matt-pocock-skills`，注意 `grill-with-docs` 是薄壳依赖 `grilling`+`domain-modeling`）。
- 每技能通常含 `agents/*.yaml`（Claude 专属）——复制时可排除。
- 拿到后**先验证 skill 立即可用**（读取完整 SKILL.md 与依赖），再落位。

### 步骤 2：放入权威源
把选定的技能源复制进 `/workspace/.agents/skills/<name>/`（分类可参照：`engineering/`、`productivity/`、`superpowers/`、`workflow/`）。**不要放各 agent 目录**——权威源是唯一来源。

### 步骤 3：同步到各 agent 目录
```bash
bash .agents/scripts/sync-skills.sh       # copy 到目标；交互冲突处理 overwrite/absorb/skip
```
执行后核对各目标目录（`.claude/skills`、`.codex/skills`、`.acecode/skills`）出现对应技能。

### 步骤 4：提交
在 `feat/skill-sync-script` 分支上 stage 技能源（**只加 `.agents/skills/**`，不要加各 agent 的同步副本、zip、`.trae-html-share-packages`、openai.yaml 等杂音**），提交信息参考仓库风格（`feat: ...` 短命令式）。

### 步骤 5：推送 + 提 PR
- 推送：`git push -u origin feat/skill-sync-script`（用 gh 已登录身份；若 git 直接失败，先 `gh auth setup-git`）。
- 提 PR：`gh pr create --repo tmoonlight/acecode --base master --head LIUXIN557:feat/skill-sync-script --title ... --body ...`
- **已知阻塞**：token 只有 PR 只读权限，`createPullRequest` 会被拒。请先请求用户把 token 的 `Pull requests` 权限提升为 **Write**（https://github.com/settings/personal-access-tokens ），或改用用户在网页手动提 PR（https://github.com/LIUXIN557/acecode/compare/master...feat/skill-sync-script ，并把 base 切到 `tmoonlight/acecode` 的 `master`）。

---

## 四、注意事项 / 坑

- **别依赖本会话上下文**：技能文件已丢，必须重新获取，别假设工作树里已有。
- **权威源唯一性**：只往 `.agents/skills/` 放源；各 agent 目录由脚本幂等同步，内容一致时跳过。
- **git 忽略/计时**：`.trae-html-share-packages` 的 zip、各 agent 同步副本、`openai.yaml`（Claude 专属）不应进 PR。
- **安全**：token 在 `/tmp/ght`，属一次会话、权限 600，勿提交进 git、勿写入仓库内可被跟踪路径；清理由新 agent 自行决定。
- **脚本设计**：默认 skip（非交互），带 `--dry-run` / `--targets=`；交互三选一 overwrite/absorb/skip；`PRESERVE` 机制现为空。
- **上游技能可能随时更新**：本任务只是"重建当前想要的一套"，非锁定某版本。

---

## 五、验收清单

- [ ] `.agents/skills/` 出现 brainstorm + Matt 系技能源，且 SKILL.md 完整可读、依赖存在
- [ ] `sync-skills.sh` 运行后各 agent 目录同步到位
- [ ] `feat/skill-sync-script` 分支有新提交，仅含权威源技能 +（必要时）脚本改动，无杂音文件
- [ ] git push 成功
- [ ] 向 `tmoonlight/acecode` 成功创建 PR（或已请用户在网页创建），附可复制的标题+描述