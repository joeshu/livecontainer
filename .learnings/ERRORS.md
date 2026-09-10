# Errors
## [ERR-20260910-POP] command

**记录时间**: 2026-09-10T13:20:31Z
**优先级**: high
**状态**: resolved
**领域**: infra

### 摘要
BusyBox grep 不支持 --exclude-dir；verify_ipa_package 需要 --ipa/--mode 参数

### Error
```
递归搜索使用 find -print0 | xargs -0 grep；IPA 校验只有拿到实际产物后执行并补齐参数
```

### Context
- 尝试的命令/操作：
- 输入或参数：
- 环境细节：

### 建议修复
（待补充）

### 元数据
- 可复现: unknown
- 作用域: project
- 基础路径: /var/minis/workspace/livecontainer-audit/.learnings
- 项目路径: /var/minis/workspace/livecontainer-audit
- 关联文件: (可选)

---
## [ERR-20260910-8KF] command

**记录时间**: 2026-09-10T14:30:32Z
**优先级**: high
**状态**: pending
**领域**: infra

### 摘要
Swift URL bookmark 初始化器只替换了方法头，遗漏 relativeTo/bookmarkDataIsStale 参数

### Error
```
修改多参数 API 时保留完整调用上下文；编辑后立即读取语法区段并执行静态门禁
```

### Context
- 尝试的命令/操作：
- 输入或参数：
- 环境细节：

### 建议修复
（待补充）

### 元数据
- 可复现: unknown
- 作用域: project
- 基础路径: /var/minis/workspace/livecontainer-audit/.learnings
- 项目路径: /var/minis/workspace/livecontainer-audit
- 关联文件: (可选)

---
