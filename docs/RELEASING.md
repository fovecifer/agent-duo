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
