# 反馈与沟通规范 / Contribution and Communication Guidelines

[中文](#中文) | [English](#english)

使用中文或英文提交即可，不要求重复翻译。
You may write in Chinese or English; you do not need to provide both.

## 中文

本规范适用于本仓库的 issue、PR 和评论。可以使用 AI 辅助，但提交者需要对内容负责。
格式是为了让人容易理解，不是要求写长报告；不相关的项目写“不适用”，不清楚的内容直接说明。

### 先说人能看懂的话

- 先用一两句话说清问题或结论，再补充依据，不要让维护者从大段日志中猜你的意思。
- 使用简体中文或清楚的英文。术语、缩写第一次出现时，简要解释它与本问题的关系。
- 区分实际观察、引用他人的结果、自己的推测和未验证的部分。没有设备或没有测试都可以直说。
- 编译通过、成功启动、暂时没看到错误，不等于整个功能已经修好。
- 直接回答对方的问题。不要反复改写背景、堆砌术语，或用“已闭环”“证据链收敛”等空话代替结果。
- 长日志放附件或折叠区，正文只保留关键片段及必要上下文。公开前删除密码、令牌和个人信息。

例如，不要只写：

> 已完成全链路闭环，后续按验收矩阵复核。

可以写：

> 程序现在能正常打开，但保存文件还没测试，所以暂时不能说问题全部解决。

### Issue 格式

一次尽量只讨论一个主要问题，按模板说明：

1. **一句话说明**：什么功能有问题，或希望改进什么。
2. **环境**：设备、系统镜像、内核或相关软件版本，以及自行修改的内容。
3. **复现或使用场景**：做了什么、预期是什么、实际发生什么；偶发问题注明频率。
4. **已尝试与结果**：只写实际做过的操作。猜测单独标明，不要把排查计划写成已完成的测试。
5. **证据与请求**：相关日志、截图或引用，以及希望维护者帮助确认的具体问题。

不要求报告者先找到根因。没有日志、无法稳定复现时，请说明限制，不要编造步骤或补齐未知数据。

### PR 格式

1. **改了什么、为什么改**：简要说明改动，并关联完整的 issue 地址。
2. **如何验证**：写出实际使用的环境、操作和结果；他人验证请注明来源。
3. **影响与限制**：说明影响范围、尚未验证的行为，以及是否只是临时缓解。
4. **风险与回退**：涉及启动、存储、充电或数据修改时，说明主要风险和撤回方法。

没有实机验证并不禁止提交供审查，但必须明确写出，不能称为“实机修复完成”。

### 评论和排查建议

回复不需要再贴一份完整报告，通常按下面的顺序即可；没有必要的项目可以省略：

```text
结论：直接回答当前的问题。
依据：实际观察、代码检查或他人提供的结果。
尚未确认：哪些只是推测，缺少什么证据。
下一步：如果需要协助，说清谁做什么，以及结果能帮助判断什么。
```

给命令时说明在哪里执行、有什么作用、预期看到什么。优先使用已有日志，不要默认要求反复压测。
写盘、刷机、修改运行参数等有风险的操作，必须先说明风险和恢复方法。
收到新的结果后只更新相关结论，不要反复要求对方执行已经做过且没有新信息的操作。

### AI 辅助内容

- 允许用 AI 起草、分析或整理，但请先人工阅读和核对。不要原样粘贴自己看不懂、无法解释的技术内容。
- AI 起草实质性技术内容时，请简注明使用范围，例如“AI 辅助：整理文字；测试由本人执行”。单纯改错字或润色不必声明。
- AI 生成的解释不是证据；引用代码、日志、测试数字和提交时，必须核对其确实存在且与本问题相关。
- 不要为了填满模板而生成长篇总结、虚构测试、夸大结论，或附上整段 AI 对话。
- 发出前请确认：不了解你排查过程的人，也能看懂发生了什么、已确认什么、还需要什么帮助。

难以理解或缺少关键信息的内容，维护者可能先要求简化、改写或补充，再继续调查。

## English

These guidelines apply to issues, pull requests, and comments in this repository.
AI assistance is allowed, but you remain responsible for what you submit.
The format is meant to make reports easier to understand, not longer.
Write “not applicable” for irrelevant items and state clearly when something is unknown.

### Use plain language

- Start with one or two sentences stating the problem or conclusion, then provide evidence.
  Do not make maintainers guess your point from a large log dump.
- Write in Simplified Chinese or clear English. Explain unfamiliar terms and abbreviations when first used,
  including why they matter to the issue.
- Distinguish your observations, results reported by others, hypotheses, and untested behavior.
  It is fine to say you do not have the hardware or have not tested something.
- A successful build, a successful boot, or a period without errors does not prove that the whole feature is fixed.
- Answer the question directly. Avoid repeating background, piling up jargon, or substituting phrases such as
  “end-to-end validation complete” or “the evidence has converged” for actual results.
- Put long logs in attachments or collapsible sections. Keep only relevant excerpts and necessary context in the body.
  Remove passwords, tokens, and personal information before posting.

Instead of:

> End-to-end validation is complete; further checks will follow the acceptance matrix.

Write:

> The application now opens, but saving files has not been tested, so I cannot yet say the problem is fully fixed.

### Issue format

Keep each issue focused on one main problem and use the template to describe:

1. **Summary:** What is broken, or what would you like to improve?
2. **Environment:** Device, system image, kernel or relevant software versions, and any local modifications.
3. **Reproduction or use case:** What you did, what you expected, and what happened. Include the frequency of intermittent failures.
4. **Attempts and results:** Only describe actions you actually performed. Label hypotheses separately;
   do not present a troubleshooting plan as completed testing.
5. **Evidence and request:** Relevant logs, screenshots, or references, and the specific help you need from maintainers.

You do not need to find the root cause before reporting a problem.
If logs are unavailable or reproduction is unreliable, explain the limitation rather than inventing steps or missing data.

### Pull request format

1. **What changed and why:** Briefly explain the change and include the full URL of the related issue.
2. **Verification:** State the environment, actions, and results of testing you actually performed.
   Cite the source when relying on someone else's tests.
3. **Impact and limitations:** Explain what is affected, what remains untested, and whether the change is only a workaround.
4. **Risks and rollback:** For changes involving boot, storage, charging, or data modification,
   describe the main risks and how to revert the change.

You may submit a PR for review without hardware testing, but say so explicitly.
Do not describe it as a hardware-verified fix.

### Comments and troubleshooting

A reply does not need to repeat the full report. The following order is usually enough; omit items that do not apply:

```text
Conclusion: Answer the current question directly.
Evidence: Your observations, code inspection, or results reported by others.
Unknowns: What is still a hypothesis, and what evidence is missing?
Next step: If help is needed, explain who should do what and what the result would help determine.
```

When providing commands, explain where to run them, what they do, and what output to expect.
Prefer existing logs; do not routinely ask people to repeat stress tests.
Explain risks and recovery steps before suggesting disk writes, flashing, runtime setting changes, or other risky operations.
When new results arrive, update the relevant conclusions rather than requesting repeated actions that add no new information.

### AI-assisted content

- You may use AI to draft, analyze, or organize content, but personally read and check it before posting.
  Do not paste technical explanations you do not understand or cannot explain.
- Briefly disclose AI assistance with substantive technical content, for example:
  “AI assistance: text organization; testing performed by me.” A disclosure is not required for simple proofreading or wording edits.
- AI-generated explanations are not evidence. Check that cited code, logs, test numbers, and commits exist and are relevant to the issue.
- Do not generate long summaries merely to fill the template, invent tests, overstate conclusions, or paste entire AI conversations.
- Before posting, check that someone unfamiliar with your investigation can understand what happened,
  what is confirmed, and what help is still needed.

If a post is difficult to understand or lacks essential information, maintainers may ask you to simplify,
rewrite, or supplement it before continuing the investigation.
