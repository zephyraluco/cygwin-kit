# Minimal Cygwin Runtime

在 Windows PowerShell 7 中运行：

```powershell
./scripts/install-cygwin.ps1
```

脚本通过 HTTPS 从 Cygwin 官网下载安装器，保留安装器默认的软件包签名验证，安装到
`C:\cygwin`，然后检查 Bash、OpenSSH、sshpass、OpenSSL 运行库和时区文件。可用 `-Root`
指定安装目录，`-Mirror` 指定镜像，`-Cache` 指定下载缓存目录。

请求的软件包为 `bash,cygwin,coreutils,findutils,gawk,tar,gzip,libssl3,openssh,sshpass,curl`。
Cygwin 安装器还会安装默认基础包和必要依赖，因此实际安装内容不只包含上述包。
这是构建和打包的安装源，发布包会另外按白名单生成，不直接归档整个安装目录。

CI 分为 **Build** 和 **Package**，均直接调用 `scripts/` 下的脚本，在 Windows 上构建，不使用 Docker。
分支推送、PR 和手动运行 Build 只编译，不打包或上传产物。
Package 仅在推送 tag 时触发，在自己的 runner 上重新构建，再打包并发布。
运行成功后，在该次运行页面的
**Artifacts → cygwin-x86_64** 下载压缩包，产物保留 **7 天**。
下载产物内包含 `cygwin-x86_64.tar.gz`，其顶层目录为 `cygwin/`。
`scripts/stage-runtime.sh` 从空目录生成精简发布树，只保留选定程序和递归 DLL 依赖。
保留 Bash/sh、SSH 客户端及 keygen/agent/add、scp/sftp、sshpass、ripgrep、fd（fd-find），
以及 ls/cat/cp/mv/rm/mkdir/ln/chmod/env/dirname/basename/mktemp/sed/grep/cygpath，
另保留 head/tail/sort/find/wc/xargs/uniq/cut/tr/awk/tar/sleep/curl；awk 使用 GNU awk，
tar 配套保留 gzip，支持 `.tar.gz` 的创建和解压。
curl 为 Cygwin HTTPS/HTTP 下载工具，其 libcurl、libssl、zlib 等依赖由 staging 阶段
按 PE 导入递归收集。
保留 SSH helper 和 xterm、xterm-256color、cygwin、dumb 四种终端定义。
不包含编辑器、mintty、SSH 服务端、文件类型数据库、排版工具、文档、翻译、
安装器状态或用户目录。**时区文件和所有随包证书数据均不包含在成品中**，
包括 `zoneinfo`、`localtime`、`etc/ssl`、`etc/pki` 和 `usr/share/pki`。
因此 curl 在 HTTPS 下需要自备 CA 证书：`curl --cacert <文件>`，或自行在 `/etc/ssl/certs` 放置证书包；
纯 HTTP 请求不受影响。
最小启动配置使用 UTF-8，默认 `TZ=UTC0`；SSH 仍使用用户自己的 known_hosts 和密钥。
源安装目录保持完整，归档工具从源环境调用，不必放进发布包。

推送 tag 会在构建和 ABI 检查成功后自动发布 GitHub Release。
在 Release 的 Assets 中直接下载 `cygwin-x86_64.tar.gz` 及其 `.sha256` 校验文件，
不需要解开 Actions 下载时附加的 ZIP 包装。不要将自动生成的 Source code 压缩包
误当作运行环境。Actions 产物保留 7 天；Release 附件持续保留，直到手动删除。
请在 Windows 上解压到目标父目录；Cygwin 不是 Linux 可执行环境。

安装器和软件包使用镜像当前版本，未固定版本；不同日期打包结果可能不同。

## ripgrep 和 fd-find

在 Windows PowerShell 7 中手动构建或打包：

```powershell
./scripts/build.ps1 -WorkRoot D:\build-work
# 可选：将上一步编译结果集成并打包，不重复编译。
./scripts/package.ps1 -WorkRoot D:\build-work -Archive D:\cygwin-x86_64.tar.gz
```

构建脚本使用独立的 `C:\cygwin-build` 安装 `gcc-core,binutils`，再调用
`scripts/build-cygwin-commands.ps1` 构建官方 ripgrep tag `15.2.0`，提交
`e89fff89ac9af12e8d4ce9d5fd07beb408ca730f`。
它使用 Windows 宿主 Rust `nightly-2025-11-01` 和 Cygwin GCC，构建
`x86_64-pc-cygwin` 目标及其标准库；只检查 ABI，不执行 ripgrep 运行测试。
最终压缩包不包含该编译环境；只复制程序及其需要的 Cygwin DLL。
发布构建关闭调试信息，并在打包的 ripgrep 副本中移除调试段。
打包时安装 `/usr/local/bin/rg.exe`，许可证和版本记录位于 `/opt/ripgrep/share/`。
fd-find 固定为最新正式 tag `v10.5.1`，源码 `sharkdp/fd` 提交
`193d0df1d0ad455e44506953a2cd80428203ff35`，使用相同工具链构建。
关闭默认 features，避免引入 jemalloc 和补全生成组件；命令为 `fd`，
安装到 `/usr/local/bin/fd.exe`，许可证和版本记录位于 `/opt/fd/share/`。
打包时检查 fd 的 Cygwin ABI，并测试文件查找及 `-x` 执行功能。

这两个命令都是 Cygwin 动态链接程序，需要随包提供的 Cygwin 运行环境，不是独立 Win32 程序。
打包前从 PowerShell 独立启动 staging 环境，检查根目录、Bash、文件操作、SSH 配置解析及密钥生成。
ripgrep 保持仅验证 ABI，不执行功能测试。可在 Linux 上对包含 rg 和 fd 的解开发布包运行
`python3 scripts/tests/test-stage-runtime.py /path/to/cygwin` 验证筛选和依赖检查。

## SSH

发布包包含 Cygwin OpenSSH 客户端和 `sshpass`，可在 Cygwin Bash 中连接远程主机：

```bash
ssh 用户名@远程主机
# 自定义端口
ssh -p 2222 用户名@远程主机
```

使用 `sshpass` 从环境变量读取密码：

```bash
read -rsp 'SSH 密码: ' SSHPASS; echo
export SSHPASS
sshpass -e ssh 用户名@远程主机
unset SSHPASS
```

## 下载工具

发布包包含 `curl` 和 `sleep`，可在 Cygwin Bash 中使用：

```bash
curl -fsSL http://example.com/file -o file
sleep 2
```

由于包内不含证书数据，HTTPS 请求需要显式指定 CA 文件：

```bash
curl --cacert /path/to/ca-bundle.crt -fsSL https://example.com
```
