# ohos-ports

## 项目介绍

ohos-ports 致力于将 npm 生态中的三方库移植到 OpenHarmony（以下简称鸿蒙）平台。

项目采用 ports 模式——仓库中只维护补丁和构建脚本，不存储完整源码。当前 Node.js 运行时已经支持鸿蒙系统，大部分纯 JS 的 npm 包可直接运行，但使用 native addon 的包需要针对鸿蒙重新编译。理想情况下应直接向上游社区提 PR 支持鸿蒙，本项目则承载那些短期内无法合入上游、但社区又有迫切使用需求的包。

适配后的包统一发布到 npm 中心仓的 `@ohos-ports` scope 下，构建产物以社区版 OpenHarmony 为目标，通常也兼容 HarmonyOS 商用版本。


## 📦 已发布的包

当前 `ports/` 目录下维护的包（CI 流水线发布）：

<!-- PORTS_TABLE_START -->
| 包名 | 版本 | 安装 |
|------|------|------|
| @ohos-ports/better-sqlite3 | 13.0.3 | `npm i @ohos-ports/better-sqlite3` |
| @ohos-ports/bufferutil | 4.1.0-2 | `npm i @ohos-ports/bufferutil` |
| @ohos-ports/bun-pty | 0.4.10-1 | `npm i @ohos-ports/bun-pty` |
| @ohos-ports/lightningcss | 1.33.0-1 | `npm i @ohos-ports/lightningcss` |
| @ohos-ports/mermaid-cli | 11.16.0 | `npm i @ohos-ports/mermaid-cli` |
| @ohos-ports/opentui-core | 0.5.3 | `npm i @ohos-ports/opentui-core` |
| @ohos-ports/oxlint-tsgolint | 7.0.2001-1 | `npm i @ohos-ports/oxlint-tsgolint` |
| @ohos-ports/pprof | 5.17.0 | `npm i @ohos-ports/pprof` |
| @ohos-ports/puppeteer | 25.6.0-beta.0 | `npm i @ohos-ports/puppeteer` |
| @ohos-ports/resvg-js | 2.6.2 | `npm i @ohos-ports/resvg-js` |
| @ohos-ports/tailwindcss-oxide | 4.3.3-1 | `npm i @ohos-ports/tailwindcss-oxide` |
<!-- PORTS_TABLE_END -->

> 以上表格由 `python3 docs/update-packages.py` 自动生成，请勿手动编辑。

完整的 @ohos-ports 包列表（含本地发布的 Beta 包）请通过[在线查询页](https://ohos-ports.github.io/ohos-ports/)查看。

## 端到端运作流程

本项目采用 npm 分阶段发布（staged publishing）机制，CI 通过 NPM_TOKEN 认证执行 `npm stage publish`，发布后需维护者在 npmjs.com 上 2FA 审核通过后包才正式上线。

### 阶段一：适配开发（贡献者操作）

1. 在 `ports/<包名>/<版本>/` 目录下创建：
   ```
   patchs/
   └── 0001-xxx.patch    # 鸿蒙适配补丁
   build.sh               # 构建脚本
   publish.sh             # 发布脚本
   ```
2. 本地或容器中执行 `build.sh` 验证构建
3. 本地 `npm install` + 验证 `require`/`import` 可正常加载
4. 提交 PR 到主仓

### 阶段二：CI 自动构建和发布（GitHub Actions 自动执行）

PR 合入主仓后，CI 自动触发：

1. 检测 `ports/` 下变更的目录
2. 执行 `build.sh` 构建原生 addon
3. 执行 `publish.sh` → `npm stage publish`（通过 NPM_TOKEN 认证）
4. 维护者在 npmjs.com 审核通过（2FA）后，包正式上线

## 贡献指南

### 1. Fork 仓库

Fork 本仓库，在个人仓的 Settings → Actions 中启用工作流。

### 2. 准备构建环境

本项目的 CI 基于 OpenHarmony ARM64 容器运行。本地开发建议使用相同环境：

- 鸿蒙电脑（推荐）
- 或 [DockerHarmony](https://github.com/hqzing/dockerharmony) 容器（arm 服务器为佳）

构建过程中通常需要从 GitHub 下载源码，注意网络连通性。

### 3. 编写适配脚本

参考 `ports/bufferutil/4.1.0/` 的结构，在 `ports/<包名>/<版本>/` 下创建以下文件：

#### 目录结构

```
ports/<包名>/<版本>/
├── patchs/
│   └── 0001-update-package-json.patch   # 修改包名、仓库地址等
├── build.sh                              # 构建脚本（需可执行权限）
└── publish.sh                            # 发布脚本（需可执行权限）
```

#### patchs/ — 鸿蒙适配补丁

补丁用于将原始包的 `package.json` 中的 `name` 改为 `@ohos-ports/<包名>`，并更新仓库地址等信息。示例：

```diff
--- a/package.json
+++ b/package.json
@@ -1,5 +1,5 @@
 {
-  "name": "bufferutil",
+  "name": "@ohos-ports/bufferutil",
   "version": "4.1.0",
```

#### build.sh — 构建脚本

构建脚本负责下载源码、应用补丁、编译原生 addon、合并多平台预构建产物。典型流程：

```sh
#!/bin/sh
set -e

# 1. 下载上游源码
curl -fsSL https://github.com/<org>/<repo>/archive/refs/tags/v<version>.tar.gz -o <pkg>-<version>.tar.gz
tar -zxf <pkg>-<version>.tar.gz
rm <pkg>-<version>.tar.gz
cd <pkg>-<version>

# 2. 应用补丁
patch -p1 < ../patchs/0001-update-package-json.patch

# 3. 编译原生 addon（生成 prebuilds/<platform>-<arch>/@ohos-ports+<pkg>.node）
npm install
npm run prebuild

# 4. 从官方 npm 包复制其他平台的预构建产物
cd ..
curl -fsSL https://registry.npmjs.org/<pkg>/-/<pkg>-<version>.tgz -o <pkg>-<version>.tgz
tar -zxf <pkg>-<version>.tgz
rm <pkg>-<version>.tgz

cp -r package/prebuilds/* <pkg>-<version>/prebuilds/
rm -rf package

# 5. 重命名其他平台的 .node 文件为 scoped 格式
#    prebuildify 已自动为当前平台生成 @ohos-ports+<pkg>.node，无需处理
#    其他平台的文件需手动重命名
cd <pkg>-<version>/prebuilds
mv darwin-arm64/<pkg>.node darwin-arm64/@ohos-ports+<pkg>.node
# ... 其他平台同理
```

#### publish.sh — 发布脚本

发布脚本通过 `npm stage publish --provenance` 进行分阶段发布，`--provenance` 生成来源证明，CI 中通过 NPM_TOKEN 认证：

```sh
#!/bin/sh
set -e

cd <pkg>-<version>
npm stage publish --provenance --tag latest --access public
```

> stage 后包不会自动上线，需维护者在 npmjs.com 上 2FA 审核通过后正式发布。

### 5. 本地构建和验证

以下两种方式任选其一：

**方式一：通过容器构建**

```sh
# 启动鸿蒙容器
docker pull ghcr.io/hqzing/dockerharmony:latest
docker run -itd --name=ohos ghcr.io/hqzing/dockerharmony:latest

# 将仓库复制到容器中
docker cp ohos-ports ohos:/root

# 进入容器
docker exec -it ohos sh

# 准备环境
cd /root/ohos-ports
source setup-tools.sh
source setup-env.sh

# 构建
cd ports/<包名>/<版本>
./build.sh
```

**方式二：通过个人 Fork 仓的 GitHub Actions 调试**

将代码推送到个人 Fork 仓，CI 会自动触发构建。在 Actions 页面观察 `build.sh` 的执行日志，确认构建是否通过。`publish.sh` 因缺少 `NPM_TOKEN` 会失败，属正常行为。

> 构建后需验证包是否可用：新建一个测试项目，`npm install` 构建产物，确认能正常 `require`/`import`。

### 6. 提交 PR

将 PR 提到本仓库。PR 合入后，CI 会自动触发构建和发布。

### 注意事项

1. 根目录的 `setup-tools.sh` 和 `setup-env.sh` 可支撑常规构建环境配置。深度场景可自行在 `build.sh` 中编写环境配置命令。
2. 适配过程要注意兼容性，请勿破坏包在其他 OS 上的行为。
3. 发布软件包时建议使用 `x.y.z-1`、`x.y.z-2` 等修订版本号，便于在不改变 semver 版本的情况下迭代补丁。
4. 尊重他人知识产权，改包时请勿改动原有的作者和开源许可证信息。

## 鸣谢

本项目的构建和 CI 流水线基于 [DockerHarmony](https://github.com/hqzing/dockerharmony) 提供的 OpenHarmony 容器环境，感谢该项目为鸿蒙原生编译提供的标准化基础设施。

## 项目治理

- 本仓库中的包主要供临时使用，当包正式被上游官方接纳后，维护者会将其从本仓库中移除
- 若有问题咨询求助，可联系项目维护者：hongfeizheng@163.com