# agent-duo Homebrew Tap 发布实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户能通过 `brew install fovecifer/agent-duo/agent-duo` 一条命令安装 agent-duo。

**Architecture:** 走"自建 Homebrew tap"路线（暂不提交 homebrew-core，未达 notability 门槛）。主仓库 `fovecifer/agent-duo` 打版本 tag 提供版本化 tarball；新建 tap 仓库 `fovecifer/homebrew-agent-duo`，其 `Formula/agent-duo.rb` 用 **libexec + wrapper** 模式安装：把整包（`bin/ lib/ docs/ start.sh`）装进 keg 的 `libexec`，再在 `bin` 生成两个入口（`peer`、`agent-duo-start`）。`tmux` 设为 `depends_on`；`claude`/`codex` 不作为 brew 依赖，仅在 `caveats` 提示。

**Tech Stack:** Bash、Homebrew Formula (Ruby DSL)、`gh` CLI、GitHub Actions。

---

## 背景事实（执行前必读，已由计划作者核实）

- 这是纯 shell 工具，**无编译**。产物：`bin/peer`、`start.sh`、`lib/inject.sh`、`docs/AGENT-INSTRUCTIONS.md`。
- `start.sh` 会解引用软链后，按自身目录定位 `bin/`、`lib/`、`docs/`（`SCRIPT_DIR` 逻辑），因此把整包放进 `libexec` 后，用绝对路径 `exec "#{libexec}/start.sh"` 启动即可正确找到同级目录。
- `bin/peer` **自包含**，不引用任何同级文件；其 `peer help` 实现是 `sed -n '2,12p' "$0"`。在 `bin.write_exec_script` 包装下 `$0` 指向 `libexec/bin/peer` 真身，注释完整，`peer help` 正常输出用法。
- License 为 **MIT**。
- 本机已具备：`gh`、`brew`、`tmux`（均在 `/opt/homebrew/bin`）。
- 主仓库 remote：`https://github.com/fovecifer/agent-duo.git`，当前**无任何 tag**。
- `start.sh -y`（或 `AGENT_DUO_AUTO_INJECT=1`）走非交互注入：当目标项目 `AGENTS.md` 无 peer 块时，会先写入 peer 协作块，**然后**才创建 tmux 会话（调 `tmux has-session`/`new-session`/`new-window`/`send-keys` 以及检查 `claude`/`codex` 是否在 PATH）。因此 `test do` 用 stub 即可在写入 `AGENTS.md` 后顺利跑完。

## 涉及/新增文件一览

主仓库 `~/workspace/agent-duo`：
- 修改：`README.md`、`README.zh-CN.md` —— 增加 brew 安装段落。
- 新增：`docs/RELEASING.md` —— 发版与同步 tap 的 runbook。

tap 仓库（由 `brew tap-new` 在 `$(brew --repository)/Library/Taps/fovecifer/homebrew-agent-duo` 生成）：
- 新增：`Formula/agent-duo.rb` —— 核心 formula。
- 修改：tap 自带的 GitHub Actions 工作流保持默认即可（`tests.yml`、`publish.yml`）。

## ⚠️ 对外不可逆动作（执行到这些步骤前请向用户确认）

1. **Task 2 - 推送 tag `v0.1.0`** 到 `fovecifer/agent-duo`（tag 一旦公开，tarball sha256 即固定，删除/重打 tag 是坏实践）。
2. **Task 6 - 创建 GitHub 仓库 `fovecifer/homebrew-agent-duo` 并 push**（创建公开仓库）。

其余步骤为本地操作，可自由重试。

---

## Task 1: 主仓库新增发版 runbook 文档

**Files:**
- Create: `docs/RELEASING.md`

- [ ] **Step 1: 写 `docs/RELEASING.md`**

写入以下完整内容：

````markdown
# 发版与 Homebrew tap 同步

agent-duo 通过自建 tap `fovecifer/agent-duo`（仓库 `fovecifer/homebrew-agent-duo`）分发。
安装方式：`brew install fovecifer/agent-duo/agent-duo`。

## 发布新版本

1. 确保 `master` 上测试通过：`bash test/run.sh`。
2. 打 tag 并推送（以 `v0.2.0` 为例）：

   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```

   GitHub 会自动在
   `https://github.com/fovecifer/agent-duo/archive/refs/tags/v0.2.0.tar.gz`
   提供版本化 tarball。

3. 计算该 tarball 的 sha256：

   ```bash
   curl -fsSL https://github.com/fovecifer/agent-duo/archive/refs/tags/v0.2.0.tar.gz \
     | shasum -a 256
   ```

4. 在 tap 仓库 `homebrew-agent-duo` 更新 `Formula/agent-duo.rb` 的 `url` 与 `sha256`，提交并推送。
5. 本地校验：

   ```bash
   brew update
   brew upgrade fovecifer/agent-duo/agent-duo
   brew audit --strict --online fovecifer/agent-duo/agent-duo
   brew test fovecifer/agent-duo/agent-duo
   ```

## 自动化（可选）

tap 仓库可加一个 workflow，监听本仓库 release 事件后自动 bump `url`/`sha256`，
再由 tap 自带的 `tests.yml` 跑 `brew test`/`brew audit`。见本仓库 `docs/RELEASING.md` 末尾说明。
````

- [ ] **Step 2: 校验文件已写入**

Run: `test -f docs/RELEASING.md && echo OK`
Expected: 输出 `OK`

- [ ] **Step 3: 提交**

```bash
git add docs/RELEASING.md
git commit -m "docs: add release runbook for Homebrew tap"
```

---

## Task 2: 打 v0.1.0 tag 并推送（⚠️ 对外动作）

**Files:** 无（git 操作）

- [ ] **Step 1: 确认测试通过**

Run: `bash test/run.sh`
Expected: 末尾输出 `ALL TESTS PASSED`，退出码 0。若失败，**停止**并报告用户。

- [ ] **Step 2: 确认工作区干净且在 master**

Run: `git status --short && git branch --show-current`
Expected: 无未提交改动（Task 1 已提交），分支为 `master`。

- [ ] **Step 3: 创建并推送 tag（向用户确认后执行）**

```bash
git tag v0.1.0
git push origin v0.1.0
```
Expected: `git push` 显示 `* [new tag] v0.1.0 -> v0.1.0`。

- [ ] **Step 4: 创建 GitHub Release（可选，让 tarball 入口更显眼）**

```bash
gh release create v0.1.0 --title "v0.1.0" \
  --notes "First Homebrew-installable release. Install: brew install fovecifer/agent-duo/agent-duo"
```
Expected: 输出 release 页面 URL。

- [ ] **Step 5: 拉取 tarball 计算 sha256（记录下来，Task 4 要用）**

```bash
curl -fsSL https://github.com/fovecifer/agent-duo/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
```
Expected: 输出一行 64 位十六进制 sha256。**记下这个值，记为 `<SHA256>`。**

---

## Task 3: 初始化 tap 仓库骨架

**Files:** 由命令生成于 `$(brew --repository)/Library/Taps/fovecifer/homebrew-agent-duo`

- [ ] **Step 1: 用 brew tap-new 生成 tap 骨架**

```bash
brew tap-new fovecifer/agent-duo --no-git
```
（`--no-git` 先不初始化 git，Task 6 再统一初始化并推送。若该 flag 不被支持，去掉它即可，后续 `git init` 时检测已存在的 `.git`。）
Expected: 提示在 `.../Library/Taps/fovecifer/homebrew-agent-duo` 创建了骨架，含 `Formula/` 目录与 `.github/workflows/`。

- [ ] **Step 2: 进入 tap 目录并确认结构**

Run:
```bash
TAP_DIR="$(brew --repository)/Library/Taps/fovecifer/homebrew-agent-duo"
ls -la "$TAP_DIR" && ls -la "$TAP_DIR/Formula" 2>/dev/null; ls "$TAP_DIR/.github/workflows" 2>/dev/null
```
Expected: 存在 `Formula/` 目录与 `.github/workflows/`（含 `tests.yml`、`publish.yml`）。记 `TAP_DIR` 备用。

---

## Task 4: 编写 Formula 并本地验证

**Files:**
- Create: `$TAP_DIR/Formula/agent-duo.rb`

- [ ] **Step 1: 写 `Formula/agent-duo.rb`**

把 `<SHA256>` 替换为 Task 2 Step 5 得到的真实值，写入下面完整内容：

```ruby
class AgentDuo < Formula
  desc "Make Claude Code and Codex CLI see each other's screens and talk to each other"
  homepage "https://github.com/fovecifer/agent-duo"
  url "https://github.com/fovecifer/agent-duo/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "<SHA256>"
  license "MIT"

  depends_on "tmux"

  def install
    libexec.install "bin", "lib", "docs", "start.sh"
    bin.write_exec_script libexec/"bin/peer"
    (bin/"agent-duo-start").write <<~EOS
      #!/bin/bash
      exec "#{libexec}/start.sh" "$@"
    EOS
  end

  def caveats
    <<~EOS
      agent-duo drives Claude Code and Codex CLI inside a tmux session.
      Install and log in to both CLIs first (they are NOT installed by this formula):
        Claude Code: https://docs.claude.com/claude-code
        Codex CLI:   https://github.com/openai/codex

      Then, from your project directory:
        agent-duo-start
        tmux -CC attach -t agents      # iTerm2 renders the two windows as native tabs
    EOS
  end

  test do
    # 用 stub 顶替真实 tmux/claude/codex，验证 Homebrew 包装后路径接线正确。
    (testpath/"stub").mkpath
    %w[tmux claude codex].each do |c|
      (testpath/"stub"/c).write <<~SH
        #!/bin/bash
        case "$1" in
          has-session) exit 1 ;;            # 报告会话不存在，让 start.sh 继续
          new-session|new-window) echo "%0" ;;  # 返回一个 pane id
        esac
        exit 0
      SH
      chmod 0755, testpath/"stub"/c
    end

    proj = testpath/"proj"
    proj.mkpath
    ENV.prepend_path "PATH", testpath/"stub"

    # 入口脚本应能定位 libexec 里的 lib/inject.sh 与 docs/，并向项目 AGENTS.md 注入 peer 块
    system bin/"agent-duo-start", "-y", proj
    assert_path_exists proj/"AGENTS.md"
    assert_match "peer", (proj/"AGENTS.md").read

    # peer 包装脚本在 keg 中应能正常打印用法（验证 write_exec_script 下 $0 指向真身）
    assert_match "peer peek", shell_output("#{bin}/peer help")
  end
end
```

- [ ] **Step 2: 语法/规范检查**

Run: `brew style fovecifer/agent-duo/agent-duo`
Expected: `1 file inspected, no offenses detected`（若有 offense，按提示修正后重跑）。

- [ ] **Step 3: 从源码安装 formula**

Run: `brew install --build-from-source fovecifer/agent-duo/agent-duo`
Expected: 安装成功，列出 `peer` 与 `agent-duo-start` 进入 `bin`。若提示 `tmux` 未装会自动作为依赖装上。

- [ ] **Step 4: 跑 formula 自带 test**

Run: `brew test fovecifer/agent-duo/agent-duo`
Expected: 测试通过，无报错。

- [ ] **Step 5: 在线审计**

Run: `brew audit --strict --online fovecifer/agent-duo/agent-duo`
Expected: 无 error。（warning 视情况修正；`url`/`sha256`/`desc`/`license` 必须无误。）

- [ ] **Step 6: 冒烟测试已安装的命令**

Run: `peer help && command -v agent-duo-start`
Expected: `peer help` 打印用法（含 `peer peek`）；`agent-duo-start` 解析到 brew 安装的包装脚本路径。

- [ ] **Step 7: 卸载以保持环境干净（Task 7 验证从远端 tap 重装）**

Run: `brew uninstall fovecifer/agent-duo/agent-duo`
Expected: 卸载成功。

---

## Task 5: 收敛 tap 仓库内容（README 等）

**Files:**
- Modify: `$TAP_DIR/README.md`（`brew tap-new` 已生成默认 README）

- [ ] **Step 1: 覆盖 tap 的 README**

写入：

```markdown
# fovecifer/homebrew-agent-duo

Homebrew tap for [agent-duo](https://github.com/fovecifer/agent-duo).

```sh
brew install fovecifer/agent-duo/agent-duo
```
```

- [ ] **Step 2: 确认 formula 就位**

Run: `ls "$TAP_DIR/Formula/agent-duo.rb" && echo OK`
Expected: 输出路径与 `OK`。

---

## Task 6: 创建 GitHub tap 仓库并推送（⚠️ 对外动作）

**Files:** 无（git/gh 操作，工作目录为 `$TAP_DIR`）

- [ ] **Step 1: 在 tap 目录初始化 git（若 Task 3 用了 --no-git）**

```bash
cd "$TAP_DIR"
git init -b main 2>/dev/null || true
git add -A
git commit -m "feat: add agent-duo formula (v0.1.0)"
```
Expected: 产生一个提交。

- [ ] **Step 2: 创建远端仓库并推送（向用户确认后执行）**

```bash
cd "$TAP_DIR"
gh repo create fovecifer/homebrew-agent-duo --public --source=. --remote=origin --push
```
Expected: 创建公开仓库 `fovecifer/homebrew-agent-duo` 并推送 `main`。

- [ ] **Step 3: 验证远端可见**

Run: `gh repo view fovecifer/homebrew-agent-duo --json url -q .url`
Expected: 输出仓库 URL。

---

## Task 7: 端到端验证「从远端 tap 全新安装」

**Files:** 无

- [ ] **Step 1: 移除本地开发态 tap，改用远端**

```bash
brew untap fovecifer/agent-duo 2>/dev/null || true
brew tap fovecifer/agent-duo
```
Expected: `brew tap` 从 GitHub 克隆 `homebrew-agent-duo`。

- [ ] **Step 2: 全新安装**

Run: `brew install fovecifer/agent-duo/agent-duo`
Expected: 安装成功（含 `tmux` 依赖）。

- [ ] **Step 3: 验证命令可用**

Run: `peer help && agent-duo-start --help 2>&1 | head -5 || true`
Expected: `peer help` 打印用法。（注：`start.sh` 无 `--help`，此处仅确认命令存在、不崩在路径问题上。）

- [ ] **Step 4: 跑 brew test 再确认一次**

Run: `brew test fovecifer/agent-duo/agent-duo`
Expected: 通过。

---

## Task 8: 主仓库 README 增加 brew 安装说明

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`

- [ ] **Step 1: 在 `README.md` 的安装章节顶部加入 Homebrew 方式**

在现有安装说明前插入：

```markdown
### Install with Homebrew (recommended)

```sh
brew install fovecifer/agent-duo/agent-duo
```

This installs the `peer` and `agent-duo-start` commands and pulls in `tmux`.
You still need to install and log in to Claude Code and Codex CLI separately.
```

（保留原有的 `git clone` + `./install.sh` 方式作为「from source」备选。）

- [ ] **Step 2: 在 `README.zh-CN.md` 对应位置加入中文版**

```markdown
### 用 Homebrew 安装（推荐）

```sh
brew install fovecifer/agent-duo/agent-duo
```

会安装 `peer` 与 `agent-duo-start` 命令，并自动装上 `tmux`。
Claude Code 与 Codex CLI 仍需你自行安装并登录。
```

- [ ] **Step 3: 校验改动**

Run: `grep -n "brew install fovecifer/agent-duo" README.md README.zh-CN.md`
Expected: 两个文件各命中一处。

- [ ] **Step 4: 提交**

```bash
git add README.md README.zh-CN.md
git commit -m "docs: add Homebrew install instructions"
```

- [ ] **Step 5: 推送 master（向用户确认后执行）**

```bash
git push origin master
```
Expected: 推送成功。

---

## 完成判定（Definition of Done）

- [ ] `brew install fovecifer/agent-duo/agent-duo` 在干净环境可一条命令成功安装。
- [ ] `peer help` 与 `agent-duo-start` 安装后可用。
- [ ] `brew audit --strict --online` 与 `brew test` 均通过。
- [ ] tap 仓库 `fovecifer/homebrew-agent-duo` 已公开，`Formula/agent-duo.rb` 的 `url`/`sha256` 指向 `v0.1.0`。
- [ ] 主仓库 README（中英）含 brew 安装说明，`docs/RELEASING.md` 记录后续发版流程。

## 备注 / 给执行者的提醒

- `sha256` 必须用 Task 2 实际拉取的 tarball 计算，**不要**手写或复用旧值。
- 若 `brew tap-new` 的 `--no-git` 不被你的 Homebrew 版本支持，去掉该 flag；它会自带 `.git`，Task 6 Step 1 改为 `cd "$TAP_DIR"` 后直接 `git add -A && git commit`。
- 不要在 formula 里调用项目的 `install.sh`——它面向用户 HOME 做软链，违反 Homebrew「只往 keg 写文件」的约定。
- `claude`/`codex` 故意**不**做成 brew 依赖（它们不在 homebrew-core 且需登录），仅在 `caveats` 提示。
- 两处对外动作（推 tag、建仓库并推送）执行前请按计划向用户确认。
