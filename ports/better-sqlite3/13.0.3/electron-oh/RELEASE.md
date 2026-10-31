# Electron-OH 发行材料与签名决策

范围仅为 `@ohos-ports/better-sqlite3@13.0.3-electron-oh.0`，dist-tag 为 `electron-oh`。
本 PR 不执行发布。完整材料、最终包和运行证据均须经维护者审阅。

## 当前材料与缺口

| 组件 | 已收集的材料 | 待完成事项 |
| --- | --- | --- |
| better-sqlite3 13.0.3 | 保留 Node 基线包原 LICENSE | 包比较确认不变。 |
| SQLite | 保留原 sqlite3.c 中 public-domain dedication | 包比较确认不变。 |
| Node-API v22.17.0 头文件 | licenses/Node-v22.17.0-LICENSE.txt，保留官方完整 LICENSE | 不借此宣称分发整个 Node；仅使用公开头文件。 |
| node-addon-api 8.9.2 | licenses/node-addon-api-8.9.2-LICENSE.txt，保留官方完整 MIT 文本 | 与构建输入版本一致。 |
| SDK 6.0.2.130 的静态运行库与启动代码 | licenses/ 中 NDK 的 LLVM-NOTICE、NATIVE-NOTICE 两份原文，覆盖 SDK 附带的许可说明 | SDK 升级时重新核对来源、文本和实际静态库。 |
| Electron N-API shim | lock 中固定发行 ZIP 与 libshim.a 哈希 | 缺少能够对应该归档的上游 LICENSE/NOTICE 或明确允许静态链接及再分发的上游说明。 |

公开文本的来源和 SHA-256 记录在 release-materials.lock.json；构建时校验并将全文
合并到现有 THIRD_PARTY_NOTICES.txt，不向 npm 包新增运行时或额外目录。
SDK notices 保留完整原文，包含本构建未使用组件的说明，不表示这些组件都被打入包。
release-materials.lock.json 另锁定实测 SDK 版本、notices、静态 libc++/libc++abi/libunwind、
compiler-rt 及启动对象哈希；构建时检查这些输入，避免仅换 SDK 却沿用旧 notices。
Node 原文件及包根 LICENSE 不被覆盖。材料完整性通过不等于再分发授权已获批准。

shim 的具体取证步骤：

1. 从 lock 指向的 Electron-OH 37.2.0 发行物取得原 ZIP，校验其哈希。
2. 检查 docs/electron-napi-library.zip 内及发行物附带的 LICENSE/NOTICE。
3. 如未包含，请上游维护者提供明确覆盖当前 libshim.a 哈希、来源及静态再分发方式的公开说明。
   本 PR 可以引用该说明；不要以插件 README 的 MIT 概述或当前主分支许可证代替发行物授权依据。
4. 将适用的完整文本保存到 licenses/，在 documents 中增加来源和 SHA-256；
   shimAuthorization 增加 licenseDocument，维护者审阅后将 status 改为 approved 并记录 reviewUrl。
   若拿到的是新版本 shim，应升级所有对应输入和测试，不沿用旧二进制的授权或证据。

当前构建采用已经解压、通过 lock 校验的依赖；完整官方 ZIP 导入尚未重跑。
shim 授权状态如实保持 pending-upstream-evidence，不以补写一份 MIT 模板来消除缺口。

## 本 PR 提议的签名决策

选择 `hap-consumer-signing`：npm 包携带最终 strip 后的 ELF，由应用方在 HAP 构建时
使用自身应用证书及 profile 完成代码签名。这个发行范围不承诺支持下载 ELF 后直接执行或任意动态加载。
原独立 Node 预编译文件不重新签名、不重建、不替换。

依据与边界：

- 官方 binary-sign-tool 将 `-selfSign 1` 定义为本机自签名；不能把它作为跨设备公开发行可用性的证明。
  文档：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/binary-sign-tool
- 已有 demo 使用 hap-sign-tool 的 `-signCode 1`，verify-app 日志明确验证了
  libs/arm64-v8a/better_sqlite3.node，随后通过装机回归。这支持 HAP 集成路径，
  不等于已验证应用市场发行或 standalone ELF 分发。
- 不提交 npm/HAP 私钥、口令或应用 profile；应用签名由应用维护者配置。
- npm 中 ELF 与 manifest 的哈希绑定打包前文件。HAP 代码签名可能添加签名块或产生外部签名数据；
  验证包内 ELF 与输入的关系并分别记录哈希，不能无条件把签名后文件视为与 npm ELF 逐字节一致。

本策略 status 仍为 proposed。维护者审阅适用场景及验证报告后，在 signatureDecision 中
记录 reviewUrl 并改为 approved。选用不同分发方式时，应先变更策略、工具及验证，不能仅改状态。

## 三种构建模式

| 参数 | 用途 | 是否允许进入公开发布检查 |
| --- | --- | --- |
| --allow-unsigned | 本地 HAP 测试；当前独立构建 CI 沿用此模式 | 拒绝。 |
| --sign-tool /path/to/binary-sign-tool | 本机 selfSign 调试；manifest 标记 self-signed-local-only | 拒绝。 |
| --for-hap-distribution | 应用侧 HAP 签名路线；manifest 标记 unsigned-for-hap-signing | 授权与策略均批准后才允许构建；仍需最终运行证据。 |

三个参数互斥。`--for-hap-distribution` 不执行 npm 发布，也不为应用签名。
当前未满足 shim 授权与维护者签名决策条件时，该模式必须失败。
原 Node publish.sh 不承担 Electron 发布，新增构建 CI 不持有 npm 写权限。

## 正式发行操作顺序

下列命令均在 electron-oh/ 下执行。

1. 补齐并审阅上述授权材料与签名决策，然后先检查材料身份：

   ```sh
   python3 tools/check-release.py --check-materials
   ```

   该命令仅校验来源文件哈希，不是发布放行。

2. 使用经过哈希校验的 Node 基线目录及依赖构建新的候选目录：

   ```sh
   ./build-electron-oh.sh \
     --source /path/to/prepared-node-package \
     --output /path/to/new-release-candidate \
     --ndk /path/to/openharmony/native \
     --shim /path/to/electron-napi-library \
     --runtime-library /path/to/libelectron.so \
     --for-hap-distribution
   ```

   原生编译、strip 完成后生成 manifest、完整 notices，再用 npm pack --ignore-scripts 打包。
   不把之前 --allow-unsigned 的 manifest 直接改名为发行状态。

3. 对最终 tgz 执行 verify-package.py、test-package-contract.py，运行 Node demo 与
   Electron HAP demo；应用打包使用 collectAllLibs=true、strip=false，并按 SDK 流程执行代码签名、
   verify-app、装机验证。验证日志须显示 better_sqlite3.node 代码签名成功。
   保存测试所用 tgz/ELF/HAP 哈希和完整报告；生产应用必须使用自己的签名配置。

4. 复制 release-evidence.example.json 到报告目录，填入该最终 tgz、原 Node 基线、ELF 和
   已验签 HAP 的身份，填写真实运行结果、可访问报告和维护者审阅链接。示例不是测试证据。

   ```sh
   python3 tools/check-release.py baseline.tgz candidate.tgz --evidence /path/to/evidence.json
   ```

   检查缺少材料、策略未批准、local-only/self-sign 包、包或 notices 被替换、证据不匹配时退出非零。
   工具只检查结构、身份和显式状态；报告链接是否真实、审阅者是否有权限仍须维护者审核。
   它不联网认证 reviewUrl，也不代替许可证审阅、证书链校验或真机测试。

5. 维护者使用同一个已验证 tgz 发布 `--tag electron-oh --access public --ignore-scripts`，
   保持 latest 不变；再从 registry 下载该版本，比较制品身份并进行安装回归。
   当前 PR 不新增自动发布任务。后续可在 GitHub 托管 runner 上增加受保护的 OIDC 发布阶段，
   从固定构建 run 获取并校验制品，不能重新打包或信任任意 PR 上传的包。

历史 HAP 证据仅适用于其记录的旧 tgz。新增完整 notices 后须记录新的 tgz 身份并重新验证；
可以证明原生文件相同，但不能将旧报告的 tarball 哈希改成新包哈希来追认通过。
