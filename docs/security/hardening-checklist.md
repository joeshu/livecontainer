# LiveContainer 加固实施清单

基线：`5c8b5103d91117d86add96cf30711d86add96cf30711d3ab183d031`
分支：`hardening/p0-runtime-boundary`

## 交付规则

- 每个阶段独立提交，失败可回滚。
- 不改变现有功能开关语义，除非有兼容性降级。
- 每个安全边界同时做输入校验、真实路径校验和错误回滚。
- 不在本地安装 npm/项目依赖；本地只做静态审查、脚本测试和可用工具验证。
- iOS/Xcode/私有 API 行为必须列入真机验收，不假称本地已验证。

## 阶段清单

### Phase 0：基线与工具

- [x] 建立本地分支
- [x] 建立实施清单
- [x] 增加安全路径工具接口（原生深链、注册表归属和 Bootstrap 目标校验）
- [x] 增加不依赖 Xcode 的路径/归档静态契约检查
- [x] 增加变更回滚说明和验收记录（本分支；未推送）
- [x] 每个阶段使用独立 checkpoint（当前共 7 个加固提交；未推送）

### Phase 1：P0 路径边界

- [x] `bundle-name` 仅允许已注册 bundle，禁止 URL 直接成为路径（原生深链和 Bootstrap 均校验注册 Bundle）
- [x] `container-folder-name` 仅允许目标 App 已注册容器（深链、Bootstrap 最终容器解析均校验 LCContainers）
- [ ] App Group identifier 做安全组件与 entitlement 映射
- [ ] 所有实际路径做 canonical containment
- [ ] 外部 bookmark 失败禁止回退到内部同名容器

### Phase 2：P0 IPA 安装事务

- [x] 解压拒绝绝对路径、`..`、symlink、hardlink、special file（待 Actions/真机验证）
- [x] 启用 libarchive 安全选项（待 Actions/真机验证）
- [x] 限制条目数、单文件大小、总解压大小、目录深度（待 Actions/真机验证）
- [x] 解压失败必须返回失败并清理 staging（静态验证；运行时待验证）
- [x] staging 使用每操作唯一目录（静态验证；运行时待验证）
- [x] patch/sign/verify 成功后才替换正式 App（静态验证；签名/真机待验证）
- [x] 替换失败恢复旧 App（静态验证；异常注入待验证）
- [x] 不删除调用者拥有的源 IPA

### Phase 3：启动与并发状态

- [ ] `runApp` 使用 request ID + actor/串行状态机（本轮已先落地 request ID + 原子 pending 记录，actor 化待后续）
- [x] JIT 失败/取消清理全部 pending launch 状态
- [x] classic launch 串行重试且只一次性退出（静态验证；真机回调顺序待验证）
- [x] 深链 URL 改为带目标和 TTL 的原子 pending 记录（队列化待后续）
- [ ] 安装/下载/导出互斥并拥有各自 staging
- [x] 修复 `LC_HOME_PATH` 继承污染（静态验证；LiveProcess 真机待验证）

### Phase 4：模块注入架构

- [ ] `LCMachOReader` 统一边界验证
- [ ] `LCMachOWriter` 事务化、可重复、可回滚
- [ ] 默认显式加载 runtime，Mach-O 注入降为兼容 fallback
- [ ] TweakLoader 改为 manifest 驱动
- [ ] 模块路径、真实路径、架构、签名、hash、ABI 校验
- [ ] 内置 runtime 与用户 tweak 分离
- [ ] 默认 `RTLD_LOCAL`，显式声明才允许 global
- [ ] hook 注册表和幂等安装
- [ ] 安全模式及失败模块隔离

### Phase 5：P1/P2 生命周期

- [ ] security-scoped bookmark start/stop 成对
- [ ] stale bookmark 重新生成
- [ ] XPC audit token/entitlement 校验
- [ ] continuation actor 化
- [ ] cookie/background URLSession 按 Guest 隔离
- [ ] 清理操作按 owner/TTL，不清空整个 tmp
- [ ] App Group 按实际引用计数清理
- [ ] plist schema 版本化迁移

## 当前验收状态

- 仓库基线：PASS
- 分支隔离：PASS
- P0 安全解压/安装事务/注册表归属/原子启动协议/启动重试：代码已落地，静态门禁 PASS
- P1 清理失败保护、自定义 payload 校验、TweakLoader 路径收紧：代码已落地，静态门禁 PASS
- 外部容器 bookmark 完整启动协议、Manifest 注入、Xcode/iOS 真机：未完成/未验证
- 远端推送：未执行
