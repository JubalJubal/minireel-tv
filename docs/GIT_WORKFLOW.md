# Git 工作流

MiniReel 采用**主干开发 + 标签发布**：只有 `main` 一条长期分支，日常改动直接提交到 `main`，正式发布通过推送 `v*` 版本标签触发流水线。

## 一、分支模型

| 分支 | 用途 | 生命周期 |
| --- | --- | --- |
| `main` | 唯一长期分支，始终保持可发布状态 | 永久 |
| `try/<主题>`（可选） | 临时试验，完成后变基回 `main` 并删除 | 数天以内 |

约定：

- 不建立 `develop`、`release/*`、`hotfix/*` 等长期分支，需要时用 `try/*` 短分支代替。
- `main` 上的每一次提交都应通过 CI（`flutter analyze`、`flutter test`、发布工具单测）。
- 历史保持线性：用变基同步远端，不产生无意义的合并提交。

## 二、一次性配置

克隆仓库后执行一次（可重复运行，只写入本仓库的 `.git/config`）：

```powershell
# Windows PowerShell 5.1（若提示「禁止运行脚本」，-ExecutionPolicy Bypass 即可绕过）
powershell -ExecutionPolicy Bypass -File tool\setup-git-workflow.ps1 -UserName "你的名字" -UserEmail "你的邮箱"

# PowerShell 7+
pwsh -File tool/setup-git-workflow.ps1 -UserName "你的名字" -UserEmail "你的邮箱"
```

写入的配置项：

| 配置 | 值 | 作用 |
| --- | --- | --- |
| `init.defaultBranch` | `main` | 新建仓库时默认分支名为 `main` |
| `pull.rebase` | `true` | 拉取时变基，避免产生合并提交 |
| `fetch.prune` | `true` | 拉取时清理远端已删除的分支引用 |
| `push.default` | `simple` | 只推送同名分支 |
| `push.autoSetupRemote` | `true` | 新分支首次推送自动建立上游跟踪 |
| `core.autocrlf` | `false` | 换行符完全交给 `.gitattributes` 决定 |
| `commit.template` | `.gitmessage` | `git commit` 时自动带出提交信息模板 |
| `merge.ff` | `only` | 禁止本地产生合并提交，保证线性历史 |
| `rerere.enabled` | `true` | 记住冲突的解决方式，重复变基时自动复用 |
| `tag.sort` | `-version:refname` | 标签按版本号排序 |

> 这些配置全部是仓库级的，不会影响你机器上的其他项目。

## 三、日常流程

```powershell
git switch main
git pull --rebase

# ...修改代码...

git add <改动的文件>
git commit                 # 编辑器会自动载入 .gitmessage 模板
git push
```

如果同时在改多个互不相关的功能，可以用短分支隔离：

```powershell
git switch -c try/settings-layout
# ...提交...
git switch main
git rebase try/settings-layout    # 线性并入 main
git branch -d try/settings-layout
git push
```

## 四、提交信息规范

格式：

```
<type>(<scope>): <50 字以内的简短描述>

为什么做这个改动

怎么验证
```

`type` 取值：

| type | 用途 |
| --- | --- |
| `feat` | 新功能 |
| `fix` | 修复缺陷 |
| `perf` | 性能优化 |
| `refactor` | 重构，不改变外部行为 |
| `docs` | 文档 |
| `test` | 测试 |
| `build` | 构建脚本、依赖、打包 |
| `ci` | CI/CD 配置 |
| `chore` | 杂项维护 |
| `revert` | 回滚 |

`scope` 可选，常用值：`player`、`library`、`settings`、`windows`、`android`、`tv`、`ci`、`deps`。

示例：

```
feat(player): 竖屏上下滚动翻集时预缓存下一集首帧

滚动翻集前提前拉起下一集的媒体与首帧解码，减少翻页后的等待时间。
预缓存复用横屏连播的同一套缓存，不额外增加内存占用。

在 Android 12 真机上连续翻 20 集，首帧等待从约 600ms 降到 200ms 以内。
```

破坏性变更在标题的 `type` 后加 `!`，并在正文写 `BREAKING CHANGE:` 说明。关联议题在正文末尾单独一行写 `Closes #123`。

## 五、发布流程

版本号的唯一事实来源是 `pubspec.yaml` 的 `version: <name>+<build>`。

1. 更新 `pubspec.yaml`：

   ```yaml
   version: 0.2.6+8
   ```

2. 提交这次版本变更：

   ```powershell
   git commit -am "chore(release): 0.2.6"
   git push
   ```

3. 打注解标签并推送（标签必须匹配 `v<major>.<minor>.<patch>`，可带 `-beta.1` 这类预发布后缀）：

   ```powershell
   git tag -a v0.2.6 -m "MiniReel 0.2.6"
   git push origin v0.2.6
   ```

   也可以一步推送提交和标签：`git push --follow-tags`

4. 推送标签后，`.github/workflows/release.yml` 会依次：

   - 用 `tool/release.cjs metadata` 校验标签格式，并推导版本号、构建号与是否预发布；
   - 在 Windows 上构建安装包，在 Ubuntu 上构建并校验 6 个签名 APK（phone / tv × 三种 ABI）；
   - 生成 `SHA256SUMS.txt`，创建草稿 Release 后上传产物并转为正式发布。

标签格式不合法时流水线会在 metadata 阶段直接失败，请用 `v0.2.6`、`v0.2.6-beta.1` 这样的写法。

## 六、CI 一览

| 工作流 | 触发条件 | 作用 |
| --- | --- | --- |
| [ci.yml](../.github/workflows/ci.yml) | 推送到 `main`、面向 `main` 的 PR、手动触发 | 安装依赖，校验发布工具，运行 `flutter analyze` 与 `flutter test` |
| [build-tv-v7a.yml](../.github/workflows/build-tv-v7a.yml) | 推送到 `main`（限 `lib/**`、`android/**`、`pubspec.yaml` 等路径）或手动触发 | 构建 Android TV APK 并创建 Release |
| [release.yml](../.github/workflows/release.yml) | 推送 `v*` 标签 | 构建 Windows 安装包与 6 个 APK，发布正式 Release |

> `build-tv-v7a.yml` 目前会在 `main` 有新提交时自动发一个 TV 包，属于「每次提交都可能发布」的行为。若希望严格只在打标签时发布，把它的 `on.push` 段删掉、只保留 `workflow_dispatch` 即可。

## 七、提交前自查

- `flutter analyze --no-pub --no-fatal-infos` 与 `flutter test test --no-pub` 通过；改了 `tool/release.cjs` 时另外跑 `node --test tool/release.test.cjs`。
- 提交前用 `flutter pub get --enforce-lockfile` 确认本地 Flutter 版本与 `pubspec.lock` 一致（CI 固定 Flutter 3.41.9）。
- 没有把签名材料带进提交：`*.jks`（`android/app/minireel-release.jks` 除外）、`key.properties`、`ANDROID_SIGNING_SECRETS.txt`、`.env` 都已被 `.gitignore` 覆盖。
- 换行符交给 `.gitattributes`，不要手动改 CRLF/LF。
- 大文件、构建产物（`build/`、`output/`、`*.apk`）不入库。
- 版本号只在准备发布时修改，避免日常提交顺带 bump。
