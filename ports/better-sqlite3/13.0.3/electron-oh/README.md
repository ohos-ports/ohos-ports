# better-sqlite3 13.0.3：Electron-OH 37.2.0

在已有鸿蒙 Node port 上，增加显式启用的 Electron-OH arm64 原生文件。
沿用现有 0001/0002 补丁，不新增 C++/JS 逻辑修改；默认加载器、Node build.sh
和 Node 二进制保持不变。应用使用上游已有的 nativeBinding 参数。

## 支持范围与版本

已验证组合：OpenHarmony arm64、Electron-OH 37.2.0、内置 Node 22.17.0、N-API 10。
独立 Node 回归使用鸿蒙 Node 24.13.0。版本号相同的运行时也须校验实际文件哈希。

上游源码和 npm 预发布包均以 13.0.3 为基线；候选 npm 包版本为
`13.0.3-electron-oh.0`，独立 dist-tag 为 `electron-oh`。应用显式安装该预发布版本
或 electron-oh tag，原 Node 包的 latest 保持不变。当前不发布。

## 仓库目录与文件职责

新增实现集中在与 patchs 同级的 electron-oh/，原 Node 构建和发布入口保留原位置：

```text
ports/better-sqlite3/13.0.3/
├── build.sh                         原 Node 构建入口
├── publish.sh                       Node 发布入口，增加重复发布保护
├── patchs/
│   ├── 0001-update-package-json.patch
│   ├── 0002-openharmony-platform-support.patch
│   └── 0003-electron-oh-package.patch
└── electron-oh/
    ├── .gitignore
    ├── README.md
    ├── build-electron-oh.sh
    ├── electron-oh.lock.json
    ├── node-api-headers.lock.json
    ├── examples/main.cjs
    ├── tests/
    └── tools/
```

| 文件（相对 electron-oh/） | 功能 |
| --- | --- |
| .gitignore | 排除本目录下载基线、临时包及 Python 缓存。 |
| README.md | 构建、依赖来源、HAP 接入和验证说明；打包时复制为包根目录 README.electron-oh.md。 |
| build-electron-oh.sh | 独立构建入口，按脚本自身目录调用 Python，不依赖调用者工作目录。 |
| electron-oh.lock.json | 固定包版本、Electron/Node/N-API、shim、运行时及 addon 源码身份。 |
| node-api-headers.lock.json | 固定四份公开 Node-API 头文件的 SHA-256。 |
| release-materials.lock.json | 固定完整许可文本身份，记录 shim 授权与签名决策的实际状态。 |
| licenses/* | 保留 Node、node-addon-api 及实测 SDK 的完整许可/notice 文本。 |
| RELEASE.md | 发行缺口、签名策略、补证方法及正式发布顺序。 |
| release-evidence.example.json | 最终包、双宿主运行及 HAP 验签报告模板；不是已通过的证据。 |
| examples/main.cjs | Electron 主进程使用 nativeBinding 的精简接入示例。 |
| tests/database-smoke.cjs | 两宿主共用的真实 SQL、事务、UDF、聚合、BigInt 等断言。 |
| tests/electron-oh-smoke.cjs | 检查 Electron 宿主、实际原生文件哈希并执行共享断言。 |
| tests/node-smoke.cjs | 在独立鸿蒙 Node 中检查原默认加载路径，不传 nativeBinding。 |
| tests/verify-package.py | 对比 registry 基线与候选 tarball，检查原文件不变及新增文件清单。 |
| tests/test-package-contract.py | 七类负向包验证：覆盖 Node、改 loader、缺文件、改哈希、改 notices、混入运行时和改入口。 |
| tests/test-release-guard.py | 检查缺证据、声称通过但缺授权、本地包冒充发行包及 notices 被替换的拒绝行为。 |
| tests/test-publication.py | 以 npm 替身检查原 Node 发布入口的六种情形，不访问发布接口。 |
| tools/electron_oh.py | 交叉编译、链接 shim/静态 libc++、ELF 校验、可选签名和独立打包。 |
| tools/ci-build-electron-oh.py | 获取并校验 Node 基线，调用本目录构建入口，生成候选包和比较报告；不发布。 |
| tools/prepare-electron-oh-deps.py | 校验导入官方发行 ZIP、shim 和运行时，生成本地依赖缓存。 |
| tools/release_materials.py | 校验锁定许可文本，将全文合并到包内现有 notices 文件。 |
| tools/check-release.py | 检查正式发行包与材料、签名状态及外部证据的绑定，不执行发布。 |

保留在本目录之外的四个修改文件：

| 文件 | 保留位置的原因与作用 |
| --- | --- |
| ../patchs/0003-electron-oh-package.patch | 与既有补丁放在一起；仅调整候选包版本与文档 files 清单。 |
| ../publish.sh | 现有 Node CI 的固定入口；保持 latest 发布语义，已发布版本跳过，异常查询和 Electron 预发布拒绝。 |
| 仓库根 .github/workflows/better-sqlite3-electron-oh-checks.yml | GitHub 只在工作流目录识别入口；调用本目录的宿主静态检查及发布保护测试。 |
| 仓库根 .github/workflows/better-sqlite3-electron-oh-build.yml | 手动调用本目录 CI 构建入口，使用受信任 self-hosted runner，上传验证包，不发布 npm。 |

原 build.sh 和 0001/0002 补丁没有修改。仓库中的 README 路径与 npm 中的文档路径
不同，但 npm 包的默认入口、JS、Node 二进制和预编译目录布局不随本次整理改变。

## 构建依赖来源

- Electron-OH 官方发行物：
  https://gitcode.com/CPF-Electron/Electron/releases/download/v37.2.0/v37.2.0-openharmony-arm64.zip
- shim：同一发行 ZIP 内的 `docs/electron-napi-library.zip`，使用其 `lib/libshim.a`。
- Node-API 头文件：Node.js 官方仓库固定 tag `v22.17.0/src/` 的四份公开 C API 头文件。
- node-addon-api：npm `node-addon-api@8.9.2`。
- OHOS NDK：从 DevEco Studio SDK Manager 安装。当前实测 Native SDK API 22 / 6.0.2.130。

发行 ZIP、shim ZIP、shim 库、libelectron.so、addon 源码和头文件的 SHA-256
分别保存在两个 lock 文件中。NDK 元数据和编译器版本写入生成的 manifest。
2026-10-21 官方 ZIP 地址匿名请求返回 HTTP 401；这不是公开可无认证下载的承诺。
可登录上游获取原 ZIP，再导入缓存；无需把 libshim.a 上传到本仓库：

```sh
python3 tools/prepare-electron-oh-deps.py \
  --archive /path/to/v37.2.0-openharmony-arm64.zip \
  --output /path/to/new-cache
```

脚本校验发行物、内嵌 shim 和最终运行时哈希，拒绝不安全解压路径；输出 profile.json
记录后续使用的 shim 根目录和运行时路径。不提供 --archive 时尝试官方地址，失败会
明确报错，不回退到未经验证的镜像。也可自行解压同一发行物并直接传入构建路径。
完整官方 ZIP 的导入在本次机器上未重跑，原始 ZIP 当前不在本机缓存；实际构建使用
已经解压且通过 lock 校验的 shim/libelectron.so。

## 构建与打包

需要 Bash、Python >= 3.12、patch、Node/npm、OHOS NDK。
下列相对路径命令均在 ports/better-sqlite3/13.0.3/electron-oh/ 下执行。
先运行原 Node build.sh，或解压已经发布的 @ohos-ports/better-sqlite3@13.0.3 tarball，
得到含 SQLite amalgamation、defines.gypi 和 Node 预编译文件的基线包。

```sh
cd /path/to/prepared-node-package
npm install --ignore-scripts --omit=dev --no-save --package-lock=false node-addon-api@8.9.2

/path/to/port/electron-oh/build-electron-oh.sh \
  --source /path/to/prepared-node-package \
  --output /path/to/new-candidate-directory \
  --ndk /path/to/openharmony/native \
  --shim /path/to/electron-napi-library \
  --runtime-library /path/to/libelectron.so \
  --allow-unsigned

cd /path/to/new-candidate-directory
npm pack --ignore-scripts --pack-destination /path/to/artifacts
```

--allow-unsigned 仅生成本地 HAP 测试产物。`--sign-tool /path/to/binary-sign-tool`
仅用于本机自签名调试，不作为跨设备公开发行方案。strip 必须在签名前完成。
本 PR 提议采用应用侧 HAP 签名路线；维护者批准授权与策略后使用 --for-hap-distribution，
三个模式互斥。详见 [RELEASE.md](RELEASE.md)。
编译使用上游生成的 SQLite defines，链接 shim、静态 libc++；检查 AArch64、
注册入口、未解析 N-API/libuv 符号及 DT_NEEDED（当前仅 libc.so）。
原输入包不被修改，输出目录必须不存在。

```text
prebuilds/openharmony-arm64.node        原 Node 文件，逐字节保留
prebuilds/electron-oh/37.2.0/openharmony-arm64/
  better_sqlite3.node                  专用 Electron-OH 文件
  manifest.json                       输入、哈希、编译参数、签名状态
  THIRD_PARTY_NOTICES.txt              锁定的完整许可文本及 shim 授权待补状态
```

Node/Node-API、node-addon-api 和当前 NDK LLVM 的完整许可文本已收集并按哈希锁定，
构建时合并到 notices。shim 仍缺少对应精确发行物的授权证明，不能以插件内的许可概述代替。
该缺口及维护者对签名策略的确认，会阻止正式发行模式与发布前检查放行。
manifest 的运行状态是构建时状态；运行后以外部、绑定制品哈希的报告附证，
不篡改已经测试过的 tarball 来追认通过。

## HAP 应用接入

安装候选 tgz，不执行 electron-rebuild。将 Electron 专用 .node 复制到
`electron/libs/arm64-v8a/better_sqlite3.node`，JS 包和 manifest 放在应用 node_modules。
shim 已静态链接，不需在 HAP 中另外部署 libshim.a，也不向库 npm 包混入整个 Electron。

根 build-profile.json5 对应 product 的 buildOption 中设置：

```json
{"nativeLib":{"collectAllLibs":true,"debugSymbol":{"strip":false}}}
```

关闭二次 strip，保持预编译文件哈希和签名。使用应用签名流程完成 HAP 原生代码签名。
此前 demo 使用 SDK hap-sign-tool 的 signCode=1，验签、安装及功能验证均执行；
这不等于当前新增 notices 后的 tgz 已完成最终发行回归，也不等于 standalone 分发已验证。

Electron 主进程 app.whenReady() 后使用：

```js
const { app } = require('electron');
const path = require('node:path');
const Database = require('@ohos-ports/better-sqlite3');
app.whenReady().then(() => {
  if (process.platform !== 'openharmony' || process.arch !== 'arm64' ||
      process.versions.electron !== '37.2.0' || process.versions.node !== '22.17.0') {
    throw new Error('Unsupported Electron-OH runtime');
  }
  const db = new Database(path.join(app.getPath('userData'), 'app.db'), {
    nativeBinding: '/data/storage/el1/bundle/libs/arm64/better_sqlite3.node',
  });
  app.on('before-quit', () => db.close());
});
```

上述路径是已验证模板的实际安装路径；变更 HAP 模块布局后应重新确认。
数据库由主进程管理，renderer 通过应用 IPC 访问。普通 Node 仍直接 new Database(file)，
不传 nativeBinding，继续使用原 Node 预编译文件。
精简示例见仓库本目录中的 examples/main.cjs。

## 验证与 CI

```sh
python3 tests/verify-package.py baseline.tgz candidate.tgz
python3 tests/test-package-contract.py baseline.tgz candidate.tgz
# 在鸿蒙独立 Node 中：
node tests/node-smoke.cjs /path/to/installed/package
# Electron 主进程 ready 后调用 tests/electron-oh-smoke.cjs 导出函数。
```

CI 分为独立的宿主静态检查，以及手动触发的受信任 self-hosted Electron 构建。
后者要求 runner 标签 electron-oh、环境中提供 OHOS_NDK、ELECTRON_OH_SHIM、
ELECTRON_OH_RUNTIME_LIBRARY；每次仍校验哈希。当前官方下载需认证且 NDK 需安装，
所以不假定公共 Ubuntu runner 可匿名取得全部依赖。手动任务上传候选 tgz 和比较报告，
不调用 npm publish，不把 ELF 检查冒充真机测试。不要将未审阅 PR 送入特权 runner。
workflow 入口保留在仓库根 .github/workflows，构建与测试实现集中在本目录。
宿主静态检查可随 PR 触发；手动交叉构建需维护者先配置 runner 和经过锁定校验的依赖。
本地构建通过不等于远端 Actions 或真机测试已通过。

## 发布隔离

原 publish.sh 保留 Node latest 自动发布，不再使用默认关闭开关；增加已发布版本
跳过检查，防止仅更新 Electron 文件时重复发布 13.0.3。仅明确 E404 才继续原发布命令；
认证、网络和异常响应会失败退出，拒绝把 Electron 预发布包送入该入口。新增 CI 无 npm token、
无发布步骤。Electron 预发布只在完成完整 notices、最终签名及双宿主证据审阅后，
由维护者单独执行 npm publish --tag electron-oh；不使用 --tag latest。
提交源码、lock、文档和测试，不提交开发缓存、tgz、HAP、签名密钥或整个 Electron 发行物。
