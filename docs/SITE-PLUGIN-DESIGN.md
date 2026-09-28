# static-site：公开接口与站点插件设计

状态：2026-09-28 已实现 API v1，包版本 0.3.0；使用方式见 [公开 API 指南](PLUGIN-API.md)。下文保留设计目标，实际支持范围以指南和文末记录为准。
基线：独立包提交 57d6b56；博客只保留自己的适配器。
开发目录：D:/jddtest/Site Compiler/static-site-dev；独立安装目录：~/.emacs.d/pkg/static_site。
仅在开发目录内修改、提交并推送，再经明确授权通过 Git 同步安装目录；不直接写入安装目录或全局 Emacs 配置。

## 1. 目标与边界

提供面向静态站点项目的 Emacs 工作流框架。make4ht、其他生成器和部署方案均由项目选择；新增站点不要求向核心加入业务代码。

核心负责上下文、动作分派、异步任务、日志/诊断、预览生命周期、取消和局部编辑扩展。站点插件提供构建/部署、URL 映射、状态解码、snippet、自定义命令/环境和快捷键。

LaTeX .sty/.4ht、make4ht .mk4、目录和缓存仍归站点/编译器。框架不替换 AUCTeX、Projectile、project.el、补全前端，也不再实现 SSG。

站点贡献只在相应 root 的启用缓冲区/会话生效。不得用全局 LaTeX hook、setq-default 或全局按键实现站点功能。

## 2. 实施前的基础与缺口

已经具备：独立三个运行模块、可配置命令/步骤、异步进程、异步 HTTP、项目隔离、目录局部设置、环境快照、可选状态协议、模板和错误导航。

缺口：博客仍调用大量 -- 内部函数；rsync 部署与核心耦合；动作、局部键位/写作贡献和清理缺少统一契约。现有核心没有博客业务硬编码，无需重写。

## 3. 最小插件形式

插件是站点内的普通 Lisp 文件，如 emacs/site-plugin.el。无需插件市场、依赖解算、目录递归扫描或新脚本语言。

保留 static-site-register-project ROOT SETTINGS 和原有配置变量。简单项目只配命令即可；高级站点增加：

~~~elisp
;; API v1；变量由站点插件提供。
(static-site-register-plugin
 root 'jddblog
 (list :api-version 1
       :settings '((static-site-build-command . ("node" "tools/build.mjs" "make4ht"))
                   (static-site-verify-command . ("node" "tools/verify.mjs")))
       :actions (list (cons 'deploy-preview preview-provider)
                      (cons 'deploy-publish publish-provider))
       :preview (list :route route-function :decode status-decoder)
       :templates templates
       :keymap project-map
       :setup setup-function
       :teardown teardown-function))
~~~

- 注册键是 (canonical-root, plugin-id)，不存在全局“当前站点”。未知 API 版本报错。
- 显式加载信任的项目代码，沿用 Emacs 的目录局部代码信任机制；打开陌生目录不自动执行插件。
- 同一 root 可组合多个插件。重复动作/模板需明确替换声明，不能依靠加载顺序静默覆盖。API v1 使用 :replace 的贡献名列表授权特定覆盖。
- 设置优先级：用户 buffer/directory-local 值 > 项目插件默认值 > 框架默认值。
- 注册只存数据/函数，不启动构建、网络或部署。
- 重载影响后续上下文；已启动任务保持快照，预览设置变化要求显式重启。
- 两个 checkout 可有同名插件；回调保留函数对象/词法闭包与 root，不依赖后加载的全局变量解析当前站点。站点私有 helper 也要避免不同版本同名定义互相覆盖。
- 插件是可信 Lisp，不是沙箱。框架保证公开贡献机制的作用域，不能阻止任意插件主动修改全局状态。

## 4. 公开接口

第一版只承诺少量入口，不公开可变 state struct：

| 公开接口 | 契约 |
| --- | --- |
| static-site-context | 当前项目的只读快照：root、backend、source buffer、目录、环境、插件版本 |
| static-site-register-plugin | 指定 root 的注册入口，与旧 register-project 共存 |
| static-site-invoke-action ACTION &optional CONTEXT | 解析动作、捕获上下文、取得任务所有权，再调用 provider |
| static-site-run-job CONTEXT SPEC DONE | 异步串行 argv 步骤；统一环境、日志、诊断和取消 |
| static-site-preview-state CONTEXT | 预览状态快照，不暴露内部 plist |
| static-site-preview-probe CONTEXT DONE | 有界异步状态/占用检查；依情况验证身份，复用会话在途请求 |
| static-site-log CONTEXT TEXT | 写所属任务诊断，无需访问内部 buffer |

取消和打开日志沿用已有用户命令；run-job 返回 job handle。适配器不再调用 --state、--idle、--run、--buffer、--environment 或 preview--request。

### 动作与任务协议

- 常见 action id 为 build、verify、deploy-preview、deploy-publish、deploy-forget；站点可加 doctor、deploy 等动作。
- 简单动作声明 argv/工作目录；复杂动作提供 (lambda (context done) ...)。
- provider 可调用公开 job/probe API，不能同步执行耗时编译或网络请求。
- job spec 支持 :argv 或 :steps、:directory、:environment。当前统一使用 compilation 日志和互斥写任务；不开放自定义诊断格式/只读 job 分类。默认不是 shell 字符串；管道由项目脚本负责。
- done 恰好调用一次，返回 :status（success/error/cancelled）、可选退出码/消息/provider 数据；异常转换成失败，取消不算成功。
- action 在第一次异步预检前取得所有权；避免两个命令同时检查空闲再各自启动。其内部 job 复用该所有权。
- 同 root 互斥写任务不得重叠；不同 root 可并行。watching preview 与独立构建互斥；只读状态查询无需独占写锁。
- 迟到回调核对 action/session generation，不能覆盖新任务状态。
- Windows 进程树停止改异步；完成前保持 stopping，不提前释放锁或启动新构建。
- 所有操作使用捕获的 root/环境，回调不能改用当时选中的另一个 buffer 的项目。

### 部署是可替换 provider

现有 rsync 移入可选 static-site-deploy-rsync.el，保留旧命令/变量的兼容入口。博客 provider 调用 tools/deploy.mjs，其他站点可调用其托管平台 CLI 或自定义脚本。

框架不规定 rsync、远端路径、manifest、快照格式或必需的发布阶段。提供统一菜单、日志、取消、状态和可复用确认 UI；provider 决定目标、需展示的变更、准备结果如何验证、哪个动作真正发布。

provider 如果提供 preview/publish，计划绑定 root、provider、实际目标和内容版本，失败/切站点后不可复用错计划。博客保持现有 plan ID 契约。只有单阶段发布的 provider 也可以注册自己的动作。

不需要部署的项目不注册相关动作。旧通用菜单为兼容保留 rsync 入口，执行时才加载可选模块；可用 static-site-action-available-p 判断插件 provider。构建和预览不依赖部署模块。

## 5. 站点局部的写作扩展

### Snippet 与命令

- 保留字符串+光标标记和插入函数两种现有模板，零额外依赖。
- 站点提供 BlogImage、widget、自定义环境模板；核心不解释其 TeX/HTML 语义。
- 可选 YASnippet 桥接直接调用已启用的 yas-expand-snippet，未启用则使用普通文本后备；不安装 snippet 表或写全局目录。
- 不强制维护两套模板；复杂插入可直接提供函数，不新增一门 snippet 语言。

### 自定义环境与 AUCTeX

- setup 在匹配的 LaTeX buffer 内添加命令参数、环境或 CAPF；缺少 AUCTeX 时保留模板，不迫使其他站点安装它。
- 优先使用 AUCTeX 命令/环境支持、站点局部 style 文件和标准 CAPF，不再创建 TeX 解析器。
- 列表复制并设为 buffer-local 后再添加；退出时撤销自身贡献，保留用户后续修改。
- 不修改全局 TeX-auto-save、TeX-output-dir、PDF 编译/预览和 Corfu。AUCTeX 正常生成 auto/；构建侧负责识别它。

依据：[AUCTeX 扩展机制](https://www.gnu.org/software/auctex/manual/auctex.html)、[自动目录缓存](https://www.gnu.org/software/auctex/manual/auctex/Automatic-Local.html)。

### 快捷键与生命周期

- root 对应的贡献通过 buffer 自己的 minor-mode 覆盖映射组合，不修改全局图或共享 LaTeX major-mode 图。
- 博客保留自己的前缀，或局部 remap 通用命令。显式用户键位优先，冲突可见。
- setup/teardown 成对、幂等；反复启用不重复 hook、CAPF、timer、keymap 或 snippet。
- buffer 关闭、模式禁用、root 切换、插件重载均清理。停止一个站点不影响另一个。
- 普通 LaTeX buffer 默认不启用 static-site 模式，不接受站点贡献。

依据：[Emacs minor mode](https://www.gnu.org/software/emacs/manual/html_node/elisp/Defining-Minor-Modes.html)。

## 6. 预览与性能

- 文件监听和增量构建归站点 preview 命令；Emacs 不增加第二个构建 watcher。
- 保持现有 identity/readiness/revision decoder；可选 per-page revision/hash 由站点根据最终页面生成，框架不推测源文件依赖。
- 保存后短时快速检查、building 时适当加快、空闲时退避。save hook 只标记检查需求，不构建；没有预览会话时不唤醒计时器。
- 每会话一个在途 HTTP 请求、超时有界、停止时取消；暂不引入常驻 SSE 客户端。
- 隐藏 EWW 标记 dirty，显示时再刷新；有 page revision 时精准刷新，否则回退全站 revision。
- 普通静态服务器没有状态时，只保证可打开，不能承诺识别构建成功/失败或自动刷新。
- 元信息 CAPF 改单次扫描，必要时按 buffer modification tick 缓存；保持字符扫描上限、嵌套/注释正确性。
- 日志优化先测量，不为了截断输出破坏 compilation-mode 定位。
- 博客 watcher/hash/staging 统一排除 AUCTeX 生成文件；核心不对所有站点硬编码 auto/ 过滤。
- 通用 rsync provider 的快照校验/复制已迁到独立 batch Emacs 过程；publish 前的文件树校验仍同步。博客使用既有外部部署脚本。

## 7. 迁移顺序

1. 在现有实现外提供公开 context/job/probe 入口；内部实现可暂时不重构。
2. 引入 root-scoped descriptor 和动作分派，保留旧变量/register-project。
3. 博客 guard、部署与预览迁到公开 API；核心测试不依赖博客目录。
4. rsync 移入可选 provider，旧命令改为分派入口。
5. 完成局部写作贡献和清理，提供 BlogImage、自定义环境、快捷键示例。
6. 实施轮询、EWW、补全优化；用第二个独立静态站点验证通用性。

不一开始引入 schema 注册中心、插件依赖图或任意事件总线。API 版本独立于内部模块划分。

## 8. 验收矩阵

| 需求 | 完成证据 |
| --- | --- |
| 博客只用公开 API | adapter 不再引用包的 -- 函数/state；真实构建、预览、取消通过 |
| 第二站点可扩展 | 非博客站点接入不同命令、状态格式、部署 provider，无须修改核心 |
| 部署可替换 | rsync 与博客各自测试；无部署站点能正常使用；不发布真实网站 |
| 全局配置保持 | 普通 LaTeX buffer 的 TeX 设置、CAPF、hooks、keymap 在启停插件前后相同 |
| 插件隔离 | 两个 root、相同 ID/不同版本、不同加载顺序及 root 切换不串用配置/回调 |
| 局部扩展生命周期 | 重复启停、杀 buffer、重载、用户局部覆盖、缺失 AUCTeX/YAS 正常 |
| 异步可靠 | 并发启动、预检中取消、迟到回调、进程树停止、失败恢复；回调一次，锁不早放 |
| 性能 | 无编辑轮询减少，保存不重复构建，隐藏 EWW 不重载，长元信息补全更快 |
| 独立使用 | 新站点教程、最小插件、模板/环境/键位例子、API 版本与迁移说明 |

过去 VALIDATION.md 的37项通过不能作为新接口已完成的证据。跨平台支持按实际验证范围报告。

## 9. 与博客设计的配合

博客仓库 docs/CONFIGURATION-AND-MATH-DESIGN.md 定义数学配置和渲染职责。本规范不复制其文章 schema、SVG 资源或原生 make4ht 规则。

用户已确认方向为“通用静态站点框架 + 每站点插件”，且其他 LaTeX 写作体验保持不变。本轮在独立开发副本中实现运行模块和博客适配器，没有修改安装目录或全局配置。

## 10. 实施记录

公开入口、root/ID 注册、预检前动作锁、上下文快照、异步取消、可选 rsync、局部扩展与预览优化已实现。博客适配器不再调用框架私有函数。新站点示例与精确 job/callback 契约见 PLUGIN-API.md；旧变量和 register-project 继续可用。

Windows/Emacs 31.1：原工作流 37 项回归通过，新增 API 9 项通过，博客适配器 6 项通过；真实 EWW 集成覆盖启动、修改后刷新、原文错误定位、失败恢复和停止。非博客生成器使用真实异步命令验证；没有向真实托管服务发布。根目录变化在下一次 context/action 或重新启用时清理，不增加逐键扫描。复杂 AUCTeX/YAS 交互和其他操作系统仍需在对应实际环境验证。
