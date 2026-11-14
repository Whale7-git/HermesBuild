# 本地改动补丁

上游：`gonzalezreal/textual`，revision `01b51875a5406eefc95f52a058cb059e7bc94dc4`（0.5.0）。

每个文件一个补丁，共 17 个。`HERMES-PATCHES.md` 早前记录为「7 处改动」，
实际逐字节比对后是 **17 个文件**有差异——文字说明只覆盖了其中 7 类改动，
另有 10 个文件（文本选择交互、高亮分词、Overflow 等）的改动没有被文字记录。

## 用法

```bash
git clone https://github.com/gonzalezreal/textual.git textual
cd textual && git checkout 01b51875a5406eefc95f52a058cb059e7bc94dc4

for p in /path/to/patches/*.patch; do
    git apply -p1 "$p" || echo "FAILED: $p"
done
```

## 验证

已实测：把上游 checkout 到干净目录，依次 `git apply -p1` 全部 17 个补丁，
**17/17 应用成功，逐字节与本地文件一致**（`UPSTREAM-SHA256.json` 的
`local_files` 与 `modified_files` 即比对结果）。

## 注意

- 补丁针对上述确切 revision。上游若已合入同类改动，`git apply` 会失败——
  那正是需要人工判断「回退到上游版本」还是「重做本地改动」的地方。
- `UPSTREAM-SHA256.json` 现在同时记录 `original_files`（上游原始）与
  `local_files`（本地当前），`modified_files` 由两者差异自动得出。
